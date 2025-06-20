// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

/**
 * @title IVotingAdapterERC20V1
 * @notice Voting adapter that calculates voting weight based on ERC20 token balances
 * @dev This adapter enables voting using ERC20 tokens with snapshot capabilities.
 * It enforces one vote per address per proposal, with voting weight determined by
 * the voter's token balance at the proposal's start time (snapshot).
 *
 * Key features:
 * - Snapshot-based voting weight calculation
 * - Support for both timestamp and block number clock modes
 * - One vote per address constraint
 * - Configurable weight multiplier per token
 * - Separate tracking for regular and freeze votes
 *
 * Voting mechanics:
 * - Weight = token balance at snapshot × weightPerToken
 * - Uses getPastVotes() for historical balance lookup
 * - Automatically detects token's clock mode (timestamp vs block)
 * - Empty vote data parameter (token IDs not needed)
 *
 * Integration notes:
 * - Token must implement IVotes interface (e.g., VotesERC20V1)
 * - Supports tokens with checkpoint/snapshot functionality
 * - Works with both timestamp-based and block-based voting power
 */
interface IVotingAdapterERC20V1 {
    // --- Errors ---

    /** @notice Thrown when an address attempts to vote more than once on the same proposal */
    error AlreadyVoted();

    // --- Initializer Functions ---

    /**
     * @notice Initializes the voting adapter with token and weight configuration
     * @dev Detects and stores the token's clock mode during initialization.
     * The token must implement the IVotes interface for voting power queries.
     * @param token_ The ERC20 token address (must implement IVotes)
     * @param strategy_ The strategy contract that will use this adapter
     * @param weightPerToken_ Multiplier applied to token balances for vote weight calculation
     */
    function initialize(
        address token_,
        address strategy_,
        uint256 weightPerToken_
    ) external;

    // --- View Functions ---

    /**
     * @notice Returns the ERC20 token used for voting weight calculation
     * @return token The token contract address
     */
    function token() external view returns (address token);

    /**
     * @notice Returns the weight multiplier applied to token balances
     * @return weightPerToken The multiplier value
     */
    function weightPerToken() external view returns (uint256 weightPerToken);

    /**
     * @notice Calculates freeze vote weight for a voter at a specific snapshot
     * @dev Uses the lower 32 bits of freezeProposalSnapshotAndId_ as the snapshot
     * timepoint (block or timestamp based on token's clock mode).
     * @param voter_ The address to calculate weight for
     * @param freezeProposalSnapshotAndId_ Combined snapshot and proposal ID
     * @return weight The calculated freeze vote weight
     */
    function getFreezeVoteWeight(
        address voter_,
        uint48 freezeProposalSnapshotAndId_
    ) external view returns (uint256 weight);

    /**
     * @notice Checks if an address has already voted on a proposal
     * @param proposalId_ The proposal to check
     * @param voter_ The voter address to check
     * @return hasCastedVote True if the address has already voted
     */
    function hasCastedVoteForProposal(
        uint32 proposalId_,
        address voter_
    ) external view returns (bool hasCastedVote);

    /**
     * @notice Checks if an address has voted on a specific freeze proposal
     * @dev Tracks freeze votes separately per freeze voting contract
     * @param freezeVoteContract_ The freeze voting contract address
     * @param freezeProposalSnapshotAndId_ The freeze proposal identifier
     * @param voter_ The voter address to check
     * @return hasCastedVote True if the address has already voted on this freeze proposal
     */
    function hasCastedVotePerFreezeVoteProposalPerFreezeVoteContract(
        address freezeVoteContract_,
        uint48 freezeProposalSnapshotAndId_,
        address voter_
    ) external view returns (bool hasCastedVote);
}
