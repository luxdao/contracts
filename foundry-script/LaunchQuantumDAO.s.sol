// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.31;

import { Script, console } from "forge-std/Script.sol";

// --- DAO stack (consumed from luxfi/standard via remappings) ----------------
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

// --- PQ Safe-owner stack (consumed from luxfi/standard) ----------------------
import { PQSigner } from "@luxfi/standard/safe/pq/PQSigner.sol";
import { PQSchemes } from "@luxfi/standard/safe/pq/PQSchemes.sol";

// --- Safe infra (deployed fresh from the standard safe-smart-account lib) ----
import { SafeL2 } from "@safe-global/safe-smart-account/SafeL2.sol";
import { SafeProxyFactory } from "@safe-global/safe-smart-account/proxies/SafeProxyFactory.sol";
import { CompatibilityFallbackHandler } from "@safe-global/safe-smart-account/handler/CompatibilityFallbackHandler.sol";

// --- OZ proxy ---------------------------------------------------------------
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

interface ISafeMin {
    function getThreshold() external view returns (uint256);
    function isModuleEnabled(address module) external view returns (bool);
}

/**
 * @title LaunchQuantumDAO
 * @notice Launches the LUX QUANTUM DAO on the LIVE Lux testnet (EVM chainId 96368):
 *         a Decent/Zodiac-style modular DAO whose treasury Safe is guarded by a
 *         POST-QUANTUM owner set.
 *
 *  Components (the canonical luxdao stack):
 *    1. VotesERC20V1  "Lux Quantum" / LQ  — the governance token (ERC20Votes).
 *    2. A Gnosis Safe (deployed via the LIVE gnosisSafeProxyFactory) — treasury + executor.
 *       Final owner set = [deployer (ECDSA), PQSigner(ML-DSA-65), PQSigner(SLH-DSA-128f)],
 *       threshold = 2. The two PQSigners are EIP-1271 validators wrapping a single
 *       post-quantum public key each (the just-completed PQ-Safe-owner work).
 *    3. ModuleGovernorV1 — Zodiac module enabled on the Safe; executes passed proposals
 *       via execTransactionFromModule.
 *    4. StrategyV1 (+ VotingWeightERC20V1 weight, VoteTrackerERC20V1 tracker,
 *       ProposerAdapterERC20V1 proposer gate) — defines voting power / quorum / period.
 *
 *  Deployment model: a chain re-genesis invalidated the lux-testnet.json record — its
 *  addresses now hold unrelated code (verified on-chain: the "safe factory" / "voting"
 *  master-copy slots are AICoin ERC20s from a prior mining deploy; the governor/strategy/
 *  token master copies are empty). So this launch is FULLY SELF-CONTAINED: it deploys the
 *  Safe singleton + proxy factory + fallback handler fresh from the standard
 *  safe-smart-account lib, then deploys fresh UUPS implementations + an ERC1967Proxy per
 *  DAO component (the native pattern for these UUPS contracts). The Safe is created with
 *  the deployer as the sole owner (threshold 1) so the script can enable the governor
 *  module and wire the DAO atomically; the final step ADDS the two PQ owners and raises
 *  the threshold to 2, leaving the exact quantum owner set. The post-launch governance
 *  e2e (propose -> vote -> execute) and the PQ-signing proof (ML-DSA + SLH-DSA owners
 *  executing a Safe tx at threshold 2) are run by the companion fork test / shell driver.
 *
 *  PQ public keys are generated OFF-CHAIN by safe/test/pqgen/cmd/pqsign (real
 *  luxfi/crypto keys, framed exactly as the live precompiles parse them) and passed in
 *  via env: PQ_MLDSA_PUBKEY / PQ_SLHDSA_PUBKEY (hex). The PQSigner constructor re-derives
 *  and binds keccak256(pubkey), so a wrong key can never be silently substituted.
 *
 *  Run (mnemonic from env, never logged):
 *    forge script foundry-script/LaunchQuantumDAO.s.sol:LaunchQuantumDAO \
 *      --rpc-url lux_testnet --mnemonic "$LUX_MNEMONIC" --mnemonic-indexes 0 --broadcast
 */
