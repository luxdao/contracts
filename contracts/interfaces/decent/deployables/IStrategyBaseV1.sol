// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IStrategyBaseV1 {
    error InvalidProposerAdapter(address _proposerAdapter);

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
}
