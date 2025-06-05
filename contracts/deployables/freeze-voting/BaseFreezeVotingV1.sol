// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IBaseFreezeVotingV1} from "../../interfaces/decent/deployables/IBaseFreezeVotingV1.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

abstract contract BaseFreezeVotingV1 is
    IBaseFreezeVotingV1,
    Ownable2StepUpgradeable
{
    uint48 internal _freezeProposalCreated;
    uint256 internal _freezeProposalVoteCount;
    uint32 internal _freezeProposalPeriod;
    uint32 internal _freezePeriod;
    uint256 internal _freezeVotesThreshold;
    uint48 internal _freezeActivated;

    constructor() {
        _disableInitializers();
    }

    function __BaseFreezeVotingV1_init(
        address owner_,
        uint32 freezeProposalPeriod_,
        uint32 freezePeriod_,
        uint256 freezeVotesThreshold_
    ) internal onlyInitializing {
        __Ownable_init(owner_);
        _freezeVotesThreshold = freezeVotesThreshold_;
        _freezeProposalPeriod = freezeProposalPeriod_;
        _freezePeriod = freezePeriod_;
    }

    function freezeProposalCreated()
        external
        view
        virtual
        override
        returns (uint48)
    {
        return _freezeProposalCreated;
    }

    function freezeProposalVoteCount()
        external
        view
        virtual
        override
        returns (uint256)
    {
        return _freezeProposalVoteCount;
    }

    function freezeProposalPeriod()
        external
        view
        virtual
        override
        returns (uint32)
    {
        return _freezeProposalPeriod;
    }

    function freezePeriod() external view virtual override returns (uint32) {
        return _freezePeriod;
    }

    function freezeVotesThreshold()
        external
        view
        virtual
        override
        returns (uint256)
    {
        return _freezeVotesThreshold;
    }

    function freezeActivated() external view virtual override returns (uint48) {
        return _freezeActivated;
    }

    function isFrozen() external view virtual override returns (bool) {
        return
            _freezeProposalVoteCount >= _freezeVotesThreshold &&
            block.timestamp < _freezeActivated + _freezePeriod;
    }

    function initializeFreezeVote() internal virtual {
        _freezeProposalCreated = uint48(block.timestamp);
        _freezeProposalVoteCount = 0;
        _freezeActivated = 0;
    }

    function recordFreezeVote(
        address voter,
        uint256 weightCasted
    ) internal virtual {
        if (weightCasted == 0) revert NoVotes();

        _freezeProposalVoteCount += weightCasted;

        if (_freezeProposalVoteCount >= _freezeVotesThreshold) {
            _freezeActivated = uint48(block.timestamp);
        }

        emit FreezeVoteCast(voter, weightCasted);
    }

    function unfreeze() public virtual override onlyOwner {
        _freezeProposalCreated = 0;
        _freezeProposalVoteCount = 0;
        _freezeActivated = 0;
    }
}
