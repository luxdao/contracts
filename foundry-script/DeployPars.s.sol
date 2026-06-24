// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.31;

import { Script, console } from "forge-std/Script.sol";

// --- DAO stack masters (consumed from luxfi/standard via remappings) ---------
import { VotesERC20V1 } from "@luxfi/standard/dao/deployables/erc20/VotesERC20V1.sol";
import { StrategyV1 } from "@luxfi/standard/dao/deployables/strategies/StrategyV1.sol";
import { VotingWeightERC20V1 } from "@luxfi/standard/dao/deployables/strategies/voting-weight/VotingWeightERC20V1.sol";
import { VoteTrackerERC20V1 } from "@luxfi/standard/dao/deployables/strategies/vote-trackers/VoteTrackerERC20V1.sol";
import { ProposerAdapterERC20V1 } from "@luxfi/standard/dao/deployables/strategies/proposer-adapters/ProposerAdapterERC20V1.sol";
import { ModuleGovernorV1 } from "@luxfi/standard/dao/deployables/modules/ModuleGovernorV1.sol";

// --- Safe infra (deployed fresh from the standard safe-smart-account lib) -----
import { SafeL2 } from "@safe-global/safe-smart-account/SafeL2.sol";
import { SafeProxyFactory } from "@safe-global/safe-smart-account/proxies/SafeProxyFactory.sol";
import { CompatibilityFallbackHandler } from "@safe-global/safe-smart-account/handler/CompatibilityFallbackHandler.sol";

// --- Work market (lives in THIS repo, not in standard) ------------------------
import { BountyV1 } from "../contracts/deployables/bounty/BountyV1.sol";
import { EscrowV1 } from "../contracts/deployables/bounty/EscrowV1.sol";
import { ReputationV1 } from "../contracts/deployables/bounty/ReputationV1.sol";

// --- OZ proxy ----------------------------------------------------------------
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title DeployPars
 * @notice Deploys the CANONICAL luxdao platform stack for the Pars sovereign L1
 *         (EVM chainId 494949): the DAO-factory masters the create-a-DAO flow proxies
 *         against, plus one live, fully-wired permissionless work-market instance.
 *
 *  The core contracts are brand-neutral luxdao; the Pars deployment is white-labeled
 *  as "Pars" on pars.vote — no brand is baked into bytecode, only the chain it runs on.
 *
 *  What it deploys, and why:
 *
 *   (A) DAO-FACTORY MASTERS — the master copies the app's "anyone creates a DAO"
 *       flow references. A DAO is assembled at create time as proxies pointing at
 *       these shared implementations, so they are deployed ONCE here:
 *         - Safe singleton (SafeL2) + SafeProxyFactory + CompatibilityFallbackHandler.
 *           A chain re-genesis invalidated any prior canonical Safe addresses, so these
 *           are deployed fresh from the standard safe-smart-account lib (exactly as
 *           LaunchQuantumDAO does). The factory is what the app calls to mint each
 *           DAO's treasury Safe.
 *         - VotesERC20V1, ModuleGovernorV1, StrategyV1, VotingWeightERC20V1,
 *           VoteTrackerERC20V1, ProposerAdapterERC20V1 — the Zodiac/Decent-style DAO
 *           module + voting stack, deployed as bare master copies (NOT initialized;
 *           a master copy holds no DAO state — each DAO's proxy is initialized at
 *           create time by the app against the per-DAO token / Safe / params).
 *       These populate the pars.ts `contracts{}` slots (see REPORT in run()).
 *
 *   (B) WORK-MARKET — the headline two-sided market (post a task -> claim -> deliver
 *       -> PAID on acceptance, escrow released, reputation recorded). Deployed as a
 *       single canonical instance for the Pars DAO using the predict-then-wire pattern:
 *       EscrowV1's controller and ReputationV1's writer must BOTH be the BountyV1 proxy,
 *       but BountyV1 needs the escrow + reputation addresses to initialize — a cycle.
 *       It is broken by predicting the BountyV1 proxy address (CREATE is deterministic
 *       in deployer + nonce), pointing escrow/reputation at the prediction, then
 *       deploying the BountyV1 proxy into exactly that slot. The app may later deploy
 *       additional per-DAO work-market instances the same way; this ships one live now.
 *
 *  Run against Pars (deployer key from env / KMS — NEVER inline a live key):
 *    forge script foundry-script/DeployPars.s.sol:DeployPars \
 *      --rpc-url https://rpc.pars.network --private-key "$PARS_DEPLOYER_KEY" --broadcast
 *
 *  Run the proof against local anvil (forked at 494949) with anvil's PUBLIC test key:
 *    forge script foundry-script/DeployPars.s.sol:DeployPars \
 *      --rpc-url http://127.0.0.1:8545 \
 *      --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --broadcast
 *
 *  Owner / treasury: the work-market owner (UUPS upgrade authority) is the deployer by
 *  default, or a passed PARS treasury Safe via env PARS_TREASURY_SAFE; the slash
 *  treasury is that same Safe when set, otherwise address(0) (slash routes to funder).
 */
