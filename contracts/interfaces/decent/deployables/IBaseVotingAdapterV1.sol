// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IBaseVotingAdapterV1 {
    error NotStrategy();
    error UnauthorizedFreezeVoter(address caller);
    error NoFreezeVotingWeight();

    event VoteRecorded(
        address indexed voter,
        uint32 indexed proposalId,
        uint256 weightCasted,
        bytes votingAdapterVoteData
    );

    event FreezeVoteRecorded(
        address indexed voter,
        uint48 indexed freezeProposalSnapshotAndId,
        uint256 weightCasted,
        bytes adapterVoteData
    );

    function strategy() external view returns (address);

    function recordVote(
        address _voter,
        uint32 _proposalId,
        bytes calldata _votingAdapterVoteData
    ) external returns (uint256 weightCasted);

    function weightOf(
        address _voter,
        uint32 _proposalId,
        bytes calldata _votingAdapterVoteData
    ) external view returns (uint256 weight);

    function recordFreezeVote(
        address voter,
        uint48 freezeProposalSnapshotAndId,
        bytes calldata adapterVoteData
    ) external returns (uint256 weightCasted);

    function validVotingAdapterVote(
        address voter,
        uint32 proposalId,
        bytes calldata votingAdapterVoteData
    ) external view returns (bool isValid, uint256 votingWeight);
}
