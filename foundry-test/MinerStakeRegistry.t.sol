// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {MinerStakeRegistry} from "../contracts/deployables/thinking/MinerStakeRegistry.sol";

contract MinerStakeRegistryTest is Test {
    MinerStakeRegistry reg;
    address constant DAO = address(0xDA0);
    address constant SLASHER = address(0x5);
    address constant MINER = address(0xABCD);
    address constant CHALLENGER = address(0xC);

    uint256 constant MIN_BOND = 1 ether;
    uint256 constant BOND_PER_UNIT = 0.1 ether; // 0.1 ETH per declared compute unit
    uint64 constant COOLDOWN = 7 days;

    function setUp() public {
        reg = new MinerStakeRegistry(MIN_BOND, BOND_PER_UNIT, COOLDOWN, DAO);
        vm.prank(DAO);
        reg.setSlasher(SLASHER);
        vm.deal(MINER, 100 ether);
    }

    // bond ~ capacity -> eligible.
    function test_BondProportionalToCapacity_Eligible() public {
        vm.prank(MINER);
        reg.bond{value: 1 ether}(10); // 10 units * 0.1 = 1 ETH, meets floor
        assertTrue(reg.eligible(MINER), "bonded in proportion to capacity -> eligible");
        assertEq(reg.bonded(MINER), 1 ether);
    }

    function test_Underbonded_Rejected() public {
        vm.prank(MINER);
        vm.expectRevert(MinerStakeRegistry.Underbonded.selector);
        reg.bond{value: 1 ether}(20); // 20 units needs 2 ETH, only 1 sent
    }

    // AUTOMATED SLASHING: the fraud verifier slashes; the challenger is paid; a fleeing miner can't dodge.
    function test_SlashByFraudVerifier_PaysChallenger() public {
        vm.prank(MINER);
        reg.bond{value: 5 ether}(10);
        uint256 before = CHALLENGER.balance;
        vm.prank(SLASHER);
        reg.slash(MINER, 2 ether, CHALLENGER);
        assertEq(reg.bonded(MINER), 3 ether, "bond reduced by the slash");
        assertEq(CHALLENGER.balance, before + 2 ether, "challenger paid the slashed bond");
    }

    function test_OnlySlasherCanSlash() public {
        vm.prank(MINER);
        reg.bond{value: 5 ether}(10);
        vm.prank(address(0xBAD));
        vm.expectRevert(MinerStakeRegistry.NotSlasher.selector);
        reg.slash(MINER, 1 ether, CHALLENGER);
    }

    // the cooldown exists so a miner cannot exit ahead of a fraud proof.
    function test_CannotFleeFraudDuringCooldown() public {
        vm.prank(MINER);
        reg.bond{value: 5 ether}(10);
        vm.prank(MINER);
        reg.requestUnbond();
        assertFalse(reg.eligible(MINER), "a miner exiting is immediately ineligible");
        // can't withdraw yet
        vm.prank(MINER);
        vm.expectRevert(MinerStakeRegistry.CoolingDown.selector);
        reg.withdraw();
        // but it CAN still be slashed during the cooldown
        vm.prank(SLASHER);
        reg.slash(MINER, 5 ether, CHALLENGER);
        assertEq(reg.bonded(MINER), 0, "fraud caught the fleeing miner");
    }

    function test_WithdrawAfterCooldown() public {
        vm.prank(MINER);
        reg.bond{value: 3 ether}(10);
        vm.prank(MINER);
        reg.requestUnbond();
        vm.warp(block.timestamp + COOLDOWN + 1);
        uint256 before = MINER.balance;
        vm.prank(MINER);
        reg.withdraw();
        assertEq(MINER.balance, before + 3 ether, "bond returned after the fraud window");
        assertEq(reg.bonded(MINER), 0);
    }

    // GOVERNANCE: blacklist removes eligibility and blocks re-bonding.
    function test_GovernanceBlacklist() public {
        vm.prank(MINER);
        reg.bond{value: 2 ether}(10);
        assertTrue(reg.eligible(MINER));
        vm.prank(DAO);
        reg.setBlacklist(MINER, true);
        assertFalse(reg.eligible(MINER), "blacklisted -> ineligible");
        vm.prank(MINER);
        vm.expectRevert(MinerStakeRegistry.Blacklisted_.selector);
        reg.bond{value: 1 ether}(5); // can't re-bond while blacklisted
    }

    function test_OnlyAdminGoverns() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(MinerStakeRegistry.NotAdmin.selector);
        reg.setBlacklist(MINER, true);
    }
}
