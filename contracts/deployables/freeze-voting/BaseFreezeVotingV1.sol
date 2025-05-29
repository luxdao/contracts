// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IBaseFreezeVotingV1} from "../../interfaces/decent/deployables/IBaseFreezeVotingV1.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

abstract contract BaseFreezeVotingV1 is
    IBaseFreezeVotingV1,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    ERC165
{
    uint48 internal _freezeProposalCreated;
    uint32 internal _freezeProposalPeriod;
    uint32 internal _freezePeriod;
    uint256 internal _freezeVotesThreshold;
    uint256 internal _freezeProposalVoteCount;
    mapping(address => mapping(uint48 => bool)) internal _userHasFreezeVoted;

    constructor() {
        _disableInitializers();
    }

    function __BaseFreezeVotingV1_init(
        address owner_,
        uint32 freezeProposalPeriod_,
        uint32 freezePeriod_,
        uint256 freezeVotesThreshold_
    ) internal initializer {
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        _updateFreezeProposalPeriod(freezeProposalPeriod_);
        _updateFreezePeriod(freezePeriod_);
        _updateFreezeVotesThreshold(freezeVotesThreshold_);
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal virtual override onlyOwner {}

    function freezeProposalCreated()
        external
        view
        virtual
        override
        returns (uint48)
    {
        return _freezeProposalCreated;
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

    function freezeProposalPeriod()
        external
        view
        virtual
        override
        returns (uint32)
    {
        return _freezeProposalPeriod;
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

    function userHasFreezeVoted(
        address user,
        uint48 proposalId
    ) external view virtual override returns (bool) {
        return _userHasFreezeVoted[user][proposalId];
    }

    function isFrozen() external view virtual override returns (bool) {
        return
            _freezeProposalVoteCount >= _freezeVotesThreshold &&
            block.timestamp < _freezeProposalCreated + _freezePeriod;
    }

    function unfreeze() external virtual override onlyOwner {
        _freezeProposalCreated = 0;
        _freezeProposalVoteCount = 0;
    }

    function updateFreezeVotesThreshold(
        uint256 freezeVotesThreshold_
    ) external virtual override onlyOwner {
        _updateFreezeVotesThreshold(freezeVotesThreshold_);
    }

    function updateFreezeProposalPeriod(
        uint32 freezeProposalPeriod_
    ) external virtual override onlyOwner {
        _updateFreezeProposalPeriod(freezeProposalPeriod_);
    }

    function updateFreezePeriod(
        uint32 freezePeriod_
    ) external virtual override onlyOwner {
        _updateFreezePeriod(freezePeriod_);
    }

    function _updateFreezeVotesThreshold(
        uint256 freezeVotesThreshold_
    ) internal virtual {
        _freezeVotesThreshold = freezeVotesThreshold_;
        emit FreezeVotesThresholdUpdated(freezeVotesThreshold_);
    }

    function _updateFreezeProposalPeriod(
        uint32 freezeProposalPeriod_
    ) internal virtual {
        _freezeProposalPeriod = freezeProposalPeriod_;
        emit FreezeProposalPeriodUpdated(freezeProposalPeriod_);
    }

    function _updateFreezePeriod(uint32 freezePeriod_) internal virtual {
        _freezePeriod = freezePeriod_;
        emit FreezePeriodUpdated(freezePeriod_);
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(IBaseFreezeVotingV1).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
