// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IBaseFreezeVotingV1} from "../interfaces/decent/deployables/IBaseFreezeVotingV1.sol";

/**
 * A mock contract implementing IBaseFreezeVotingV1 for testing.
 */
contract MockFreezeVoting is IBaseFreezeVotingV1 {
    bool private _isFrozen;
    uint256 private _freezeVotesThreshold;
    uint32 private _freezeProposalPeriod;
    uint32 private _freezePeriod;

    /**
     * Sets whether the mock should return that the DAO is frozen.
     */
    function setIsFrozen(bool frozen) external {
        _isFrozen = frozen;
    }

    /**
     * @inheritdoc IBaseFreezeVotingV1
     */
    function isFrozen() external view returns (bool) {
        return _isFrozen;
    }

    function castFreezeVote() external {
        // Mock implementation - does nothing except emit an event for testing
        emit FreezeVoteCast(msg.sender);
    }

    /**
     * @inheritdoc IBaseFreezeVotingV1
     */
    function unfreeze() external {
        _isFrozen = false;
        emit DAOUnfrozen(msg.sender);
    }

    /**
     * @inheritdoc IBaseFreezeVotingV1
     */
    function updateFreezeVotesThreshold(
        uint256 freezeVotesThreshold_
    ) external override {
        _freezeVotesThreshold = freezeVotesThreshold_;
        emit FreezeVotesThresholdUpdated(freezeVotesThreshold_);
    }

    /**
     * @inheritdoc IBaseFreezeVotingV1
     */
    function updateFreezeProposalPeriod(
        uint32 freezeProposalPeriod_
    ) external override {
        _freezeProposalPeriod = freezeProposalPeriod_;
        emit FreezeProposalPeriodUpdated(freezeProposalPeriod_);
    }

    /**
     * @inheritdoc IBaseFreezeVotingV1
     */
    function updateFreezePeriod(uint32 freezePeriod_) external override {
        _freezePeriod = freezePeriod_;
        emit FreezePeriodUpdated(freezePeriod_);
    }

    // Mock events for testing
    event FreezeVoteCast(address indexed voter);
    event DAOUnfrozen(address indexed unfreezer);

    function freezeProposalCreated() external view override returns (uint48) {}

    function freezePeriod() external view override returns (uint32) {}

    function freezeVotesThreshold() external view override returns (uint256) {}

    function freezeProposalPeriod() external view override returns (uint32) {}

    function freezeProposalVoteCount()
        external
        view
        override
        returns (uint256)
    {}

    function userHasFreezeVoted(
        address user,
        uint48 proposalId
    ) external view override returns (bool) {}
}
