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

    struct VotingAdapterVoteData {
        address votingAdapter;
        bytes adapterVoteData;
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
    event FreezeVoterAuthorizationChanged(
        address indexed freezeVoterContract,
        bool isAuthorized
    );

    event VotingPeriodEnded(
        uint32 indexed proposalId,
        uint48 votingEndTimestamp,
        uint48 currentTimestamp
    );

    error InvalidProposerAdapter(address _proposerAdapter);
    error NoVotingAdapters();
    error NoProposerAdapters();
    error InvalidBasisNumerator();
    error InvalidStrategyAdmin();
    error ProposalNotActive();
    error NoVotingWeight();
    error InvalidVoteType();
    error ProposalNotInitialized();
    error InvalidVotingAdapter();
    error InvalidAddress();

    function initialize(
        address strategyAdmin,
        uint32 votingPeriod,
        uint256 quorumThreshold,
        uint256 basisNumerator,
        address[] calldata votingAdapters,
        address[] calldata proposerAdapters,
        address lightAccountFactory
    ) external;

    function isProposer(
        address address_,
        address proposerAdapter_,
        bytes calldata proposerAdapterData_
    ) external view returns (bool);

    function initializeProposal(
        uint32 proposalId_,
        bytes32[] calldata txHashes_,
        bytes calldata proposalInitializerData_
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

    function strategyAdmin() external view returns (address);

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
        VotingAdapterVoteData[] calldata votingAdaptersData
    ) external;

    function addAuthorizedFreezeVoter(address freezeVoterContract) external;

    function removeAuthorizedFreezeVoter(address freezeVoterContract) external;

    function isAuthorizedFreezeVoter(
        address freezeVoterContract
    ) external view returns (bool);

    function authorizedFreezeVoters() external view returns (address[] memory);

    function votingPeriodEnded(uint32 _proposalId) external view returns (bool);

    function validStrategyVote(
        address voter_,
        uint32 proposalId_,
        uint8 voteType_,
        VotingAdapterVoteData[] calldata votingAdaptersData_
    ) external view returns (bool isValid);
}
