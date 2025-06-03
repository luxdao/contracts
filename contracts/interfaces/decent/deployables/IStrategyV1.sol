// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IStrategyBaseV1} from "./IStrategyBaseV1.sol";

interface IStrategyV1 is IStrategyBaseV1 {
    struct ProposalVotingDetails {
        uint48 votingStartTimestamp;
        uint48 votingEndTimestamp;
        uint32 votingStartBlock;
        uint256 yesVotes;
        uint256 noVotes;
        uint256 abstainVotes;
    }

    enum VoteType {
        NO,
        YES,
        ABSTAIN
    }

    event Voted(
        address indexed voter,
        uint32 indexed proposalId,
        VoteType voteType,
        uint256 totalWeightCastedInTx
    );
    event ProposalInitialized(
        uint32 indexed proposalId,
        uint48 votingStartTimestamp,
        uint48 votingEndTimestamp,
        uint32 votingStartBlock
    );

    error NoVotingAdapters();
    error NoProposerAdapters();
    error InvalidBasisNumerator();
    error InvalidProposalInitializer();
    error ProposalNotFoundOrNotActive();
    error NoVotingWeight();
    error InvalidVoteType();
    error ProposalNotInitialized();
    error MismatchedInputs();
    error InvalidVotingAdapter();

    function initialize(
        address proposalInitializer,
        uint32 votingPeriod,
        uint256 quorumThreshold,
        uint256 basisNumerator,
        address[] memory votingAdapters,
        address[] memory proposerAdapters,
        address lightAccountFactory
    ) external;

    function proposalInitializer() external view returns (address);

    function votingPeriod() external view returns (uint32);

    function quorumThreshold() external view returns (uint256);

    function basisNumerator() external view returns (uint256);

    function proposalVotingDetails(
        uint32 proposalId
    ) external view returns (ProposalVotingDetails memory);

    function votingAdapters() external view returns (address[] memory);

    function proposerAdapters() external view returns (address[] memory);

    function isQuorumMet(uint32 _proposalId) external view returns (bool);

    function isBasisMet(uint32 _proposalId) external view returns (bool);

    function vote(
        uint32 _proposalId,
        uint8 _voteType,
        address[] calldata _votingAdaptersToUse,
        bytes[] calldata _votingAdapterVoteData
    ) external;
}
