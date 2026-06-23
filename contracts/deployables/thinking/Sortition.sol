// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

/**
 * @title Sortition
 * @author Hanzo AI Inc / Zoo Labs Foundation
 * @notice Permissionless committee selection by cryptographic sortition. An
 * operator is in the committee for a round iff its seeded ticket falls below a
 * selection threshold sized so that, in expectation, ~`size` of `population`
 * registered operators are selected. Selection probability is `size/population`,
 * so an adversary controlling fraction `f` of the population controls ~`f` of the
 * committee --- to control a MAJORITY of a committee it must control a majority of
 * the WHOLE registered population, not merely race to fill the first `size` slots.
 *
 * This is the structural half of permissionless Sybil-resistance (the economic
 * half is a non-refundable registration cost, so acquiring that population
 * majority is expensive and sunk). It is the equal-vote regime the soundness
 * review identifies as safe: one operator, one ticket; no stake weighting (a
 * sub-threshold whale cannot buy disproportionate seats).
 *
 * @dev The `seed` MUST be fixed AFTER operators commit (register / round-open) and
 * be unpredictable to them and to the round opener --- a future block hash or a
 * VRF beacon. A caller-chosen or pre-known seed lets an attacker grind which of its
 * identities are selected and defeats the guarantee. Membership is O(1) per check
 * (one keccak), so no on-chain enumeration of the operator set is needed.
 */
library Sortition {
    /// @notice True iff `operator` is sampled into a committee of expected size
    /// `size` drawn from `population` registered operators under `seed`.
    /// @param seed   unpredictable, post-commitment randomness (future blockhash/VRF)
    /// @param operator the operator's address (its ticket is keccak(seed, operator))
    /// @param population number of registered operators at seed time (snapshot)
    /// @param size    target committee size
    function isSelected(bytes32 seed, address operator, uint256 population, uint256 size)
        internal
        pure
        returns (bool)
    {
        if (population == 0 || size == 0) return false;
        if (size >= population) return true; // committee is the whole population
        uint256 ticket = uint256(keccak256(abi.encodePacked(seed, operator)));
        // threshold = floor(2^256 / population) * size. No overflow: size < population
        // so (MAX/population)*size < (MAX/population)*population <= MAX. The floor makes
        // the realized probability a hair below size/population (conservative: never
        // selects MORE than intended in expectation).
        uint256 threshold = (type(uint256).max / population) * size;
        return ticket < threshold;
    }
}
