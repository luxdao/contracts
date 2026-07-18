// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.31;

import { Script, console } from "forge-std/Script.sol";
import { WorkMarketDeployer } from "../contracts/deployables/bounty/WorkMarketDeployer.sol";
import { Escrow } from "../contracts/deployables/bounty/Escrow.sol";
import { Reputation } from "../contracts/deployables/bounty/Reputation.sol";
import { Bounty } from "../contracts/deployables/bounty/Bounty.sol";

/**
 * @title DeployWorkMarket
 * @notice Surgical, brand-neutral deploy of the finished work-market — Bounty / Escrow /
 *         Reputation + its global Karma stack (Karma + KarmaController) — as a fresh, fully
 *         wired instance owned by the org DAO Safe. Reuses the org's existing DAO-factory
 *         masters and any live Governor DAO (nothing else is touched), so it can SUPERSEDE a
 *         prior smoke work-market without disturbing the rest of the stack.
 *
 * @dev The whole market + Karma stack is stood up and self-verified inside ONE constructor
 *      (WorkMarketDeployer): escrow.controller = reputation.writer = the Bounty proxy;
 *      reputation -> KarmaController; KarmaController is the sole Karma ATTESTOR; Reputation is
 *      the sole KarmaController KARMA_SOURCE; ALL governance handed to the org Safe; the
 *      deployer renounces every transient role. A mis-wire reverts the whole deploy.
 *
 *  Owner / Karma-admin = the org DAO Safe, REQUIRED (DAO_TREASURY_SAFE). This script REFUSES
 *  to run without it — the work-market custodies value and mints global reputation, so its
 *  UUPS upgrade authority + Karma admin must never be a hot EOA.
 *
 *  Run (deployer key from KMS / k8s secret — NEVER inline a live key; fork-test first):
 *    DAO_TREASURY_SAFE=0x<orgDaoSafe> \
 *    forge script foundry-script/DeployWorkMarket.s.sol:DeployWorkMarket \
 *      --rpc-url <org-c-chain-rpc> --private-key "$DEPLOYER_KEY" --broadcast
 *
 *  Verified org DAO Safes (treasury targets):
 *    Zoo  200200 -> 0x229599f227231d8C90fcF1a78589F5DC4b7A6962
 *    Pars 494949 -> 0x4CEA4ac1C874a340B06e0422E77a477463C3a542
 *  NEVER broadcast this with the 0x9011 deployer on Lux 96369 (staged post-flag-day).
 *
 *  After deploy: run WorkMarketSmoke (BOUNTY=<new bounty>) to create+pay bounty 0 (the e2e
 *  asserts stateOf(0)==Paid), then update deployments/lux-dao/<chainId>.json + the e2e spec.
 */
contract DeployWorkMarket is Script {
    /// @notice Flat global-Karma award minted per accepted completion (Safe-retunable later).
    uint256 internal constant KARMA_PER_COMPLETION = 10e18;

    struct WorkMarket {
        address bounty;
        address escrow;
        address reputation;
        address karma;
        address karmaController;
    }

    function run() external returns (WorkMarket memory wm) {
        address daoSafe = vm.envAddress("DAO_TREASURY_SAFE");
        require(daoSafe != address(0), "DeployWorkMarket: DAO_TREASURY_SAFE required (Safe owns + admins the market)");
        require(daoSafe.code.length > 0, "DeployWorkMarket: DAO_TREASURY_SAFE has no code (not a deployed Safe)");

        vm.startBroadcast();
        wm = _deploy(daoSafe);
        vm.stopBroadcast();

        console.log("CHAIN_ID", block.chainid);
        console.log("DAO_SAFE", daoSafe);
        console.log("BOUNTY", wm.bounty);
        console.log("ESCROW", wm.escrow);
        console.log("REPUTATION", wm.reputation);
        console.log("KARMA", wm.karma);
        console.log("KARMA_CONTROLLER", wm.karmaController);
    }

    /**
     * @notice Pure deploy logic (no broadcast / no logging) so a fork test can drive the
     *         IDENTICAL deployment and assert the wiring before any broadcast.
     * @param daoSafe_ The org DAO Safe: work-market UUPS upgrade authority + Karma governance.
     */
    function _deploy(address daoSafe_) internal returns (WorkMarket memory wm) {
        // Deploy the three stateless (ownerless) impls, then wire a market over them. slashTreasury
        // == daoSafe: slashed stakes route to the org treasury (matches the canonical DeployDAO
        // owner/treasury model when a Safe is set).
        WorkMarketDeployer d = new WorkMarketDeployer(
            daoSafe_,
            daoSafe_,
            KARMA_PER_COMPLETION,
            address(new Escrow()),
            address(new Reputation()),
            address(new Bounty())
        );
        wm.bounty = d.bounty();
        wm.escrow = d.escrow();
        wm.reputation = d.reputation();
        wm.karma = d.karma();
        wm.karmaController = d.karmaController();
    }
}
