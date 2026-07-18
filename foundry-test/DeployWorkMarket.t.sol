// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.31;

import { Test } from "forge-std/Test.sol";
import { DeployWorkMarket } from "../foundry-script/DeployWorkMarket.s.sol";
import { Bounty } from "../contracts/deployables/bounty/Bounty.sol";
import { Escrow } from "../contracts/deployables/bounty/Escrow.sol";
import { Reputation } from "../contracts/deployables/bounty/Reputation.sol";
import { Karma } from "@luxfi/standard/governance/Karma.sol";
import { KarmaController } from "@luxfi/standard/governance/KarmaController.sol";

/**
 * @title DeployWorkMarketLive
 * @notice Proof that the surgical supersede script (DeployWorkMarket) stands up a fully wired
 *         work-market + Karma stack owned entirely by the org DAO Safe — the exact deploy the
 *         runbook broadcasts to Zoo 200200 / Pars 494949. Drives the script's own _deploy so
 *         the test exercises the IDENTICAL logic, using a code-bearing address as the Safe
 *         stand-in (the script requires the Safe to have code).
 */
contract DeployWorkMarketLive is Test, DeployWorkMarket {
    function test_Deploy_WiresEverythingToTheSafe() public {
        // A distinct org-Safe stand-in (the WorkMarketDeployer's own constructor already
        // VERIFIES on-chain that it retained no role — OwnershipHandoffFailed — so a
        // successful _deploy is itself the proof the deployer holds nothing).
        address safe = address(0x5AFE);
        WorkMarket memory wm = _deploy(safe);

        Bounty b = Bounty(wm.bounty);
        Escrow e = Escrow(payable(wm.escrow));
        Reputation r = Reputation(wm.reputation);
        Karma k = Karma(wm.karma);
        KarmaController c = KarmaController(wm.karmaController);

        // Market cycle wired + owned by the Safe; slashes route to the Safe treasury.
        assertEq(e.controller(), wm.bounty, "escrow controller == bounty");
        assertEq(r.writer(), wm.bounty, "reputation writer == bounty");
        assertEq(r.karmaController(), wm.karmaController, "reputation -> controller");
        assertEq(b.owner(), safe, "bounty owner == safe");
        assertEq(e.owner(), safe, "escrow owner == safe");
        assertEq(r.owner(), safe, "reputation owner == safe");
        assertEq(b.treasury(), safe, "slash treasury == safe");

        // Karma least-privilege: Reputation is the sole earn source, controller the sole
        // attestor, the Safe the sole admin, and this deployer script holds NOTHING.
        assertTrue(c.hasRole(c.KARMA_SOURCE_ROLE(), wm.reputation), "rep is KARMA_SOURCE");
        assertTrue(k.hasRole(k.ATTESTOR_ROLE(), wm.karmaController), "controller is ATTESTOR");
        assertTrue(k.hasRole(0x00, safe), "safe is karma admin");
        assertTrue(c.hasRole(0x00, safe), "safe is controller admin");
        // Only the Reputation ledger may mint global Karma (a random address cannot).
        assertFalse(c.hasRole(c.KARMA_SOURCE_ROLE(), address(0xBEEF)), "random addr is not a source");
    }
}
