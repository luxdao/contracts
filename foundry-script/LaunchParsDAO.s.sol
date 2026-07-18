// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.31;

import { Script, console } from "forge-std/Script.sol";

// --- DAO stack types (consumed from luxfi/standard via remappings) ----------
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

// --- OZ proxy ---------------------------------------------------------------
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

interface IProxyFactory {
    function createProxyWithNonce(address singleton, bytes calldata initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

interface ISafeMin {
    function getThreshold() external view returns (uint256);
    function isOwner(address owner) external view returns (bool);
    function isModuleEnabled(address module) external view returns (bool);
}

/**
 * @title LaunchParsDAO
 * @notice Launches the PARS DAO — a real token-voting governance DAO with one live
 *         proposal — on the LIVE Pars Network (sovereign L1 EVM chainId 494949).
 *
 *  This is the ECDSA-only sibling of LaunchQuantumDAO.s.sol: same canonical luxdao
 *  Decent/Zodiac stack, but the treasury Safe owner set is the single deployer EOA
 *  (0x9011, threshold 1) — NO post-quantum owners. It exists to give pars.vote a real,
 *  featured DAO with a real, renderable proposal (the "prove a proposal renders"
 *  deliverable), not to demonstrate PQ signing.
 *
 *  DRY reuse (LP-040): the create-a-DAO factory MASTERS are already deployed on Pars
 *  (by DeployDAO.s.sol — recorded in deployments/lux-dao/494949.json). A DAO is assembled
 *  as fresh ERC1967 proxies pointing at those shared, audited master implementations, so
 *  this script deploys NO duplicate implementation bytecode — it only mints per-DAO
 *  proxies + a fresh treasury Safe (via the already-deployed Safe singleton/factory) and
 *  wires them. Single source of truth for impl bytecode.
 *
 *  What it does, atomically, as the sole owner 0x9011:
 *    1. Mint a fresh treasury Safe (0x9011 sole owner, threshold 1) via the deployed
 *       SafeProxyFactory + singleton.
 *    2. Deploy the governance token "Pars Governance"/vePARS (VotesERC20V1 proxy),
 *       splitting supply: a voting stake to the deployer, the treasury to the Safe.
 *    3. Deploy the proposer-adapter / strategy / voting-weight / vote-tracker / governor
 *       proxies and wire them (strategy.initialize2 binds the governor as strategyAdmin).
 *    4. enableModule(governor) on the Safe (1-of-1 pre-validated owner signature).
 *    5. delegate(deployer) so the deployer's vePARS become live voting power that clears
 *       the (meaningful, non-zero) proposer threshold.
 *    6. submitProposal(...) — ONE real governance proposal (a founding/signal proposal:
 *       a zero-value self-call payload + human-readable JSON metadata). Leaves it ACTIVE
 *       (30-day voting window) so pars.vote renders it live.
 *
 *  Invariants (revert the run — dry-run OR broadcast — if the DAO is malformed):
 *    - governor enabled as a Safe module,
 *    - Safe threshold == 1 and deployer is an owner,
 *    - governor.totalProposalCount() == 1,
 *    - proposal 0 state == ACTIVE.
 *
 *  Run the DRY-RUN gate first (no key, no txs — pure simulation against live 494949 state):
 *    PARS_DEPLOYER=0x9011E888251AB053B7bD1cdB598Db4f9DEd94714 \
 *    forge script foundry-script/LaunchParsDAO.s.sol:LaunchParsDAO \
 *      --rpc-url pars --sender 0x9011E888251AB053B7bD1cdB598Db4f9DEd94714
 *
 *  Only AFTER the dry-run passes, broadcast live (key from KMS-backed k8s secret; --slow;
 *  a generous CLI timeout — --slow waits for each receipt):
 *    PARS_DEPLOYER=0x9011E888251AB053B7bD1cdB598Db4f9DEd94714 \
 *    forge script foundry-script/LaunchParsDAO.s.sol:LaunchParsDAO \
 *      --rpc-url pars --private-key "$KEY" --broadcast --slow
 */
contract LaunchParsDAO is Script {
    // --- reused DAO-factory masters, deployed on Pars 494949 (deployments/lux-dao/494949.json) ---
    address constant VOTES_ERC20_MASTER = 0x09fDF9b9dAeAc933fd55f9Bcc714c754C21bDc43;
    address constant MODULE_GOVERNOR_MASTER = 0x62Ea1B27CDD922dbAaE0572f4CD4862Ca939C24c;
    address constant STRATEGY_MASTER = 0xa24318F24739d92a2e1c2997C18F5103d0fD708e;
    address constant VOTING_WEIGHT_MASTER = 0xB6BdC625f4B2877418D7A9773F8A5763c93EfbaC;
    address constant VOTE_TRACKER_MASTER = 0xFd57A578A0Ff600B5420D1964aC7A80f0E08B1ad;
    address constant PROPOSER_ADAPTER_MASTER = 0x905b1907d4b8262B220A7aF7ad0a375F3A2F05cb;
    address constant SAFE_SINGLETON = 0xDc384E006BAec602b0b2B2fe6f2712646EFb1e9D;
    address constant SAFE_FACTORY = 0x191067f88d61f9506555E88CEab9CF71deeD61A9;
    address constant SAFE_FALLBACK_HANDLER = 0xDE3df926c7E0a380270B1F75F8dd1f238e16224b;

    // --- token economics (Pars) ---
    uint256 constant INITIAL_SUPPLY = 100_000_000 ether; // 100,000,000 vePARS cap
    uint256 constant DEPLOYER_ALLOC = 10_000_000 ether; //  10% -> deployer (voting power)
    uint256 constant TREASURY_ALLOC = 90_000_000 ether; //  90% -> treasury Safe

    // --- strategy / proposer params ---
    uint32 constant VOTING_PERIOD = 2_592_000; // 30-day voting window (proposal renders ACTIVE)
    uint256 constant QUORUM_THRESHOLD = 1_000_000 ether; // 1,000,000 vePARS-vote quorum
    uint256 constant BASIS_NUMERATOR = 500_001; // > 50% YES of (YES+NO); valid [500000,999999)
    uint256 constant PROPOSER_THRESHOLD = 100_000 ether; // 100,000 vePARS delegated to propose
    uint256 constant WEIGHT_PER_TOKEN = 1; // 1 token = 1 vote (raw)

    // --- governor params ---
    uint32 constant TIMELOCK_PERIOD = 1; // 1 second timelock after voting
    uint32 constant EXECUTION_PERIOD = 604_800; // 7-day execution window

    function run() external {
        address deployer = vm.envAddress("PARS_DEPLOYER");

        vm.startBroadcast();
        require(msg.sender == deployer, "broadcaster != PARS_DEPLOYER");

        // ----------------------------------------------------------------
        // 1. Treasury Safe via the already-deployed proxy factory + singleton.
        //    Deployer is the sole owner (threshold 1) so this script can enable
        //    the governor module in a single pre-validated-owner Safe tx.
        // ----------------------------------------------------------------
        address[] memory initialOwners = new address[](1);
        initialOwners[0] = deployer;

        bytes memory safeSetup = abi.encodeWithSignature(
            "setup(address[],uint256,address,bytes,address,address,uint256,address)",
            initialOwners,
            uint256(1), // threshold
            address(0), // to
            bytes(""), // data
            SAFE_FALLBACK_HANDLER,
            address(0), // paymentToken
            uint256(0), // payment
            address(0) // paymentReceiver
        );
        // Salt-tag is env-overridable so a re-run after an interrupted broadcast can
        // pick a fresh Safe address (the CREATE2 Safe is the only collidable address;
        // every other component is a CREATE proxy with a fresh nonce-derived address).
        string memory saltTag = vm.envOr("PARS_SALT_TAG", string("genesis"));
        uint256 saltNonce = uint256(keccak256(abi.encode("pars-dao", saltTag, block.chainid)));
        address safe = IProxyFactory(SAFE_FACTORY).createProxyWithNonce(SAFE_SINGLETON, safeSetup, saltNonce);

        // ----------------------------------------------------------------
        // 2. Governance token: "Pars Governance" / vePARS (VotesERC20V1 proxy).
        // ----------------------------------------------------------------
        IVotesERC20V1.Metadata memory md = IVotesERC20V1.Metadata({ name: "Pars Governance", symbol: "vePARS" });
        IVotesERC20V1.Allocation[] memory allocs = new IVotesERC20V1.Allocation[](2);
        allocs[0] = IVotesERC20V1.Allocation({ to: deployer, amount: DEPLOYER_ALLOC });
        allocs[1] = IVotesERC20V1.Allocation({ to: safe, amount: TREASURY_ALLOC });

        bytes memory tokenInit = abi.encodeCall(
            IVotesERC20V1.initialize,
            (md, allocs, safe, false, INITIAL_SUPPLY) // owner = Safe, unlocked, cap = initial supply
        );
        VotesERC20V1 token = VotesERC20V1(address(new ERC1967Proxy(VOTES_ERC20_MASTER, tokenInit)));

        // ----------------------------------------------------------------
        // 3. Proposer adapter (token-weighted gate) -> strategy -> weight + tracker -> governor.
        // ----------------------------------------------------------------
        bytes memory proposerInit =
            abi.encodeCall(ProposerAdapterERC20V1.initialize, (address(token), PROPOSER_THRESHOLD));
        ProposerAdapterERC20V1 proposer =
            ProposerAdapterERC20V1(address(new ERC1967Proxy(PROPOSER_ADAPTER_MASTER, proposerInit)));

        address[] memory proposers = new address[](1);
        proposers[0] = address(proposer);
        bytes memory strategyInit = abi.encodeCall(
            IStrategyV1.initialize, (VOTING_PERIOD, QUORUM_THRESHOLD, BASIS_NUMERATOR, proposers, address(0))
        );
        StrategyV1 strategy = StrategyV1(address(new ERC1967Proxy(STRATEGY_MASTER, strategyInit)));

        bytes memory weightInit = abi.encodeCall(VotingWeightERC20V1.initialize, (address(token), WEIGHT_PER_TOKEN));
        VotingWeightERC20V1 weight = VotingWeightERC20V1(address(new ERC1967Proxy(VOTING_WEIGHT_MASTER, weightInit)));

        address[] memory authedCallers = new address[](1);
        authedCallers[0] = address(strategy);
        bytes memory trackerInit = abi.encodeCall(VoteTrackerERC20V1.initialize, (authedCallers));
        VoteTrackerERC20V1 tracker = VoteTrackerERC20V1(address(new ERC1967Proxy(VOTE_TRACKER_MASTER, trackerInit)));

        bytes memory govInit = abi.encodeCall(
            IModuleGovernorV1.initialize, (safe, safe, safe, address(strategy), TIMELOCK_PERIOD, EXECUTION_PERIOD)
        );
        ModuleGovernorV1 governor = ModuleGovernorV1(address(new ERC1967Proxy(MODULE_GOVERNOR_MASTER, govInit)));

        // ----------------------------------------------------------------
        // 4. Strategy phase 2: bind the governor as strategyAdmin + register voting config.
        // ----------------------------------------------------------------
        IVotingTypes.VotingConfig[] memory configs = new IVotingTypes.VotingConfig[](1);
        configs[0] = IVotingTypes.VotingConfig({ votingWeight: address(weight), voteTracker: address(tracker) });
        strategy.initialize2(address(governor), configs);

        // ----------------------------------------------------------------
        // 5. Enable the governor as a Safe module (1-of-1 pre-validated owner signature).
        // ----------------------------------------------------------------
        _safeExec(safe, deployer, safe, abi.encodeWithSignature("enableModule(address)", address(governor)));

        // ----------------------------------------------------------------
        // 6. Deployer self-delegates -> live voting power that clears the proposer gate.
        // ----------------------------------------------------------------
        token.delegate(deployer);

        // ----------------------------------------------------------------
        // 7. Submit ONE real governance proposal. Payload = a zero-value self-call to the
        //    Safe (a harmless signal payload); the human-readable intent lives in metadata.
        // ----------------------------------------------------------------
        Transaction[] memory txs = new Transaction[](1);
        txs[0] = Transaction({ to: safe, value: 0, data: bytes(""), operation: Enum.Operation.Call });

        string memory metadata = string(
            abi.encodePacked(
                '{"title":"Ratify the Pars DAO Founding Charter",',
                '"description":"Genesis proposal of the Pars DAO on the Pars Network (chain 494949). ',
                "It ratifies vePARS (Pars Governance) as the governance token and the token-voting ",
                "ModuleGovernor + Strategy stack as the DAO's on-chain decision process, with the ",
                "treasury Safe as executor. A YES vote affirms the founding charter. This is a signal ",
                'proposal: its transaction is a zero-value self-call, recording founding intent on-chain ',
                'without moving treasury funds."}'
            )
        );

        governor.submitProposal(txs, metadata, address(proposer), "");

        // ----------------------------------------------------------------
        // Post-wiring invariants — fail the run (dry-run OR broadcast) if malformed.
        // ----------------------------------------------------------------
        require(ISafeMin(safe).isModuleEnabled(address(governor)), "governor not enabled as module");
        require(ISafeMin(safe).getThreshold() == 1, "safe threshold != 1");
        require(ISafeMin(safe).isOwner(deployer), "deployer not a safe owner");
        require(governor.totalProposalCount() == 1, "totalProposalCount != 1");
        require(uint8(governor.proposalState(0)) == 0, "proposal 0 not ACTIVE"); // 0 == ACTIVE

        vm.stopBroadcast();

        // ----------------------------------------------------------------
        // REPORT — the shell driver greps these labels into the deployment record.
        // ----------------------------------------------------------------
        console.log("CHAIN_ID", block.chainid);
        console.log("DEPLOYER", deployer);
        console.log("PARS_SAFE", safe);
        console.log("TOKEN_VEPARS", address(token));
        console.log("GOVERNOR", address(governor));
        console.log("STRATEGY", address(strategy));
        console.log("VOTING_WEIGHT", address(weight));
        console.log("VOTE_TRACKER", address(tracker));
        console.log("PROPOSER_ADAPTER", address(proposer));
        console.log("SAFE_SALT_NONCE", saltNonce);
        console.log("PROPOSAL_ID", uint256(0));
        console.log("TOTAL_PROPOSAL_COUNT", uint256(governor.totalProposalCount()));
    }

    /**
     * @dev Execute `data` as a CALL from `safe` to `to`, signed by the single owner `owner`
     *      using the Safe pre-validated-signature scheme (the only owner is msg.sender,
     *      threshold 1): a 65-byte signature {r = owner, s = 0, v = 1} which `checkSignatures`
     *      accepts iff `msg.sender == owner`. The canonical way to drive a 1-of-1 Safe from
     *      the owner's EOA inside a broadcast without an off-chain signature.
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
