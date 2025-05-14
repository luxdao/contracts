// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {BaseFreezeVotingV1} from "../../../../deployables/freeze-voting/BaseFreezeVotingV1.sol";

/**
 * A minimal concrete implementation of BaseFreezeVotingV1 for testing.
 */
contract ConcreteBaseFreezeVotingV1 is BaseFreezeVotingV1 {
    /**
     * Initialize function, will be triggered when a new instance is deployed.
     *
     * @param _owner The owner of the contract
     * @param _freezeVotesThreshold The number of votes required to activate a freeze
     * @param _freezeProposalPeriod The number of blocks a freeze proposal has to succeed
     * @param _freezePeriod The number of blocks a freeze lasts
     */
    function initialize(
        address _owner,
        uint256 _freezeVotesThreshold,
        uint32 _freezeProposalPeriod,
        uint32 _freezePeriod
    ) public initializer {
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
        _updateFreezeVotesThreshold(_freezeVotesThreshold);
        _updateFreezeProposalPeriod(_freezeProposalPeriod);
        _updateFreezePeriod(_freezePeriod);
    }

    /**
     * Implements the abstract castFreezeVote function.
     *
     * Each call counts as one vote by default, or as many votes as set by setMockVotePower.
     */
    function castFreezeVote() external override {
        // If no freeze proposal exists yet, create one
        if (freezeProposalCreatedBlock == 0) {
            freezeProposalCreatedBlock = uint32(block.number);
            freezeProposalVoteCount = 0; // Initialize to zero
            emit FreezeProposalCreated(msg.sender);
        }

        // Check if proposal period has expired
        require(
            block.number <= freezeProposalCreatedBlock + freezeProposalPeriod,
            "Freeze proposal period expired"
        );

        // Check if the user has already voted on this proposal
        require(
            !userHasFreezeVoted[msg.sender][freezeProposalCreatedBlock],
            "Already voted"
        );

        // The vote power to assign to each voter
        uint256 _mockVotePower = 1;

        // Record the vote
        userHasFreezeVoted[msg.sender][freezeProposalCreatedBlock] = true;
        freezeProposalVoteCount += _mockVotePower;

        emit FreezeVoteCast(msg.sender, _mockVotePower);
    }
}
