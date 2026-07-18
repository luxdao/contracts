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
import { ModuleFractalV1 } from "@luxfi/standard/dao/deployables/modules/ModuleFractalV1.sol";
import { SystemDeployerV1 } from "@luxfi/standard/dao/singletons/SystemDeployerV1.sol";

// --- Safe infra (deployed fresh from the standard safe-smart-account lib) -----
import { SafeL2 } from "@safe-global/safe-smart-account/SafeL2.sol";
import { SafeProxyFactory } from "@safe-global/safe-smart-account/proxies/SafeProxyFactory.sol";
import { CompatibilityFallbackHandler } from "@safe-global/safe-smart-account/handler/CompatibilityFallbackHandler.sol";

// --- Work market (lives in THIS repo, not in standard) ------------------------
// The Escrow/Reputation/Bounty instance is stood up atomically + wired ON-CHAIN by a
// single constructor (WorkMarketDeployer), so no EOA-nonce prediction is trusted here.
import { WorkMarketDeployer } from "../contracts/deployables/bounty/WorkMarketDeployer.sol";
import { Escrow } from "../contracts/deployables/bounty/Escrow.sol";
import { Reputation } from "../contracts/deployables/bounty/Reputation.sol";
import { Bounty } from "../contracts/deployables/bounty/Bounty.sol";

/**
 * @title DeployDAO
 * @notice THE canonical, brand-neutral luxdao platform deploy (LP-040). It deploys the
 *         create-a-DAO factory masters every DAO's proxies reference, plus one live,
 *         fully-wired permissionless work-market instance for the deploying org.
 *
 *  LP-040 (White-Label DAO Deployment Pattern): there is ONE deploy script, not a
 *  per-brand copy. Lux, Zoo, Hanzo, Pars and every future brand run THIS script against a
 *  different `--rpc-url` / chain ID. No brand is baked into bytecode — only the chain it
 *  runs on. Brand identity lives at the edge (hostname → `config/<brand>.json`), never in
 *  the contracts. The contracts come from a single audited tree (luxfi/standard); the
 *  work-market (Bounty/Escrow/Reputation) is the one app-level composition local to this
 *  platform repo.
 *
 *  What it deploys, and why:
 *
 *   (A) DAO-FACTORY MASTERS — the master copies the app's "anyone creates a DAO" flow
 *       references. A DAO is assembled at create time as proxies pointing at these shared
 *       implementations, so they are deployed ONCE here:
 *         - Safe singleton (SafeL2) + SafeProxyFactory + CompatibilityFallbackHandler.
 *           A chain re-genesis invalidated any prior canonical Safe addresses, so these
 *           are deployed fresh from the standard safe-smart-account lib. The factory is
 *           what the app calls to mint each DAO's treasury Safe.
 *         - VotesERC20V1, ModuleGovernorV1, ModuleFractalV1, StrategyV1,
 *           VotingWeightERC20V1, VoteTrackerERC20V1, ProposerAdapterERC20V1 — the
 *           Zodiac/Decent-style DAO module + voting stack, deployed as bare master
 *           copies (NOT initialized; a master holds no DAO state — each DAO's proxy is
 *           initialized at create time by the app against the per-DAO token / Safe /
 *           params). ModuleFractalV1 is the parent↔child sub-DAO primitive: a product
 *           sub-DAO is a child Safe governed by a Fractal module under the parent, so
 *           "create a sub-DAO for a product, fund it, pay people" needs no new contract.
 *         - SystemDeployerV1 — the create-a-DAO orchestrator: a live singleton whose
 *           deployProxy(impl, initData, salt) mints + initializes each DAO's proxies
 *           deterministically. This is the on-chain half of the lux.cloud "deploy-a-DAO"
 *           flow.
 *
 *   (B) WORK-MARKET — the headline two-sided market (post a task -> claim -> deliver ->
 *       PAID on acceptance, escrow released, reputation recorded, global Karma minted).
 *       Rewards may be native / ERC-20 / ERC-721 / ERC-1155. Deployed as a single canonical
 *       instance (Bounty/Escrow/Reputation + Karma/KarmaController) for the deploying org by
 *       the atomic, self-verifying WorkMarketDeployer: Escrow's controller and Reputation's
 *       writer must BOTH be the Bounty proxy (a cycle broken by predicting the Bounty proxy
 *       address and wiring escrow/reputation at the prediction), and Reputation is wired as
 *       the sole KARMA_SOURCE on the KarmaController. The app may later deploy additional
 *       per-sub-DAO work-market instances the same way; this ships one live now.
 *
 *  Run against a target chain (deployer key from env / KMS — NEVER inline a live key):
 *    forge script foundry-script/DeployDAO.s.sol:DeployDAO \
 *      --rpc-url <chain-rpc> --private-key "$DEPLOYER_KEY" --broadcast
 *
 *  Run the proof against local anvil with anvil's PUBLIC test key:
 *    forge script foundry-script/DeployDAO.s.sol:DeployDAO \
 *      --rpc-url http://127.0.0.1:8545 \
 *      --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --broadcast
 *
 *  Owner / treasury: the work-market owner (UUPS upgrade authority) is the org treasury
 *  Safe passed via env DAO_TREASURY_SAFE, or the deployer by default; the slash treasury
 *  is that same Safe when set, otherwise address(0) (slash routes to funder).
 */
