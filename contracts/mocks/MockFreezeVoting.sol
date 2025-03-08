// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.28;

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

    /**
     * @inheritdoc IBaseFreezeVotingV1
     */
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
    function updateFreezeVotesThreshold(uint256 freezeVotesThreshold) external {
        _freezeVotesThreshold = freezeVotesThreshold;
        emit FreezeVotesThresholdUpdated(freezeVotesThreshold);
    }

    /**
     * @inheritdoc IBaseFreezeVotingV1
     */
    function updateFreezeProposalPeriod(uint32 freezeProposalPeriod) external {
        _freezeProposalPeriod = freezeProposalPeriod;
        emit FreezeProposalPeriodUpdated(freezeProposalPeriod);
    }

    /**
     * @inheritdoc IBaseFreezeVotingV1
     */
    function updateFreezePeriod(uint32 freezePeriod) external {
        _freezePeriod = freezePeriod;
        emit FreezePeriodUpdated(freezePeriod);
    }

    // Mock events for testing
    event FreezeVoteCast(address indexed voter);
    event DAOUnfrozen(address indexed unfreezer);
    event FreezeVotesThresholdUpdated(uint256 newThreshold);
    event FreezeProposalPeriodUpdated(uint32 newPeriod);
    event FreezePeriodUpdated(uint32 newPeriod);
}