contract DeployPars is Script {
    /// @notice Pars sovereign L1 — EVM chainId == primary networkID (494949).
    uint256 internal constant PARS_CHAIN_ID = 494949;

    /// @notice Addresses of every contract this script deploys (returned + logged).
    struct Deployment {
        // Safe infra (DAO-factory masters).
        address safeSingleton;
        address safeFactory;
        address fallbackHandler;
        // DAO module + voting masters.
        address votesErc20Master;
        address moduleGovernorMaster;
        address strategyMaster;
        address votingWeightMaster;
        address voteTrackerMaster;
        address proposerAdapterMaster;
        // Work-market live instance (proxies).
        address bounty;
        address escrow;
        address reputation;
    }

    function run() external returns (Deployment memory d) {
        // owner = the work-market upgrade authority + default treasury route. The
        // deployer by default; override with a Pars treasury Safe when one exists.
        address treasurySafe = vm.envOr("PARS_TREASURY_SAFE", address(0));
        address owner = treasurySafe == address(0) ? msg.sender : treasurySafe;
        address slashTreasury = treasurySafe; // address(0) => slash-to-funder.

        // Under `forge script --broadcast`, every CREATE originates from the EOA
        // (msg.sender); forge forbids relying on the ephemeral script address, and
        // vm.computeCreateAddress(msg.sender, ...) matches the broadcast CREATEs exactly.
        vm.startBroadcast();

        d = _deploy(msg.sender, owner, slashTreasury);

        vm.stopBroadcast();

        // ----------------------------------------------------------------
        // REPORT — the shell driver + the pars.ts update grep these labels.
        // ----------------------------------------------------------------
        console.log("CHAIN_ID", block.chainid);
        // (A) DAO-factory masters -> pars.ts contracts{}.
        console.log("SAFE_SINGLETON", d.safeSingleton); //            gnosisSafeL2Singleton
        console.log("SAFE_FACTORY", d.safeFactory); //                gnosisSafeProxyFactory
        console.log("SAFE_FALLBACK_HANDLER", d.fallbackHandler); //   compatibilityFallbackHandler
        console.log("VOTES_ERC20_MASTER", d.votesErc20Master); //     votesErc20MasterCopy
        console.log("MODULE_GOVERNOR_MASTER", d.moduleGovernorMaster); // moduleGovernorMasterCopy
        console.log("STRATEGY_MASTER", d.strategyMaster); //          linearVotingErc20V1MasterCopy / strategyMasterCopy
        console.log("VOTING_WEIGHT_MASTER", d.votingWeightMaster); // votingWeightErc20MasterCopy
        console.log("VOTE_TRACKER_MASTER", d.voteTrackerMaster); //   voteTrackerErc20MasterCopy
        console.log("PROPOSER_ADAPTER_MASTER", d.proposerAdapterMaster); // proposerAdapterErc20MasterCopy
        // (B) Work-market live instance.
        console.log("BOUNTY_V1", d.bounty);
        console.log("ESCROW_V1", d.escrow);
        console.log("REPUTATION_V1", d.reputation);
    }

    /**
     * @notice Deploys the full stack. Pure deploy logic (no broadcast / no logging) so
     *         the companion fork test can drive the IDENTICAL deployment and assert the
     *         live e2e against it.
     * @param deployer_ The account that actually performs the CREATEs (the EOA under
     *        `forge script`, or the calling contract under a fork test); used only to
     *        predict the BountyV1 proxy address for the wiring cycle.
     * @param owner_ The work-market UUPS upgrade authority (deployer or a treasury Safe).
     * @param slashTreasury_ Where slashed stakes route (address(0) => to the funder).
     */
    function _deploy(
        address deployer_,
        address owner_,
        address slashTreasury_
    ) internal returns (Deployment memory d) {
        // ----------------------------------------------------------------
        // (A.1) Safe infra — fresh (re-genesis invalidated any prior addresses).
        // ----------------------------------------------------------------
        d.safeSingleton = address(new SafeL2());
        d.safeFactory = address(new SafeProxyFactory());
        d.fallbackHandler = address(new CompatibilityFallbackHandler());

        // ----------------------------------------------------------------
        // (A.2) DAO module + voting masters — bare master copies (NOT initialized).
        //       Each DAO's create-flow deploys proxies pointing here and initializes
        //       THOSE with the per-DAO token / Safe / params.
        // ----------------------------------------------------------------
        d.votesErc20Master = address(new VotesERC20V1());
        d.moduleGovernorMaster = address(new ModuleGovernorV1());
        d.strategyMaster = address(new StrategyV1());
        d.votingWeightMaster = address(new VotingWeightERC20V1());
        d.voteTrackerMaster = address(new VoteTrackerERC20V1());
        d.proposerAdapterMaster = address(new ProposerAdapterERC20V1());

        // ----------------------------------------------------------------
        // (B) Work-market live instance — predict-then-wire.
        // ----------------------------------------------------------------
        (d.bounty, d.escrow, d.reputation) = _deployWorkMarket(deployer_, owner_, slashTreasury_);
    }

    /**
     * @notice Deploys + wires one EscrowV1 / ReputationV1 / BountyV1 instance.
     * @dev Breaks the escrow<->bounty and reputation<->bounty wiring cycle by predicting
     *      the BountyV1 proxy's CREATE address from `deployer_` (the CREATE origin). At
     *      entry the deployer is at some nonce N; the next CREATEs are, in order:
     *        N   escrow impl
     *        N+1 reputation impl
     *        N+2 bounty impl
     *        N+3 escrow proxy
     *        N+4 reputation proxy
     *        N+5 BountyV1 proxy   <-- predicted, pointed-to by escrow & reputation
     *      so the bounty proxy lands at computeCreateAddress(deployer_, N + 5).
     *      Escrow.initialize(owner, controller=bounty); Reputation.initialize(owner,
     *      writer=bounty); Bounty.initialize(owner, escrow, reputation, treasury).
     * @param deployer_ The CREATE origin (EOA under script; calling contract under test).
     * @return bounty The BountyV1 proxy (controller of escrow, writer of reputation).
     * @return escrow The EscrowV1 proxy (custody).
     * @return reputation The ReputationV1 proxy (history).
     */
    function _deployWorkMarket(
        address deployer_,
        address owner_,
        address treasury_
    ) internal returns (address bounty, address escrow, address reputation) {
        // The BountyV1 proxy is the 6th CREATE from here: 3 impls + escrow proxy +
        // reputation proxy precede it, so it is created at the deployer's nonce + 5.
        address predictedBounty = vm.computeCreateAddress(deployer_, vm.getNonce(deployer_) + 5);

        EscrowV1 escrowImpl = new EscrowV1();
        ReputationV1 repImpl = new ReputationV1();
        BountyV1 bountyImpl = new BountyV1();

        escrow = address(
            new ERC1967Proxy(
                address(escrowImpl),
                abi.encodeCall(EscrowV1.initialize, (owner_, predictedBounty))
            )
        );
        reputation = address(
            new ERC1967Proxy(
                address(repImpl),
                abi.encodeCall(ReputationV1.initialize, (owner_, predictedBounty))
            )
        );
        bounty = address(
            new ERC1967Proxy(
                address(bountyImpl),
                abi.encodeCall(BountyV1.initialize, (owner_, escrow, reputation, treasury_))
            )
        );

        // Fail the deploy if the prediction or wiring is wrong (never ship a market
        // whose escrow/reputation are pointed at the wrong controller/writer).
        require(bounty == predictedBounty, "DeployPars: bounty address prediction failed");
        require(EscrowV1(payable(escrow)).controller() == bounty, "DeployPars: escrow controller != bounty");
        require(ReputationV1(reputation).writer() == bounty, "DeployPars: reputation writer != bounty");
    }
}
