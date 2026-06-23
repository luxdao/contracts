// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Sortition} from "../contracts/deployables/thinking/Sortition.sol";

/// @notice Proves cryptographic sortition gives committee share ~ population share,
/// so capturing a committee majority requires a majority of the WHOLE population.
contract SortitionTest is Test {
    function _addr(uint256 i) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("op", i)))));
    }

    function test_AllSelectedWhenSizeGEPopulation() public pure {
        assertTrue(Sortition.isSelected(bytes32(uint256(1)), address(0xA), 5, 5));
        assertTrue(Sortition.isSelected(bytes32(uint256(1)), address(0xA), 5, 9));
    }

    function test_NoneWhenZero() public pure {
        assertFalse(Sortition.isSelected(bytes32(uint256(1)), address(0xA), 0, 5));
        assertFalse(Sortition.isSelected(bytes32(uint256(1)), address(0xA), 5, 0));
    }

    function test_Deterministic() public pure {
        bytes32 s = keccak256("seed");
        bool a = Sortition.isSelected(s, address(0xBEEF), 100, 10);
        bool b = Sortition.isSelected(s, address(0xBEEF), 100, 10);
        assertEq(a, b);
        // a different seed generally changes the outcome for at least some operators
        uint256 diff;
        for (uint256 i = 0; i < 50; ++i) {
            if (Sortition.isSelected(keccak256("s1"), _addr(i), 100, 50)
                != Sortition.isSelected(keccak256("s2"), _addr(i), 100, 50)) diff++;
        }
        assertGt(diff, 0, "seed must affect selection");
    }

    /// @notice Expected committee size ~ `size`. Over a 600-operator population with
    /// target 60, the realized count lands within a wide statistical band.
    function test_ExpectedCommitteeSize() public pure {
        bytes32 seed = keccak256("round-seed");
        uint256 pop = 600;
        uint256 size = 60;
        uint256 selected;
        for (uint256 i = 0; i < pop; ++i) {
            if (Sortition.isSelected(seed, _addr(i), pop, size)) selected++;
        }
        // binomial(600, 0.1): mean 60, sd ~7.3 — accept a generous ~3.5 sigma band
        assertGe(selected, 35, "committee not collapsed");
        assertLe(selected, 86, "committee not blown up");
    }

    /// @notice THE security property: an adversary's committee share tracks its
    /// population share. A 40% adversary does NOT get a committee majority; a 70%
    /// adversary does. Capturing a committee thus needs a population majority.
    function test_CaptureRequiresPopulationMajority() public pure {
        bytes32 seed = keccak256("capture-seed");
        uint256 pop = 600;
        uint256 size = 120;

        // 40% adversary (operators [0,240)) -> minority of the committee
        (uint256 advLow, uint256 totLow) = _committeeSplit(seed, pop, size, 240);
        assertLt(advLow * 2, totLow, "40% adversary must NOT hold a committee majority");

        // 70% adversary (operators [0,420)) -> majority of the committee
        (uint256 advHigh, uint256 totHigh) = _committeeSplit(seed, pop, size, 420);
        assertGt(advHigh * 2, totHigh, "70% adversary holds a committee majority (needs pop majority)");
    }

    /// @dev count (adversary-selected, total-selected) where operators [0,advCount)
    /// are the adversary's identities.
    function _committeeSplit(bytes32 seed, uint256 pop, uint256 size, uint256 advCount)
        internal
        pure
        returns (uint256 adv, uint256 total)
    {
        for (uint256 i = 0; i < pop; ++i) {
            if (Sortition.isSelected(seed, _addr(i), pop, size)) {
                total++;
                if (i < advCount) adv++;
            }
        }
    }
}
