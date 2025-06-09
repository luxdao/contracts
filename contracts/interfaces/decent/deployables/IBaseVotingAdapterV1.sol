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

    function strategy() external view returns (address strategy);

    function recordVote(
        address voter_,
        uint32 proposalId_,
        bytes calldata votingAdapterVoteData_
    ) external returns (uint256 weightCasted);

    function weightOf(
        address voter_,
        uint32 proposalId_,
        bytes calldata votingAdapterVoteData_
    ) external view returns (uint256 weight);

    function recordFreezeVote(
        address voter_,
        uint48 freezeProposalSnapshotAndId_,
        bytes calldata adapterVoteData_
    ) external returns (uint256 weightCasted);

    function validVotingAdapterVote(
        address voter_,
        uint32 proposalId_,
        bytes calldata votingAdapterVoteData_
    ) external view returns (bool isValid, uint256 votingWeight);
}
