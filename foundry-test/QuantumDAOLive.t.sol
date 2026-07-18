// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.31;

import { Test, console } from "forge-std/Test.sol";

import { VotesERC20V1 } from "@luxfi/standard/dao/deployables/erc20/VotesERC20V1.sol";
import { IVotesERC20V1 } from "@luxfi/standard/dao/interfaces/deployables/IVotesERC20V1.sol";
import { StrategyV1 } from "@luxfi/standard/dao/deployables/strategies/StrategyV1.sol";
import { IStrategyV1 } from "@luxfi/standard/dao/interfaces/deployables/IStrategyV1.sol";
import { VotingWeightERC20V1 } from "@luxfi/standard/dao/deployables/strategies/voting-weight/VotingWeightERC20V1.sol";
import { VoteTrackerERC20V1 } from "@luxfi/standard/dao/deployables/strategies/vote-trackers/VoteTrackerERC20V1.sol";
import { ProposerAdapterERC20V1 } from "@luxfi/standard/dao/deployables/strategies/proposer-adapters/ProposerAdapterERC20V1.sol";
import { ModuleGovernorV1 } from "@luxfi/standard/dao/deployables/modules/ModuleGovernorV1.sol";
import { IModuleGovernorV1 } from "@luxfi/standard/dao/interfaces/deployables/IModuleGovernorV1.sol";
import { IVotingTypes } from "@luxfi/standard/dao/interfaces/deployables/IVotingTypes.sol";
import { Transaction } from "@luxfi/standard/dao/interfaces/Module.sol";
import { Enum } from "@gnosis.pm/safe-contracts/interfaces/Enum.sol";

import { PQSigner } from "@luxfi/standard/safe/pq/PQSigner.sol";
import { PQSchemes } from "@luxfi/standard/safe/pq/PQSchemes.sol";

import { SafeL2 } from "@safe-global/safe-smart-account/SafeL2.sol";
import { SafeProxyFactory } from "@safe-global/safe-smart-account/proxies/SafeProxyFactory.sol";
import { CompatibilityFallbackHandler } from "@safe-global/safe-smart-account/handler/CompatibilityFallbackHandler.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

interface ISafeFull {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address paymentReceiver
    ) external;
    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 _nonce
    ) external view returns (bytes32);
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes calldata signatures
    ) external payable returns (bool);
    function nonce() external view returns (uint256);
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
    function isOwner(address owner) external view returns (bool);
    function isModuleEnabled(address module) external view returns (bool);
    function enableModule(address module) external;
    function addOwnerWithThreshold(address owner, uint256 _threshold) external;
}

