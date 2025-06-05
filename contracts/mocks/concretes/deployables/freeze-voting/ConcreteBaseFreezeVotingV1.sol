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
            initializeFreezeVote();
        }

        // Check if proposal period has expired
        require(
            block.timestamp <= _freezeProposalCreated + _freezeProposalPeriod,
            "Freeze proposal period expired"
        );

        recordFreezeVote(msg.sender, 1);
    }
}