contract DeployDAO is Script {
    /// @notice Addresses of every contract this script deploys (returned + logged).
    struct Deployment {
        // Safe infra (DAO-factory masters).
        address safeSingleton;
        address safeFactory;
        address fallbackHandler;
        // DAO module + voting masters.
        address votesErc20Master;
        address moduleGovernorMaster;
        address moduleFractalMaster;
        address strategyMaster;
        address votingWeightMaster;
        address voteTrackerMaster;
        address proposerAdapterMaster;
        // Create-a-DAO orchestrator (live singleton).
        address systemDeployer;
        // Work-market live instance (proxies) + its global Karma stack.
        address bounty;
        address escrow;
        address reputation;
        address karma;
        address karmaController;
    }

    /**
     * @notice Flat global-Karma award minted per accepted bounty completion (18 decimals).
     * @dev Decoupled from the reward amount (rewards span native/ERC-20/ERC-721/ERC-1155 with
     *      incommensurable units). The org Safe retunes it post-deploy via
     *      Reputation.setKarmaPerCompletion. 10 Karma/completion => ~100 completions to the
     *      1000-Karma soft cap; a sane, Sybil-resistant default.
     */
    uint256 internal constant KARMA_PER_COMPLETION = 10e18;

    function run() external returns (Deployment memory d) {
        // owner = the work-market upgrade authority + default treasury route. The org
        // treasury Safe when set (the LP-040 "staged Safe proposals" model), else the
        // deployer. Named brand-neutrally: any brand passes its own Safe. On a PRODUCTION
        // chain an unset Safe is REFUSED (M3): never hand mainnet UUPS upgrade authority to
        // the deployer EOA by silent fallback.
        address treasurySafe = vm.envOr("DAO_TREASURY_SAFE", address(0));
        (address owner, address slashTreasury) = _resolveOwnerAndTreasury(block.chainid, treasurySafe, msg.sender);

        // Under `forge script --broadcast`, every CREATE originates from the EOA
        // (msg.sender). The work-market's internal wiring no longer depends on the EOA
        // nonce — WorkMarketDeployer deploys + verifies it on-chain — so no address
        // prediction is trusted here.
        vm.startBroadcast();

        d = _deploy(owner, slashTreasury);

        vm.stopBroadcast();

        // ----------------------------------------------------------------
        // REPORT — the shell driver + the config/<brand>.json updater grep these labels.
        // ----------------------------------------------------------------
        console.log("CHAIN_ID", block.chainid);
        // (A) DAO-factory masters -> config/<brand>.json contracts{}.
        console.log("SAFE_SINGLETON", d.safeSingleton); //             safeSingleton
        console.log("SAFE_FACTORY", d.safeFactory); //                 safeFactory
        console.log("SAFE_FALLBACK_HANDLER", d.fallbackHandler); //    fallbackHandler
        console.log("VOTES_ERC20_MASTER", d.votesErc20Master); //      votesErc20Master
        console.log("MODULE_GOVERNOR_MASTER", d.moduleGovernorMaster); // moduleGovernor
        console.log("MODULE_FRACTAL_MASTER", d.moduleFractalMaster); // moduleFractal (sub-DAO)
        console.log("STRATEGY_MASTER", d.strategyMaster); //           strategyMaster
        console.log("VOTING_WEIGHT_MASTER", d.votingWeightMaster); //  votingWeightMaster
        console.log("VOTE_TRACKER_MASTER", d.voteTrackerMaster); //    voteTrackerMaster
        console.log("PROPOSER_ADAPTER_MASTER", d.proposerAdapterMaster); // proposerAdapterMaster
        console.log("SYSTEM_DEPLOYER", d.systemDeployer); //           systemDeployer (create-flow)
        // (B) Work-market live instance + global Karma stack.
        console.log("BOUNTY", d.bounty);
        console.log("ESCROW", d.escrow);
        console.log("REPUTATION", d.reputation);
        console.log("KARMA", d.karma);
        console.log("KARMA_CONTROLLER", d.karmaController);
    }

    /**
     * @notice Deploys the full stack. Pure deploy logic (no broadcast / no logging) so
     *         the companion fork test can drive the IDENTICAL deployment and assert the
     *         live e2e against it.
     * @param owner_ The work-market UUPS upgrade authority (deployer or a treasury Safe).
     * @param slashTreasury_ Where slashed stakes route (address(0) => to the funder).
     */
    function _deploy(address owner_, address slashTreasury_) internal returns (Deployment memory d) {
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
        d.moduleFractalMaster = address(new ModuleFractalV1());
        d.strategyMaster = address(new StrategyV1());
        d.votingWeightMaster = address(new VotingWeightERC20V1());
        d.voteTrackerMaster = address(new VoteTrackerERC20V1());
        d.proposerAdapterMaster = address(new ProposerAdapterERC20V1());

        // ----------------------------------------------------------------
        // (A.3) Create-a-DAO orchestrator — a live singleton (NOT a master copy).
        // ----------------------------------------------------------------
        d.systemDeployer = address(new SystemDeployerV1());

        // ----------------------------------------------------------------
        // (B) Work-market live instance + global Karma stack — atomic, self-wiring,
        //     verified ON-CHAIN. One constructor deploys Karma + KarmaController + the 3
        //     impls + 3 proxies, wires escrow.controller = reputation.writer = the Bounty
        //     proxy AND reputation -> KarmaController (Reputation is the sole KARMA_SOURCE,
        //     KarmaController is the sole Karma ATTESTOR), hands all governance to the org
        //     Safe, renounces the deployer's transient authority, and reverts if any wiring
        //     is wrong. No EOA-nonce prediction is trusted: the internal CREATEs are the
        //     deployer contract's, deterministic regardless of the outer EOA nonce.
        // ----------------------------------------------------------------
        WorkMarketDeployer wm = new WorkMarketDeployer(
            owner_,
            slashTreasury_,
            KARMA_PER_COMPLETION,
            address(new Escrow()),
            address(new Reputation()),
            address(new Bounty())
        );
        d.bounty = wm.bounty();
        d.escrow = wm.escrow();
        d.reputation = wm.reputation();
        d.karma = wm.karma();
        d.karmaController = wm.karmaController();
    }

    // ======================================================================
    // Owner / treasury resolution (M3 production-chain guard)
    // ======================================================================

    /// @notice Production chain ids where an EOA MUST NOT be the work-market upgrade authority.
    /// @dev Lux (96369), Zoo (200200), Hanzo (36963), Pars (494949). Read dynamically from
    ///      block.chainid — no id is baked into bytecode (LP-040 neutrality).
    function _isProductionChain(uint256 chainId_) internal pure returns (bool) {
        return chainId_ == 96369 || chainId_ == 200200 || chainId_ == 36963 || chainId_ == 494949;
    }

    /**
     * @notice Resolves the work-market owner + slash treasury from the env-provided Safe.
     * @dev M3 guard: on a PRODUCTION chain, REFUSE to fall back to the deployer EOA as the
     *      UUPS upgrade authority. An unset DAO_TREASURY_SAFE there would silently hand
     *      mainnet upgrade power to a hot key (an EOA that can `upgradeToAndCall` the market
     *      and drain escrow). Testnet/local may fall back to the deployer for convenience.
     *      Pure so it is unit-testable without a broadcast.
     * @param chainId_ The target chain id (block.chainid).
     * @param treasurySafe_ The env-provided org treasury Safe (address(0) if unset).
     * @param deployer_ The deploying account (fallback owner on non-production chains).
     * @return owner_ The UUPS upgrade authority for the work-market proxies.
     * @return slashTreasury_ Where slashed stakes route (address(0) => to the funder).
     */
    function _resolveOwnerAndTreasury(
        uint256 chainId_,
        address treasurySafe_,
        address deployer_
    ) internal pure returns (address owner_, address slashTreasury_) {
        if (treasurySafe_ == address(0)) {
            if (_isProductionChain(chainId_)) {
                revert("DeployDAO: DAO_TREASURY_SAFE required on production chain (refusing EOA upgrade authority)");
            }
            return (deployer_, address(0)); // testnet/local: deployer owns, slash-to-funder.
        }
        return (treasurySafe_, treasurySafe_);
    }
}
