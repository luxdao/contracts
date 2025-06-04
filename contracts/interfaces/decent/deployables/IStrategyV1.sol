// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IStrategyV1 {
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

    error InvalidProposerAdapter(address _proposerAdapter);
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

    function isProposer(
        address address_,
        address proposerAdapter_,
        bytes calldata proposerAdapterData_
    ) external view returns (bool);

    function initializeProposal(
        uint32 proposalId_,
        bytes32[] memory txHashes_,
        bytes memory proposalInitializerData_
    ) external;

    function isPassed(uint32 proposalId_) external view returns (bool);

    function getVotingTimestamps(
        uint32 proposalId_
    ) external view returns (uint48 startTime, uint48 endTime);

    function getVotingStartBlock(
        uint32 proposalId_
    ) external view returns (uint32 votingStartBlock);

    function isVotingAdapter(
        address votingAdapter_
    ) external view returns (bool);

    function isProposerAdapter(
        address proposerAdapter_
    ) external view returns (bool);

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
