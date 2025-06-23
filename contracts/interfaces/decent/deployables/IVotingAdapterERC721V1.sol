// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

/**
 * @title IVotingAdapterERC721V1
 * @notice Voting adapter that enables voting using ERC721 NFTs
 * @dev This adapter allows NFT holders to vote using their tokens, with each NFT
 * providing equal voting weight. Unlike ERC20 adapters, this supports multiple votes
 * from the same address using different NFTs.
 *
 * Key features:
 * - One vote per NFT (not per address)
 * - Current ownership validation (no historical snapshots)
 * - Voters must specify which NFT token IDs to use
 * - Configurable weight per NFT
 * - Prevents reuse of NFTs within the same proposal
 *
 * Voting mechanics:
 * - Weight = number of valid NFTs × weightPerToken
 * - Validates current NFT ownership at voting time
 * - Requires encoding token IDs in vote data: abi.encode(uint256[])
 * - Each NFT can only be used once per proposal
 *
 * Integration notes:
 * - Standard ERC721 tokens supported (no special interfaces required)
 * - Multiple votes allowed from same address with different NFTs
 * - No snapshot mechanism - uses current ownership state
 */
interface IVotingAdapterERC721V1 {
    // --- Errors ---

    /** @notice Thrown when attempting to use an NFT that has already voted on this proposal */
    error TokenIdAlreadyUsedForVote(uint256 tokenId);

    /** @notice Thrown when attempting to vote with an NFT not owned by the voter */
    error TokenIdNotOwnedByVoter(uint256 tokenId);

    // --- Initializer Functions ---

    /**
     * @notice Initializes the voting adapter with NFT token and weight configuration
     * @param token_ The ERC721 NFT contract address
     * @param strategy_ The strategy contract that will use this adapter
     * @param weightPerToken_ Voting weight assigned to each NFT
     */
    function initialize(
        address token_,
        address strategy_,
        uint256 weightPerToken_
    ) external;

    // --- View Functions ---

    /**
     * @notice Returns the ERC721 token used for voting
     * @return token The NFT contract address
     */
    function token() external view returns (address token);

    /**
     * @notice Returns the voting weight assigned to each NFT
     * @return weightPerToken The weight value per NFT
     */
    function weightPerToken() external view returns (uint256 weightPerToken);

    /**
     * @notice Checks if a specific NFT has been used to vote on a proposal
     * @param proposalId_ The proposal to check
     * @param tokenId_ The NFT token ID to check
     * @return tokenUsed True if this NFT has already been used to vote
     */
    function tokenIdUsedForVote(
        uint32 proposalId_,
        uint256 tokenId_
    ) external view returns (bool tokenUsed);

    /**
     * @notice Calculates voting weight and returns valid NFT IDs for a vote
     * @dev Validates ownership and uniqueness of all provided token IDs.
     * Filters out any NFTs that are invalid or already used.
     * @param voter_ The address attempting to vote
     * @param proposalId_ The proposal being voted on
     * @param adapterVoteData_ Encoded array of NFT token IDs: abi.encode(uint256[])
     * @return weight Total voting weight of valid NFTs
     * @return validTokenIds Array of NFT IDs that are valid for voting
     */
    function weightOfWithValidTokenIds(
        address voter_,
        uint32 proposalId_,
        bytes calldata adapterVoteData_
    ) external view returns (uint256 weight, uint256[] memory validTokenIds);

    /**
     * @notice Calculates freeze vote weight for provided NFTs
     * @dev Validates current ownership of NFTs. Unlike regular votes, includes
     * the freeze vote contract in tracking to prevent cross-contract reuse.
     * @param voter_ The address attempting to vote
     * @param freezeVoteContract_ The freeze voting contract address
     * @param freezeProposalSnapshotAndId_ The freeze proposal identifier
     * @param adapterVoteData_ Encoded array of NFT token IDs: abi.encode(uint256[])
     * @return weight Total voting weight of valid NFTs
     */
    function getFreezeVoteWeight(
        address voter_,
        address freezeVoteContract_,
        uint48 freezeProposalSnapshotAndId_,
        bytes calldata adapterVoteData_
    ) external view returns (uint256 weight);

    /**
     * @notice Checks if an NFT has been used for a specific freeze proposal
     * @dev Tracks NFT usage per freeze vote contract to prevent cross-contract reuse
     * @param freezeVoteContract_ The freeze voting contract address
     * @param freezeProposalSnapshotAndId_ The freeze proposal identifier
     * @param tokenId_ The NFT token ID to check
     * @return tokenUsed True if this NFT has been used for this freeze proposal
     */
    function tokenIdUsedPerFreezeVoteProposalPerFreezeVoteContract(
        address freezeVoteContract_,
        uint48 freezeProposalSnapshotAndId_,
        uint256 tokenId_
    ) external view returns (bool tokenUsed);
}
