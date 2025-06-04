// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {BaseFreezeVotingV1} from "../../../../deployables/freeze-voting/BaseFreezeVotingV1.sol";

contract ConcreteBaseFreezeVotingV1 is BaseFreezeVotingV1 {
    function initialize(
        address owner_,
        uint256 freezeVotesThreshold_,
        uint32 freezeProposalPeriod_,
        uint32 freezePeriod_
    ) public initializer {
        __Ownable_init(owner_);
        _freezeVotesThreshold = freezeVotesThreshold_;
        _freezeProposalPeriod = freezeProposalPeriod_;
        _freezePeriod = freezePeriod_;
    }

    function castFreezeVote() external {
        // If no freeze proposal exists yet, create one
        if (_freezeProposalCreated == 0) {
            _freezeProposalCreated = uint48(block.timestamp);
            _freezeProposalVoteCount = 0; // Initialize to zero
            emit FreezeProposalCreated(msg.sender);
        }

        // Check if proposal period has expired
        require(
            block.timestamp <= _freezeProposalCreated + _freezeProposalPeriod,
            "Freeze proposal period expired"
        );

        // Check if the user has already voted on this proposal
        require(
            !_userHasFreezeVoted[msg.sender][_freezeProposalCreated],
            "Already voted"
        );

        // The vote power to assign to each voter
        uint256 _mockVotePower = 1;

        // Record the vote
        _userHasFreezeVoted[msg.sender][_freezeProposalCreated] = true;
        _freezeProposalVoteCount += _mockVotePower;

        emit FreezeVoteCast(msg.sender, _mockVotePower);
    }
}
