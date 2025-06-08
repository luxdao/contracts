// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IVotingAdapterERC20V1 {
    error ProposalNotReadyForSnapshot();
    error AlreadyVoted();

    function initialize(
        address token_,
        address strategy_,
        uint256 weightPerToken_
    ) external;

    function token() external view returns (address token);

    function weightPerToken() external view returns (uint256 weightPerToken);

    function getFreezeVoteWeight(
        address voter_,
        uint48 freezeProposalSnapshotAndId_
    ) external view returns (uint256 weight);

    function hasCastedVoteForProposal(
        uint32 proposalId_,
        address voter_
    ) external view returns (bool hasCastedVote);

    function hasCastedVotePerFreezeVoteProposalPerFreezeVoteContract(
        address freezeVoteContract_,
        uint48 freezeProposalSnapshotAndId_,
        address voter_
    ) external view returns (bool hasCastedVote);
}
