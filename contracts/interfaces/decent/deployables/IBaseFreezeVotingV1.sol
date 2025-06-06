// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IBaseFreezeVotingV1 {
    error NoVotes();

    event FreezeVoteCast(address indexed voter, uint256 votesCast);

    function freezeProposalCreated() external view returns (uint48);

    function freezeProposalVoteCount() external view returns (uint256);

    function freezeProposalPeriod() external view returns (uint32);

    function freezePeriod() external view returns (uint32);

    function freezeVotesThreshold() external view returns (uint256);

    function freezeActivated() external view returns (uint48);

    function isFrozen() external view returns (bool);

    function unfreeze() external;
}
