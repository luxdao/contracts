// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

/**
 * @title IFreezeVotingAzoriusV1
 * @notice Freeze voting implementation for Azorius-based parent DAOs
 * @dev This contract enables token holders of an Azorius-based parent DAO to vote
 * to freeze a child DAO. It leverages the parent's existing voting adapters and
 * token infrastructure for freeze voting.
 *
 * Key features:
 * - Uses parent DAO's strategy and voting adapters for voting weight
 * - Automatic new freeze proposal creation if previous one expired
 * - Supports multiple voting adapters in a single vote
 * - Light Account support for gasless freeze voting
 *
 * Freeze voting process:
 * 1. If no active proposal exists, first voter creates one automatically
 * 2. Voters use parent's voting adapters to cast weighted votes
 * 3. When threshold is reached, child DAO is immediately frozen
 * 4. Parent DAO (owner) can unfreeze at any time
 *
 * Integration:
 * - References parent's Azorius module for strategy information
 * - Voting weight calculated through parent's voting adapters
 * - Owned by the parent DAO for administrative control
 */
interface IFreezeVotingAzoriusV1 {
    // --- Errors ---

    /** @notice Thrown when attempting to use a voting adapter not configured in the parent's strategy */
    error InvalidVotingAdapter();

    // --- Structs ---

    /**
     * @notice Data structure for casting votes through specific voting adapters
     * @param votingAdapter Address of the voting adapter to use (must be configured in parent's strategy)
     * @param adapterVoteData Adapter-specific data (e.g., token IDs for ERC721)
     */
    struct VotingAdapterVoteData {
        address votingAdapter;
        bytes adapterVoteData;
    }

    // --- Events ---

    /**
     * @notice Emitted when a new freeze proposal is created
     * @param proposer The address that triggered the proposal creation (first voter)
     * @param strategy The parent DAO's strategy contract used for this freeze proposal
     */
    event FreezeProposalCreated(
        address indexed proposer,
        address indexed strategy
    );

    // --- Initializer Functions ---

    /**
     * @notice Initializes the freeze voting contract for an Azorius-based parent DAO
     * @param owner_ The parent DAO that will have unfreeze powers
     * @param freezeVotesThreshold_ Voting weight required to freeze the child DAO
     * @param freezeProposalPeriod_ Duration in seconds that freeze proposals remain active
     * @param freezePeriod_ Duration in seconds that a freeze remains active
     * @param parentAzorius_ The parent DAO's Azorius module address
     * @param lightAccountFactory_ Factory for Light Account support (ERC-4337)
     */
    function initialize(
        address owner_,
        uint256 freezeVotesThreshold_,
        uint32 freezeProposalPeriod_,
        uint32 freezePeriod_,
        address parentAzorius_,
        address lightAccountFactory_
    ) external;

    // --- View Functions ---

    /**
     * @notice Returns the parent DAO's Azorius module
     * @dev Used to access the parent's strategy for voting adapter validation
     * @return parentAzorius The parent's Azorius module address
     */
    function parentAzorius() external view returns (address parentAzorius);

    /**
     * @notice Returns the strategy contract used for the current freeze proposal
     * @dev Captured from parent Azorius when the freeze proposal is created
     * @return freezeProposalStrategy The strategy address for the active freeze proposal
     */
    function freezeProposalStrategy()
        external
        view
        returns (address freezeProposalStrategy);

    // --- State-Changing Functions ---

    /**
     * @notice Casts a freeze vote using the parent DAO's voting adapters
     * @dev If no active freeze proposal exists, creates one automatically.
     * Aggregates voting weight from all specified adapters. If total votes
     * reach threshold, the child DAO is immediately frozen.
     * @param votingAdaptersToUse_ Array of voting adapters and their data
     * @param lightAccountIndex_ Index for Light Account resolution (0 for direct voting)
     * @custom:throws InvalidVotingAdapter if adapter not in parent's strategy
     * @custom:throws NoVotes if voter has zero total weight
     * @custom:emits FreezeProposalCreated if new proposal started
     * @custom:emits FreezeVoteCast with voter and weight
     */
    function castFreezeVote(
        VotingAdapterVoteData[] calldata votingAdaptersToUse_,
        uint256 lightAccountIndex_
    ) external;
}
