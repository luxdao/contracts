// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IVotingAdapterBaseV1 {
    event VoteRecorded(
        address indexed voter,
        uint32 indexed proposalId,
        uint256 weightCasted,
        bytes votingAdapterVoteData
    );

    function recordVote(
        address _voter,
        uint32 _proposalId,
        bytes calldata _votingAdapterVoteData
    ) external returns (uint256 weightCasted);
}
