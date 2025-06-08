// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IERC721VotingAdapterV1 {
    error NoTokenIdsPassed();
    error TokenIdAlreadyUsedForVote(uint256 tokenId);
    error TokenIdNotOwnedByVoter(uint256 tokenId);

    function initialize(
        address token,
        address strategy,
        uint256 weightPerToken
    ) external;

    function token() external view returns (address);

    function weightPerToken() external view returns (uint256);

    function tokenIdUsedForVote(
        uint32 proposalId,
        uint256 tokenId
    ) external view returns (bool);

    function weightOfWithValidTokenIds(
        address _voter,
        uint32 _proposalId,
        bytes calldata _adapterVoteData
    ) external view returns (uint256 weight, uint256[] memory validTokenIds);

    function getFreezeVoteWeight(
        address voter,
        address freezeVoteContract,
        uint48 freezeProposalSnapshotAndId,
        bytes calldata adapterVoteData
    ) external view returns (uint256 weight);

    function tokenIdUsedPerFreezeVoteProposalPerFreezeVoteContract(
        address freezeVoteContract,
        uint48 freezeProposalSnapshotAndId,
        uint256 tokenId
    ) external view returns (bool);
}