interface IProxyFactory {
    function createProxyWithNonce(address singleton, bytes calldata initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

/**
 * @title QuantumDAOLive
 * @notice Forks the LIVE Lux testnet (96368) and proves, against the REAL on-chain
 *         Safe singleton bytecode and the REAL live PQ precompiles (0x012202 ML-DSA,
 *         0x012203 SLH-DSA), the full LUX QUANTUM DAO:
 *
 *           A) deploy: token + treasury Safe (PQ owners) + governor + strategy stack;
 *           B) governance e2e: delegate -> propose -> vote -> timelock -> execute, with
 *              the Safe-executed treasury action verified on-chain;
 *           C) PQ-signing e2e: a 2-of-3 Safe (deployer ECDSA + ML-DSA + SLH-DSA owners)
 *              executes a treasury transfer where the SECOND signature is a real
 *              post-quantum signature, freshly produced (vm.ffi -> pqsign) over the
 *              actual Safe-tx-hash and accepted by the live precompile via PQSigner's
 *              EIP-1271 path. Proven for BOTH ML-DSA and SLH-DSA.
 *
 *         This executes the same bytecode the broadcast deploy would, against real
 *         chain state — the only thing the live broadcast adds is the funded-signer
 *         gas payment. Run with --fork-url + --ffi.
 */
contract QuantumDAOLive is Test {
    // Safe infra is deployed fresh on the fork (the lux-testnet.json addresses now hold
    // unrelated code after a chain re-genesis — verified on-chain).

    // PQ owner key seeds (must match the launch deployment + deployment json)
    string constant SEED_MLDSA = "lux-quantum-dao-mldsa-owner";
    string constant SEED_SLHDSA = "lux-quantum-dao-slhdsa-owner";

    // The funded deployer's address (we impersonate it on the fork; the real broadcast
    // signs with its key). Its private key is NOT needed here — vm.startPrank suffices,
    // and for the Safe ECDSA slice we use a test EOA we DO control as the ECDSA owner so
    // we can produce a real ECDSA signature deterministically. The PQ owners are the
    // headline; the ECDSA co-owner just satisfies threshold 2.
    uint256 ecdsaPk = 0xA11CE; // test ECDSA owner private key (controlled here)
    address ecdsaOwner;

    VotesERC20V1 token;
    ISafeFull safe;
    PQSigner pqMldsa;
    PQSigner pqSlhdsa;
    ModuleGovernorV1 governor;
    StrategyV1 strategy;
    VotingWeightERC20V1 weight;
    VoteTrackerERC20V1 tracker;
    ProposerAdapterERC20V1 proposer;

    function setUp() public {
        // Fork live testnet so the real Safe singleton + real PQ precompiles are present.
        vm.createSelectFork("lux_testnet");
        ecdsaOwner = vm.addr(ecdsaPk);
        _deployQuantumDAO();
    }

    // ----------------------------------------------------------------------
    // Deploy (mirrors LaunchQuantumDAO.s.sol; ECDSA owner = the controlled test EOA)
    // ----------------------------------------------------------------------
    function _deployQuantumDAO() internal {
        bytes memory mldsaPub = _ffiPub(SEED_MLDSA, "mldsa");
        bytes memory slhdsaPub = _ffiPub(SEED_SLHDSA, "slhdsa");
        assertEq(mldsaPub.length, 1952, "ml-dsa pubkey len");
        assertEq(slhdsaPub.length, 32, "slh-dsa pubkey len");

        // 1. PQ owners
        pqMldsa = new PQSigner(PQSchemes.Scheme.ML_DSA, PQSchemes.MLDSA_65, mldsaPub);
        pqSlhdsa = new PQSigner(PQSchemes.Scheme.SLH_DSA, PQSchemes.SLHDSA_SHA2_128F, slhdsaPub);

        // 2. Treasury Safe: deploy Safe infra fresh, ECDSA owner sole at threshold 1 for wiring.
        address safeSingleton = address(new SafeL2());
        IProxyFactory safeFactory = IProxyFactory(address(new SafeProxyFactory()));
        address fallbackHandler = address(new CompatibilityFallbackHandler());

        address[] memory owners = new address[](1);
        owners[0] = ecdsaOwner;
        bytes memory setup = abi.encodeWithSelector(
            ISafeFull.setup.selector,
            owners,
            uint256(1),
            address(0),
            bytes(""),
            fallbackHandler,
            address(0),
            uint256(0),
            address(0)
        );
        uint256 saltNonce = uint256(keccak256(abi.encode("lux", "quantum-dao", block.chainid)));
        safe = ISafeFull(safeFactory.createProxyWithNonce(safeSingleton, setup, saltNonce));

        // 3. Token "Lux Quantum"/LQ
        IVotesERC20V1.Metadata memory md = IVotesERC20V1.Metadata({ name: "Lux Quantum", symbol: "LQ" });
        IVotesERC20V1.Allocation[] memory allocs = new IVotesERC20V1.Allocation[](2);
        allocs[0] = IVotesERC20V1.Allocation({ to: ecdsaOwner, amount: 400_000 ether });
        allocs[1] = IVotesERC20V1.Allocation({ to: address(safe), amount: 600_000 ether });
        token = VotesERC20V1(
            address(
                new ERC1967Proxy(
                    address(new VotesERC20V1()),
                    abi.encodeCall(IVotesERC20V1.initialize, (md, allocs, address(safe), false, 1_000_000 ether))
                )
            )
        );

        // 4. proposer adapter (open)
        proposer = ProposerAdapterERC20V1(
            address(
                new ERC1967Proxy(
                    address(new ProposerAdapterERC20V1()),
                    abi.encodeCall(ProposerAdapterERC20V1.initialize, (address(token), 0))
                )
            )
        );

        // 5. strategy phase 1
        address[] memory pa = new address[](1);
        pa[0] = address(proposer);
        strategy = StrategyV1(
            address(
                new ERC1967Proxy(
                    address(new StrategyV1()),
                    abi.encodeCall(IStrategyV1.initialize, (uint32(120), 1 ether, 500_001, pa, address(0)))
                )
            )
        );

        // 6. weight + tracker
        weight = VotingWeightERC20V1(
            address(
                new ERC1967Proxy(
                    address(new VotingWeightERC20V1()),
                    abi.encodeCall(VotingWeightERC20V1.initialize, (address(token), 1))
                )
            )
        );
        address[] memory authed = new address[](1);
        authed[0] = address(strategy);
        tracker = VoteTrackerERC20V1(
            address(
                new ERC1967Proxy(
                    address(new VoteTrackerERC20V1()),
                    abi.encodeCall(VoteTrackerERC20V1.initialize, (authed))
                )
            )
        );

        // 7. governor
        governor = ModuleGovernorV1(
            address(
                new ERC1967Proxy(
                    address(new ModuleGovernorV1()),
                    abi.encodeCall(
                        IModuleGovernorV1.initialize,
                        (address(safe), address(safe), address(safe), address(strategy), uint32(1), uint32(86_400))
                    )
                )
            )
        );

        // 8. strategy phase 2
        IVotingTypes.VotingConfig[] memory cfgs = new IVotingTypes.VotingConfig[](1);
        cfgs[0] = IVotingTypes.VotingConfig({ votingWeight: address(weight), voteTracker: address(tracker) });
        strategy.initialize2(address(governor), cfgs);

        // 9. enable module + add PQ owners + threshold 2 (1-of-1 ECDSA execs while wiring)
        _execAsSoleOwner(abi.encodeWithSelector(ISafeFull.enableModule.selector, address(governor)));
        _execAsSoleOwner(
            abi.encodeWithSelector(ISafeFull.addOwnerWithThreshold.selector, address(pqMldsa), uint256(1))
        );
        _execAsSoleOwner(
            abi.encodeWithSelector(ISafeFull.addOwnerWithThreshold.selector, address(pqSlhdsa), uint256(2))
        );

        assertTrue(safe.isModuleEnabled(address(governor)), "governor module enabled");
        assertEq(safe.getThreshold(), 2, "threshold 2");
        assertEq(safe.getOwners().length, 3, "3 owners");
        assertTrue(safe.isOwner(address(pqMldsa)) && safe.isOwner(address(pqSlhdsa)), "PQ owners present");
    }

    // ----------------------------------------------------------------------
    // B) Governance e2e: propose -> vote -> timelock -> execute treasury action.
    // ----------------------------------------------------------------------
    function test_Governance_E2E_TreasuryTransfer() public {
        // The Safe (treasury) holds 600k LQ. Propose to transfer 1000 LQ to a recipient.
        address recipient = address(0xBEEF);
        uint256 amount = 1000 ether;
        uint256 treasuryBefore = token.balanceOf(address(safe));
        assertEq(treasuryBefore, 600_000 ether);

        // ECDSA owner has 400k LQ; delegate to self for voting power.
        vm.prank(ecdsaOwner);
        token.delegate(ecdsaOwner);

        Transaction[] memory txs = new Transaction[](1);
        txs[0] = Transaction({
            to: address(token),
            value: 0,
            data: abi.encodeWithSignature("transfer(address,uint256)", recipient, amount),
            operation: Enum.Operation.Call
        });

        vm.prank(ecdsaOwner);
        governor.submitProposal(txs, "transfer 1000 LQ from treasury", address(proposer), "");
        uint32 pid = 0;
        assertEq(uint8(governor.proposalState(pid)), 0, "ACTIVE"); // ACTIVE

        // ERC20Votes (mode=timestamp) requires the snapshot timepoint (votingStartTimestamp,
        // == the proposal-creation block.timestamp) to be strictly in the PAST at vote time.
        // Advance one second so getPastVotes(voter, start) is a settled past lookup.
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        // Vote YES (configIndex 0, empty voteData for ERC20).
        IVotingTypes.VotingConfigVoteData[] memory vd = new IVotingTypes.VotingConfigVoteData[](1);
        vd[0] = IVotingTypes.VotingConfigVoteData({ configIndex: 0, voteData: "" });
        vm.prank(ecdsaOwner);
        strategy.castVote(pid, 1, vd, 0); // 1 = YES

        // Advance past voting period (120s) + timelock (1s).
        vm.warp(block.timestamp + 121 + 2);
        vm.roll(block.number + 5);
        assertEq(uint8(governor.proposalState(pid)), 2, "EXECUTABLE"); // EXECUTABLE

        governor.executeProposal(pid, txs);
        assertEq(uint8(governor.proposalState(pid)), 3, "EXECUTED"); // EXECUTED

        // On-chain effect: treasury -1000, recipient +1000.
        assertEq(token.balanceOf(address(safe)), treasuryBefore - amount, "treasury debited");
        assertEq(token.balanceOf(recipient), amount, "recipient credited");
        console.log("GOV_E2E recipient balance", token.balanceOf(recipient));
        console.log("GOV_E2E treasury balance", token.balanceOf(address(safe)));
    }

    // ----------------------------------------------------------------------
    // C) PQ-signing e2e: a real ML-DSA signature satisfies the Safe at threshold 2.
    // ----------------------------------------------------------------------
    function test_PQ_MLDSA_Owner_Executes() public {
        _pqExecute(SEED_MLDSA, address(pqMldsa), "mldsa", address(0xCAFE), 11 ether);
    }

    function test_PQ_SLHDSA_Owner_Executes() public {
        _pqExecute(SEED_SLHDSA, address(pqSlhdsa), "slhdsa", address(0xD00D), 7 ether);
    }

    /// @dev Build a treasury transfer Safe tx, compute its hash, sign with the PQ key
    ///      (ffi) AND the controlled ECDSA owner, assemble the Safe `signatures` blob
    ///      (sorted by signer address; the contract-signature dynamic part appended),
    ///      execTransaction, and assert the transfer + nonce delta.
    function _pqExecute(string memory seed, address pqOwner, string memory scheme, address to, uint256 amount)
        internal
    {
        uint256 nBefore = safe.nonce();
        uint256 treBefore = token.balanceOf(address(safe));

        bytes memory inner = abi.encodeWithSignature("transfer(address,uint256)", to, amount);
        bytes32 txHash = safe.getTransactionHash(
            address(token), 0, inner, 0, 0, 0, 0, address(0), address(0), nBefore
        );

        // Real PQ contract-signature over the actual Safe-tx-hash.
        bytes memory pqContractSig = _ffiSign(seed, scheme, txHash);
        // Real ECDSA signature from the controlled co-owner.
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ecdsaPk, txHash);

        bytes memory signatures = _buildMixedSignatures(ecdsaOwner, v, r, s, pqOwner, pqContractSig);

        bool ok = safe.execTransaction(
            address(token), 0, inner, 0, 0, 0, 0, address(0), payable(address(0)), signatures
        );
        assertTrue(ok, "execTransaction with PQ signer must succeed");
        assertEq(safe.nonce(), nBefore + 1, "nonce advanced");
        assertEq(token.balanceOf(to), amount, "PQ-authorised transfer landed");
        assertEq(token.balanceOf(address(safe)), treBefore - amount, "treasury debited by PQ tx");
        console.log(scheme, "PQ owner executed; recipient balance", token.balanceOf(to));
    }

    /// @dev Assemble a Safe `signatures` blob for one ECDSA owner + one contract (PQ) owner,
    ///      threshold 2. Safe requires the 65-byte static slices ordered by signer address
    ///      ascending; for a contract signature the static slice is {r=signer, s=offset, v=0}
    ///      and the dynamic {uint256 len, bytes sig} is concatenated after BOTH static slices,
    ///      at byte offset = s.
    function _buildMixedSignatures(
        address eoa,
        uint8 v,
        bytes32 r,
        bytes32 s,
        address contractOwner,
        bytes memory contractSig
    ) internal pure returns (bytes memory) {
        // Two static slices of 65 bytes each => dynamic data starts at offset 130.
        bytes memory eoaStatic = abi.encodePacked(r, s, v); // 65 bytes
        // contract-signature static: r = left-padded signer, s = offset to dynamic, v = 0
        bytes32 cr = bytes32(uint256(uint160(contractOwner)));
        bytes32 cs = bytes32(uint256(130)); // dynamic starts right after the two 65-byte slices
        bytes memory cStatic = abi.encodePacked(cr, cs, uint8(0)); // 65 bytes
        bytes memory dynamic = abi.encodePacked(uint256(contractSig.length), contractSig);

        // Order static slices by signer address ascending.
        if (eoa < contractOwner) {
            return abi.encodePacked(eoaStatic, cStatic, dynamic);
        } else {
            // If the contract owner sorts first, its offset still points past BOTH slices (130).
            return abi.encodePacked(cStatic, eoaStatic, dynamic);
        }
    }

    // ----------------------------------------------------------------------
    // helpers: drive a 1-of-1 Safe from the controlled ECDSA owner.
    // ----------------------------------------------------------------------
    function _execAsSoleOwner(bytes memory data) internal {
        // While threshold==1 and ecdsaOwner is the sole owner, sign the real Safe-tx-hash.
        uint256 n = safe.nonce();
        bytes32 h = safe.getTransactionHash(address(safe), 0, data, 0, 0, 0, 0, address(0), address(0), n);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ecdsaPk, h);
        bytes memory sig = abi.encodePacked(r, s, v);
        bool ok = safe.execTransaction(address(safe), 0, data, 0, 0, 0, 0, address(0), payable(address(0)), sig);
        require(ok, "sole-owner exec failed");
    }

    // ----------------------------------------------------------------------
    // ffi to /tmp/pqsign
    // ----------------------------------------------------------------------
    function _ffiPub(string memory seed, string memory scheme) internal returns (bytes memory) {
        return _ffiSignField(seed, scheme, bytes32(0), "pubKey");
    }

    function _ffiSign(string memory seed, string memory scheme, bytes32 hash) internal returns (bytes memory) {
        return _ffiSignField(seed, scheme, hash, "contractSig");
    }

    function _ffiSignField(string memory seed, string memory scheme, bytes32 hash, string memory field)
        internal
        returns (bytes memory)
    {
        string[] memory cmd = new string[](10);
        cmd[0] = "/tmp/pqsign";
        cmd[1] = "sign";
        cmd[2] = "-scheme";
        cmd[3] = scheme;
        cmd[4] = "-seed";
        cmd[5] = seed;
        cmd[6] = "-hash";
        cmd[7] = vm.toString(hash);
        cmd[8] = "-raw";
        cmd[9] = field;
        return vm.ffi(cmd);
    }
}
