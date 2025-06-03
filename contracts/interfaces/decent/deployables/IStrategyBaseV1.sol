// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IStrategyBaseV1 {
    error InvalidProposerAdapter(address _proposerAdapter);

    function isProposer(
        address _address,
        address _proposerAdapter,
        bytes calldata _proposerAdapterData
    ) external view returns (bool);

    function initializeProposal(
        uint32 _proposalId,
        bytes32[] memory _txHashes,
        bytes memory _proposalInitializerData
    ) external;

    function isPassed(uint32 _proposalId) external view returns (bool);

    function getVotingTimestamps(
        uint32 _proposalId
    ) external view returns (uint48 startTime, uint48 endTime);

    function getVotingStartBlock(
        uint32 _proposalId
    ) external view returns (uint32 votingStartBlock);
}
