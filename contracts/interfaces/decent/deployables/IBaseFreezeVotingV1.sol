// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IBaseFreezeVotingV1 {
    event FreezeVoteCast(address indexed voter, uint256 votesCast);
    event FreezeProposalCreated(address indexed creator);
    event FreezeVotesThresholdUpdated(uint256 freezeVotesThreshold);
    event FreezePeriodUpdated(uint32 freezePeriod);
    event FreezeProposalPeriodUpdated(uint32 freezeProposalPeriod);

    function freezeProposalCreated() external view returns (uint48);

    function freezePeriod() external view returns (uint32);

    function freezeVotesThreshold() external view returns (uint256);

    function freezeProposalPeriod() external view returns (uint32);

    function freezeProposalVoteCount() external view returns (uint256);

    function userHasFreezeVoted(
        address user,
        uint48 proposalId
    ) external view returns (bool);

    function isFrozen() external view returns (bool);

    function unfreeze() external;

    function updateFreezeVotesThreshold(uint256 _freezeVotesThreshold) external;

    function updateFreezeProposalPeriod(uint32 _freezeProposalPeriod) external;

    function updateFreezePeriod(uint32 _freezePeriod) external;
}
