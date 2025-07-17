// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

/**
 * @title IVotingTypes
 * @notice Common types used across voting-related contracts
 * @dev This interface defines shared structs to avoid circular dependencies
 * between IStrategyV1 and IFreezeVotingAzoriusV1.
 */
interface IVotingTypes {
    /**
     * @notice Data structure for casting votes through specific voting configurations
     * @param configIndex Index of the VotingConfig in the votingConfigs array
     * @param voteData Token-specific data (e.g., token IDs for ERC721)
     */
    struct VotingConfigVoteData {
        uint256 configIndex;
        bytes voteData;
    }
}