contract LaunchQuantumDAO is Script {
    // --- token economics (testnet) ---
    uint256 constant INITIAL_SUPPLY = 1_000_000 ether; // 1,000,000 LQ
    uint256 constant TREASURY_ALLOC = 600_000 ether; // 60% to the treasury Safe
    uint256 constant DEPLOYER_ALLOC = 400_000 ether; // 40% to the deployer (voting power)

    // --- strategy params (testnet: short period, low quorum) ---
    uint32 constant VOTING_PERIOD = 120; // 120 seconds voting window
    uint256 constant QUORUM_THRESHOLD = 1 ether; // 1 LQ-vote min (YES+ABSTAIN)
    uint256 constant BASIS_NUMERATOR = 500_001; // > 50% YES of (YES+NO); valid [500000,999999)
    uint256 constant PROPOSER_THRESHOLD = 0; // anyone may propose (testnet)
    uint256 constant WEIGHT_PER_TOKEN = 1; // 1 token = 1 vote (raw)

    // --- governor params (testnet) ---
    uint32 constant TIMELOCK_PERIOD = 1; // 1 second timelock after voting
    uint32 constant EXECUTION_PERIOD = 86_400; // 1 day execution window

    function run() external {
        address deployer = vm.envAddress("PQ_DEPLOYER"); // set = the broadcasting address (asserted below)
        bytes memory mldsaPub = vm.envBytes("PQ_MLDSA_PUBKEY");
        bytes memory slhdsaPub = vm.envBytes("PQ_SLHDSA_PUBKEY");

        require(mldsaPub.length == 1952, "ML-DSA-65 pubkey must be 1952 bytes");
        require(slhdsaPub.length == 32, "SLH-DSA-128f pubkey must be 32 bytes");

        vm.startBroadcast();
        require(msg.sender == deployer, "broadcaster != PQ_DEPLOYER");

        // ----------------------------------------------------------------
        // 0. Safe infra (fresh — the chain re-genesis invalidated the old addresses).
        // ----------------------------------------------------------------
        address safeSingleton = address(new SafeL2());
        SafeProxyFactory safeFactory = new SafeProxyFactory();
        address fallbackHandler = address(new CompatibilityFallbackHandler());

        // ----------------------------------------------------------------
        // 1. PQ owners: one EIP-1271 PQSigner per scheme.
        // ----------------------------------------------------------------
        PQSigner pqMldsa = new PQSigner(PQSchemes.Scheme.ML_DSA, PQSchemes.MLDSA_65, mldsaPub);
        PQSigner pqSlhdsa = new PQSigner(PQSchemes.Scheme.SLH_DSA, PQSchemes.SLHDSA_SHA2_128F, slhdsaPub);

        // ----------------------------------------------------------------
        // 2. Treasury Safe via the fresh proxy factory. Deployer is sole owner
        //    (threshold 1) during wiring; PQ owners + threshold 2 added at the end.
        //    Deterministic salt per the governance.md convention.
        // ----------------------------------------------------------------
        address[] memory initialOwners = new address[](1);
        initialOwners[0] = deployer;

        bytes memory safeSetup = abi.encodeWithSignature(
            "setup(address[],uint256,address,bytes,address,address,uint256,address)",
            initialOwners,
            uint256(1), // threshold
            address(0), // to
            bytes(""), // data
            fallbackHandler,
            address(0), // paymentToken
            uint256(0), // payment
            address(0) // paymentReceiver
        );
        uint256 saltNonce = uint256(keccak256(abi.encode("lux", "quantum-dao", block.chainid)));
        address safe = address(safeFactory.createProxyWithNonce(safeSingleton, safeSetup, saltNonce));

        // ----------------------------------------------------------------
        // 3. Governance token: "Lux Quantum" / LQ. Split supply deployer/treasury.
        // ----------------------------------------------------------------
        IVotesERC20V1.Metadata memory md = IVotesERC20V1.Metadata({ name: "Lux Quantum", symbol: "LQ" });
        IVotesERC20V1.Allocation[] memory allocs = new IVotesERC20V1.Allocation[](2);
        allocs[0] = IVotesERC20V1.Allocation({ to: deployer, amount: DEPLOYER_ALLOC });
        allocs[1] = IVotesERC20V1.Allocation({ to: safe, amount: TREASURY_ALLOC });

        address tokenImpl = address(new VotesERC20V1());
        bytes memory tokenInit = abi.encodeCall(
            IVotesERC20V1.initialize,
            (md, allocs, safe, false, INITIAL_SUPPLY) // owner = Safe, unlocked, cap = initial supply
        );
        VotesERC20V1 token = VotesERC20V1(address(new ERC1967Proxy(tokenImpl, tokenInit)));

        // ----------------------------------------------------------------
        // 4. Proposer adapter (token-weighted gate; threshold 0 = open on testnet).
        // ----------------------------------------------------------------
        address proposerImpl = address(new ProposerAdapterERC20V1());
        bytes memory proposerInit =
            abi.encodeCall(ProposerAdapterERC20V1.initialize, (address(token), PROPOSER_THRESHOLD));
        ProposerAdapterERC20V1 proposer = ProposerAdapterERC20V1(address(new ERC1967Proxy(proposerImpl, proposerInit)));

        // ----------------------------------------------------------------
        // 5. Strategy (phase 1): voting period / quorum / basis + proposer adapters.
        //    strategyAdmin (the governor) is set in phase 2 (initialize2) below.
        // ----------------------------------------------------------------
        address[] memory proposers = new address[](1);
        proposers[0] = address(proposer);

        address strategyImpl = address(new StrategyV1());
        bytes memory strategyInit = abi.encodeCall(
            IStrategyV1.initialize,
            (VOTING_PERIOD, QUORUM_THRESHOLD, BASIS_NUMERATOR, proposers, address(0)) // no light-account factory
        );
        StrategyV1 strategy = StrategyV1(address(new ERC1967Proxy(strategyImpl, strategyInit)));

        // ----------------------------------------------------------------
        // 6. Voting weight (ERC20Votes -> weight) + vote tracker (strategy is the authorized caller).
        // ----------------------------------------------------------------
        address weightImpl = address(new VotingWeightERC20V1());
        bytes memory weightInit = abi.encodeCall(VotingWeightERC20V1.initialize, (address(token), WEIGHT_PER_TOKEN));
        VotingWeightERC20V1 weight = VotingWeightERC20V1(address(new ERC1967Proxy(weightImpl, weightInit)));

        address[] memory authedCallers = new address[](1);
        authedCallers[0] = address(strategy);
        address trackerImpl = address(new VoteTrackerERC20V1());
        bytes memory trackerInit = abi.encodeCall(VoteTrackerERC20V1.initialize, (authedCallers));
        VoteTrackerERC20V1 tracker = VoteTrackerERC20V1(address(new ERC1967Proxy(trackerImpl, trackerInit)));

        // ----------------------------------------------------------------
        // 7. Governor module: owner = Safe, avatar = target = Safe, strategy = strategy.
        // ----------------------------------------------------------------
        address govImpl = address(new ModuleGovernorV1());
        bytes memory govInit = abi.encodeCall(
            IModuleGovernorV1.initialize, (safe, safe, safe, address(strategy), TIMELOCK_PERIOD, EXECUTION_PERIOD)
        );
        ModuleGovernorV1 governor = ModuleGovernorV1(address(new ERC1967Proxy(govImpl, govInit)));

        // ----------------------------------------------------------------
        // 8. Strategy phase 2: bind the governor as strategyAdmin + register the voting config.
        // ----------------------------------------------------------------
        IVotingTypes.VotingConfig[] memory configs = new IVotingTypes.VotingConfig[](1);
        configs[0] = IVotingTypes.VotingConfig({ votingWeight: address(weight), voteTracker: address(tracker) });
        strategy.initialize2(address(governor), configs);

        // ----------------------------------------------------------------
        // 9. Enable the governor as a Safe module + add the PQ owners + threshold 2.
        //    The deployer is the sole owner (threshold 1), so each is one Safe tx
        //    signed by the deployer (pre-validated ECDSA "approved hash" style via
        //    the contract-call signature: r = owner, s = 0, v = 1).
        // ----------------------------------------------------------------
        _safeExec(safe, deployer, safe, abi.encodeWithSignature("enableModule(address)", address(governor)));
        _safeExec(
            safe,
            deployer,
            safe,
            abi.encodeWithSignature("addOwnerWithThreshold(address,uint256)", address(pqMldsa), uint256(1))
        );
        _safeExec(
            safe,
            deployer,
            safe,
            abi.encodeWithSignature("addOwnerWithThreshold(address,uint256)", address(pqSlhdsa), uint256(2))
        );

        // Post-wiring invariants (fail the broadcast if the quantum owner set is wrong).
        require(ISafeMin(safe).isModuleEnabled(address(governor)), "governor not enabled as module");
        require(ISafeMin(safe).getThreshold() == 2, "final threshold != 2");

        vm.stopBroadcast();

        // ----------------------------------------------------------------
        // Report — the broadcast + the shell driver grep these.
        // ----------------------------------------------------------------
        console.log("CHAIN_ID", block.chainid);
        console.log("DEPLOYER", deployer);
        console.log("SAFE_SINGLETON", safeSingleton);
        console.log("SAFE_FACTORY", address(safeFactory));
        console.log("SAFE_FALLBACK_HANDLER", fallbackHandler);
        console.log("QUANTUM_SAFE", safe);
        console.log("PQSIGNER_MLDSA", address(pqMldsa));
        console.log("PQSIGNER_SLHDSA", address(pqSlhdsa));
        console.log("TOKEN_LQ", address(token));
        console.log("GOVERNOR", address(governor));
        console.log("STRATEGY", address(strategy));
        console.log("VOTING_WEIGHT", address(weight));
        console.log("VOTE_TRACKER", address(tracker));
        console.log("PROPOSER_ADAPTER", address(proposer));
        console.log("SAFE_SALT_NONCE", saltNonce);
    }

    /**
     * @dev Execute `data` as a CALL from `safe` to `to`, signed by the single owner
     *      `owner` using the Safe pre-validated-signature scheme (the only owner is
     *      msg.sender, threshold 1): a 65-byte signature {r = owner, s = 0, v = 1}
     *      which `checkSignatures` accepts iff `msg.sender == owner` (approved-hash
     *      path with the executing owner). This is the canonical way to drive a 1-of-1
     *      Safe from the owner's EOA inside a broadcast without an off-chain signature.
     */
    function _safeExec(address safe, address owner, address to, bytes memory data) internal {
        bytes memory sig = abi.encodePacked(bytes32(uint256(uint160(owner))), bytes32(0), uint8(1));
        (bool ok,) = safe.call(
            abi.encodeWithSignature(
                "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)",
                to,
                uint256(0),
                data,
                uint8(0), // Operation.Call
                uint256(0),
                uint256(0),
                uint256(0),
                address(0),
                address(0),
                sig
            )
        );
        require(ok, "safe execTransaction failed");
    }
}
