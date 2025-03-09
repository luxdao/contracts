// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.28;

/**
 * @title IBaseVotingBasisPercentV1
 * @dev Interface for BaseVotingBasisPercentV1 contract that enables percent based voting basis calculations.
 *
 * Intended to be implemented by BaseStrategy implementations, this allows for voting strategies
 * to dictate any basis strategy for passing a Proposal between >50% (simple majority) to 100%.
 *
 * See https://en.wikipedia.org/wiki/Voting#Voting_basis.
 * See https://en.wikipedia.org/wiki/Supermajority.
 */
interface IBaseVotingBasisPercentV1 {
    /**
     * @dev Emitted when the basis numerator is updated.
     */
    event BasisNumeratorUpdated(uint256 basisNumerator);

    /**
     * @dev Error thrown when the numerator is invalid (out of allowed range).
     */
    error InvalidBasisNumerator();

    /**
     * @dev Returns the current basis numerator.
     * @return The current basis numerator.
     */
    function basisNumerator() external view returns (uint256);

    /**
     * @dev Returns the basis denominator, which is a constant (1,000,000).
     * @return The basis denominator.
     */
    function BASIS_DENOMINATOR() external view returns (uint256);

    /**
     * @dev Updates the `basisNumerator` for future Proposals.
     * @param _basisNumerator numerator to use
     */
    function updateBasisNumerator(uint256 _basisNumerator) external;

    /**
     * @dev Calculates whether a vote meets its basis.
     * @param _yesVotes number of votes in favor
     * @param _noVotes number of votes against
     * @return Whether the yes votes meets the set basis
     */
    function meetsBasis(
        uint256 _yesVotes,
        uint256 _noVotes
    ) external view returns (bool);
}
