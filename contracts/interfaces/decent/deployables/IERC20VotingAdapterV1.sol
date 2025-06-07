// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IERC20VotingAdapterV1 {
    error ProposalNotReadyForSnapshot();
    error AlreadyVoted();

    function initialize(
        address token,
        address strategy,
        uint256 weightPerToken
    ) external;

    function token() external view returns (address);

    function weightPerToken() external view returns (uint256);

    function getFreezeVoteWeight(
        address voter,
        uint48 freezeProposalSnapshotAndId
    ) external view returns (uint256 weight);

    function hasCastedVoteForProposal(
        uint32 proposalId,
        address voter
    ) external view returns (bool);

    function hasCastedVotePerFreezeVoteProposalPerFreezeVoteContract(
        address freezeVoteContract,
        uint48 freezeProposalSnapshotAndId,
        address voter
    ) external view returns (bool);
}
