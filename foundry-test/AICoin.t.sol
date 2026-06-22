// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {AICoin} from "../contracts/deployables/thinking/AICoin.sol";

/// @notice The native coin's Bitcoin-shaped issuance: a 1B hard cap, a subsidy
/// that halves every four years, fair-mined by useful cognition with no pre-mine,
/// and a burn that makes the coin deflationary once the cap is reached.
contract AICoinTest is Test {
    AICoin coin;
    address constant DAO = address(0xDA0);
    address constant SETTLEMENT = address(0x5E771E);
    address constant NODE = address(0xA1);

    uint256 g0; // genesis
    uint256 PERIOD;
    uint256 MAX;

    function setUp() public {
        // warp off zero so GENESIS is a realistic timestamp
        vm.warp(1_700_000_000);
        coin = new AICoin("AI", "AI", DAO, SETTLEMENT);
        g0 = coin.GENESIS();
        PERIOD = coin.HALVING_PERIOD();
        MAX = coin.MAX_SUBSIDY();
    }

    // ---- no pre-mine; starts at zero -----------------------------------------
    function test_NoPremine() public view {
        assertEq(coin.totalSupply(), 0);
        assertEq(coin.mintedSubsidy(), 0);
        assertEq(coin.cumulativeAllowance(), 0, "allowed(GENESIS) must be 0");
        assertEq(coin.emissionAllowance(), 0);
        assertEq(MAX, 1_000_000_000 ether);
        assertEq(PERIOD, 4 * 365 days);
    }

    // ---- the halving schedule is exact ---------------------------------------
    function test_HalvingScheduleExact() public {
        // epoch 0 subsidy is MAX/2; each epoch halves it
        assertEq(coin.epochSubsidy(), MAX / 2, "E_0 = MAX/2");
        vm.warp(g0 + PERIOD);
        assertEq(coin.epoch(), 1);
        assertEq(coin.epochSubsidy(), MAX / 4, "E_1 = MAX/4");
        vm.warp(g0 + 2 * PERIOD);
        assertEq(coin.epoch(), 2);
        assertEq(coin.epochSubsidy(), MAX / 8, "E_2 = MAX/8");
    }

    // ---- cumulative allowance vests linearly, halving slope, -> MAX ----------
    function test_CumulativeAllowanceCurve() public {
        // halfway through epoch 0: allowed = MAX/4 (half of E_0)
        vm.warp(g0 + PERIOD / 2);
        assertEq(coin.cumulativeAllowance(), MAX / 4, "mid-epoch-0 = MAX/4");
        // end of epoch 0 / start of epoch 1: allowed = MAX/2
        vm.warp(g0 + PERIOD);
        assertEq(coin.cumulativeAllowance(), MAX / 2, "epoch boundary = MAX/2");
        // end of epoch 1: allowed = 3/4 MAX
        vm.warp(g0 + 2 * PERIOD);
        assertEq(coin.cumulativeAllowance(), (3 * MAX) / 4, "after 2 epochs = 3/4 MAX");
        // end of epoch 2: 7/8 MAX
        vm.warp(g0 + 3 * PERIOD);
        assertEq(coin.cumulativeAllowance(), (7 * MAX) / 8, "after 3 epochs = 7/8 MAX");
        // far future: converges to MAX, never exceeds
        vm.warp(g0 + 200 * PERIOD);
        assertEq(coin.cumulativeAllowance(), MAX, "converges to MAX");
    }

    function test_MonotoneNonDecreasing() public {
        uint256 prev = coin.cumulativeAllowance();
        for (uint256 i = 1; i <= 40; i++) {
            vm.warp(g0 + (i * PERIOD) / 4); // quarter-epoch steps
            uint256 cur = coin.cumulativeAllowance();
            assertGe(cur, prev, "allowance must be monotone");
            assertLe(cur, MAX, "allowance must never exceed MAX");
            prev = cur;
        }
    }

    // ---- only the settlement (minter) may mint -------------------------------
    function test_OnlyMinterMints() public {
        vm.warp(g0 + PERIOD / 2);
        vm.expectRevert(AICoin.NotMinter.selector);
        coin.mintSubsidy(NODE, 1 ether); // msg.sender = test, not minter

        vm.prank(SETTLEMENT);
        coin.mintSubsidy(NODE, 1 ether);
        assertEq(coin.balanceOf(NODE), 1 ether);
    }

    // ---- minting is bounded by the schedule ----------------------------------
    function test_MintBoundedBySchedule() public {
        vm.warp(g0 + PERIOD / 2); // allowed = MAX/4
        assertEq(coin.emissionAllowance(), MAX / 4);

        vm.prank(SETTLEMENT);
        vm.expectRevert(abi.encodeWithSelector(AICoin.ExceedsEmissionAllowance.selector, MAX / 4 + 1, MAX / 4));
        coin.mintSubsidy(NODE, MAX / 4 + 1);

        // mint exactly the allowance, then nothing more until time advances
        vm.prank(SETTLEMENT);
        coin.mintSubsidy(NODE, MAX / 4);
        assertEq(coin.emissionAllowance(), 0);
        assertEq(coin.mintedSubsidy(), MAX / 4);

        vm.prank(SETTLEMENT);
        vm.expectRevert(abi.encodeWithSelector(AICoin.ExceedsEmissionAllowance.selector, 1, 0));
        coin.mintSubsidy(NODE, 1);

        // advancing time unlocks more
        vm.warp(g0 + PERIOD); // allowed = MAX/2
        assertEq(coin.emissionAllowance(), MAX / 2 - MAX / 4);
    }

    // ---- the entire 1B is fair-mineable, and not a wei more ------------------
    function test_FairMineEntireCapThenFeesOnly() public {
        vm.warp(g0 + 200 * PERIOD); // schedule fully unlocked
        assertEq(coin.cumulativeAllowance(), MAX);
        assertEq(coin.emissionAllowance(), MAX);

        vm.prank(SETTLEMENT);
        coin.mintSubsidy(NODE, MAX);
        assertEq(coin.totalSupply(), MAX, "entire 1B mined");
        assertEq(coin.mintedSubsidy(), MAX);
        assertEq(coin.remainingSubsidy(), 0, "no subsidy left -> fees only");

        // not one wei more, ever
        vm.prank(SETTLEMENT);
        vm.expectRevert(abi.encodeWithSelector(AICoin.ExceedsEmissionAllowance.selector, 1, 0));
        coin.mintSubsidy(NODE, 1);
    }

    // ---- burn makes it deflationary once the cap is mined --------------------
    function test_DeflationaryAfterCap() public {
        vm.warp(g0 + 200 * PERIOD);
        vm.prank(SETTLEMENT);
        coin.mintSubsidy(NODE, MAX);
        assertEq(coin.totalSupply(), MAX);

        // fee burn (EIP-1559-style): supply permanently shrinks below the cap
        uint256 burnAmt = 10_000 ether;
        vm.prank(NODE);
        coin.burn(burnAmt);
        assertEq(coin.totalSupply(), MAX - burnAmt, "burn shrinks supply");

        // no subsidy can ever replace burned coin -> net deflation is permanent
        assertEq(coin.emissionAllowance(), 0);
        vm.prank(SETTLEMENT);
        vm.expectRevert(abi.encodeWithSelector(AICoin.ExceedsEmissionAllowance.selector, burnAmt, 0));
        coin.mintSubsidy(NODE, burnAmt);
    }

    // ---- governance can rotate the settlement seam ---------------------------
    function test_AdminRotatesMinter() public {
        address newSettlement = address(0xBEEF);
        vm.expectRevert(AICoin.NotAdmin.selector);
        coin.setMinter(newSettlement); // not the DAO

        vm.prank(DAO);
        coin.setMinter(newSettlement);
        assertEq(coin.minter(), newSettlement);

        vm.warp(g0 + PERIOD / 2);
        vm.prank(SETTLEMENT); // old minter no longer authorized
        vm.expectRevert(AICoin.NotMinter.selector);
        coin.mintSubsidy(NODE, 1 ether);

        vm.prank(newSettlement);
        coin.mintSubsidy(NODE, 1 ether);
        assertEq(coin.balanceOf(NODE), 1 ether);
    }

    function test_TransferAdmin() public {
        address newAdmin = address(0xAD);
        vm.expectRevert(AICoin.NotAdmin.selector);
        coin.transferAdmin(newAdmin); // not the DAO

        vm.prank(DAO);
        coin.transferAdmin(newAdmin);
        assertEq(coin.admin(), newAdmin);

        // new admin now controls the minter seam; old admin cannot
        vm.prank(DAO);
        vm.expectRevert(AICoin.NotAdmin.selector);
        coin.setMinter(address(0xBEEF));

        vm.prank(newAdmin);
        coin.setMinter(address(0xBEEF));
        assertEq(coin.minter(), address(0xBEEF));
    }
}
