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

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

interface ISafeFull {
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
    function nonce() external view returns (uint256);
    function getThreshold() external view returns (uint256);
    function isOwner(address owner) external view returns (bool);
    function isModuleEnabled(address module) external view returns (bool);
}

interface IProxyFactory {
    function createProxyWithNonce(address singleton, bytes calldata initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

/**
 * @title LaunchParsDAOLive
 * @notice Forks LIVE Pars 494949 and proves — against the REAL on-chain DAO-factory
 *         masters + REAL Safe singleton/factory (deployments/lux-dao/494949.json) — the
 *         EXACT bootstrap LaunchParsDAO.s.sol broadcasts: reuse the masters via fresh
 *         proxies, mint a 1-of-1 treasury Safe, wire the token-voting governor stack,
 *         enable the module, delegate, and CREATE ONE REAL PROPOSAL.
 *
 *         This is the pre-broadcast gate. It uses a controlled test EOA as the sole Safe
 *         owner (so it can produce a real ECDSA Safe signature); the live broadcast uses
 *         the funded 0x9011 owner via the pre-validated-signature path. The deployment +
 *         proposal logic — and every asserted invariant — are identical.
 *
 *         Run: forge test --match-contract LaunchParsDAOLive -vv
 */
contract LaunchParsDAOLive is Test {
    // Reused DAO-factory masters + Safe infra, deployed on Pars 494949.
    address constant VOTES_ERC20_MASTER = 0x09fDF9b9dAeAc933fd55f9Bcc714c754C21bDc43;
    address constant MODULE_GOVERNOR_MASTER = 0x62Ea1B27CDD922dbAaE0572f4CD4862Ca939C24c;
    address constant STRATEGY_MASTER = 0xa24318F24739d92a2e1c2997C18F5103d0fD708e;
    address constant VOTING_WEIGHT_MASTER = 0xB6BdC625f4B2877418D7A9773F8A5763c93EfbaC;
    address constant VOTE_TRACKER_MASTER = 0xFd57A578A0Ff600B5420D1964aC7A80f0E08B1ad;
    address constant PROPOSER_ADAPTER_MASTER = 0x905b1907d4b8262B220A7aF7ad0a375F3A2F05cb;
    address constant SAFE_SINGLETON = 0xDc384E006BAec602b0b2B2fe6f2712646EFb1e9D;
    address constant SAFE_FACTORY = 0x191067f88d61f9506555E88CEab9CF71deeD61A9;
    address constant SAFE_FALLBACK_HANDLER = 0xDE3df926c7E0a380270B1F75F8dd1f238e16224b;

    uint256 constant INITIAL_SUPPLY = 100_000_000 ether;
    uint256 constant DEPLOYER_ALLOC = 10_000_000 ether;
    uint256 constant TREASURY_ALLOC = 90_000_000 ether;
    uint32 constant VOTING_PERIOD = 2_592_000;
    uint256 constant QUORUM_THRESHOLD = 1_000_000 ether;
    uint256 constant BASIS_NUMERATOR = 500_001;
    uint256 constant PROPOSER_THRESHOLD = 100_000 ether;
    uint256 constant WEIGHT_PER_TOKEN = 1;
    uint32 constant TIMELOCK_PERIOD = 1;
    uint32 constant EXECUTION_PERIOD = 604_800;

    uint256 ownerPk = 0xA11CE; // controlled sole-owner EOA (test-only)
    address owner;

    VotesERC20V1 token;
    ISafeFull safe;
    ModuleGovernorV1 governor;
    StrategyV1 strategy;
    VotingWeightERC20V1 weight;
    VoteTrackerERC20V1 tracker;
    ProposerAdapterERC20V1 proposer;

    function setUp() public {
        vm.createSelectFork("pars");
        owner = vm.addr(ownerPk);
        _deployParsDAO();
    }

    function _deployParsDAO() internal {
        // 1. Treasury Safe — reuse deployed factory + singleton; controlled EOA sole owner.
        address[] memory owners = new address[](1);
        owners[0] = owner;
        bytes memory setup = abi.encodeWithSignature(
            "setup(address[],uint256,address,bytes,address,address,uint256,address)",
            owners,
            uint256(1),
            address(0),
            bytes(""),
            SAFE_FALLBACK_HANDLER,
            address(0),
            uint256(0),
            address(0)
        );
        // Test-specific salt (owner EOA) => distinct CREATE2 address from the live script's Safe.
        uint256 saltNonce = uint256(keccak256(abi.encode("pars-dao-forktest", owner, block.chainid)));
        safe = ISafeFull(IProxyFactory(SAFE_FACTORY).createProxyWithNonce(SAFE_SINGLETON, setup, saltNonce));

        // 2. Token vePARS.
        IVotesERC20V1.Metadata memory md = IVotesERC20V1.Metadata({ name: "Pars Governance", symbol: "vePARS" });
        IVotesERC20V1.Allocation[] memory allocs = new IVotesERC20V1.Allocation[](2);
        allocs[0] = IVotesERC20V1.Allocation({ to: owner, amount: DEPLOYER_ALLOC });
        allocs[1] = IVotesERC20V1.Allocation({ to: address(safe), amount: TREASURY_ALLOC });
        token = VotesERC20V1(
            address(
                new ERC1967Proxy(
                    VOTES_ERC20_MASTER,
                    abi.encodeCall(IVotesERC20V1.initialize, (md, allocs, address(safe), false, INITIAL_SUPPLY))
                )
            )
        );

        // 3. proposer -> strategy -> weight + tracker -> governor.
        proposer = ProposerAdapterERC20V1(
            address(
                new ERC1967Proxy(
                    PROPOSER_ADAPTER_MASTER,
                    abi.encodeCall(ProposerAdapterERC20V1.initialize, (address(token), PROPOSER_THRESHOLD))
                )
            )
        );
        address[] memory pa = new address[](1);
        pa[0] = address(proposer);
        strategy = StrategyV1(
            address(
                new ERC1967Proxy(
                    STRATEGY_MASTER,
                    abi.encodeCall(
                        IStrategyV1.initialize, (VOTING_PERIOD, QUORUM_THRESHOLD, BASIS_NUMERATOR, pa, address(0))
                    )
                )
            )
        );
        weight = VotingWeightERC20V1(
            address(
                new ERC1967Proxy(
                    VOTING_WEIGHT_MASTER,
                    abi.encodeCall(VotingWeightERC20V1.initialize, (address(token), WEIGHT_PER_TOKEN))
                )
            )
        );
        address[] memory authed = new address[](1);
        authed[0] = address(strategy);
        tracker = VoteTrackerERC20V1(
            address(
                new ERC1967Proxy(
                    VOTE_TRACKER_MASTER, abi.encodeCall(VoteTrackerERC20V1.initialize, (authed))
                )
            )
        );
        governor = ModuleGovernorV1(
            address(
                new ERC1967Proxy(
                    MODULE_GOVERNOR_MASTER,
                    abi.encodeCall(
                        IModuleGovernorV1.initialize,
                        (address(safe), address(safe), address(safe), address(strategy), TIMELOCK_PERIOD, EXECUTION_PERIOD)
                    )
                )
            )
        );

        // 4. strategy phase 2.
        IVotingTypes.VotingConfig[] memory cfgs = new IVotingTypes.VotingConfig[](1);
        cfgs[0] = IVotingTypes.VotingConfig({ votingWeight: address(weight), voteTracker: address(tracker) });
        strategy.initialize2(address(governor), cfgs);

        // 5. enable module (real 1-of-1 owner signature).
        _execAsSoleOwner(abi.encodeWithSignature("enableModule(address)", address(governor)));
    }

    function test_ParsDAO_Bootstrap_CreatesOneActiveProposal() public {
        // Wiring invariants.
        assertTrue(safe.isModuleEnabled(address(governor)), "governor module enabled");
        assertEq(safe.getThreshold(), 1, "safe threshold 1");
        assertTrue(safe.isOwner(owner), "deployer is safe owner");
        assertEq(token.balanceOf(owner), DEPLOYER_ALLOC, "deployer token stake");
        assertEq(token.balanceOf(address(safe)), TREASURY_ALLOC, "treasury token stake");

        // Delegate -> proposer power clears the (non-zero) proposer gate.
        vm.prank(owner);
        token.delegate(owner);
        assertGe(token.getVotes(owner), PROPOSER_THRESHOLD, "deployer clears proposer threshold");

        // Submit the ONE real proposal.
        Transaction[] memory txs = new Transaction[](1);
        txs[0] = Transaction({ to: address(safe), value: 0, data: bytes(""), operation: Enum.Operation.Call });
        string memory metadata = '{"title":"Ratify the Pars DAO Founding Charter","description":"Genesis proposal."}';

        assertEq(governor.totalProposalCount(), 0, "no proposals before");
        vm.prank(owner);
        governor.submitProposal(txs, metadata, address(proposer), "");

        // THE deliverable assertions.
        assertEq(governor.totalProposalCount(), 1, "totalProposalCount == 1");
        assertEq(uint8(governor.proposalState(0)), 0, "proposal 0 ACTIVE");

        (address pStrategy, bytes32[] memory pTxHashes,,,) = governor.getProposal(0);
        assertEq(pStrategy, address(strategy), "proposal strategy bound");
        assertEq(pTxHashes.length, 1, "proposal has 1 tx");

        console.log("PARS_SAFE", address(safe));
        console.log("GOVERNOR", address(governor));
        console.log("TOKEN_VEPARS", address(token));
        console.log("TOTAL_PROPOSAL_COUNT", uint256(governor.totalProposalCount()));
        console.log("PROPOSAL_0_STATE_ACTIVE(0)", uint256(uint8(governor.proposalState(0))));
    }

    /// @dev Drive the 1-of-1 Safe from the controlled owner using a real ECDSA signature.
    function _execAsSoleOwner(bytes memory data) internal {
        uint256 n = safe.nonce();
        bytes32 h = safe.getTransactionHash(address(safe), 0, data, 0, 0, 0, 0, address(0), address(0), n);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, h);
        bytes memory sig = abi.encodePacked(r, s, v);
        bool ok = safe.execTransaction(address(safe), 0, data, 0, 0, 0, 0, address(0), payable(address(0)), sig);
        require(ok, "sole-owner exec failed");
    }
}
