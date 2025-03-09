// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.28;

/**
 * @title IBaseQuorumPercentV1
 * @dev Interface for BaseQuorumPercentV1 contract that enables percent based quorums.
 * Intended to be implemented by BaseStrategy implementations.
 */
interface IBaseQuorumPercentV1 {
    /**
     * @dev Emitted when the quorum numerator is updated.
     */
    event QuorumNumeratorUpdated(uint256 quorumNumerator);

    /**
     * @dev Error thrown when the numerator exceeds the denominator.
     */
    error InvalidQuorumNumerator();

    /**
     * @dev Returns the current quorum numerator.
     * @return The current quorum numerator.
     */
    function quorumNumerator() external view returns (uint256);

    /**
     * @dev Returns the quorum denominator, which is a constant (1,000,000).
     * @return The quorum denominator.
     */
    function QUORUM_DENOMINATOR() external view returns (uint256);

    /**
     * @dev Updates the quorum required for future Proposals.
     * @param _quorumNumerator numerator to use when calculating quorum (over 1,000,000)
     */
    function updateQuorumNumerator(uint256 _quorumNumerator) external;

    /**
     * @dev Calculates whether a vote meets quorum. This is calculated based on yes votes + abstain votes.
     * @param _totalSupply the total supply of tokens
     * @param _yesVotes number of votes in favor
     * @param _abstainVotes number of votes abstaining
     * @return Whether the total number of yes votes + abstain meets the quorum
     */
    function meetsQuorum(
        uint256 _totalSupply,
        uint256 _yesVotes,
        uint256 _abstainVotes
    ) external view returns (bool);

    /**
     * @dev Calculates the total number of votes required for a proposal to meet quorum.
     * @param _proposalId The ID of the proposal to get quorum votes for
     * @return The quantity of votes required to meet quorum
     */
    function quorumVotes(uint32 _proposalId) external view returns (uint256);
}
