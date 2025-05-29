// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IBaseFreezeVotingV1} from "../../interfaces/decent/deployables/IBaseFreezeVotingV1.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

abstract contract BaseFreezeVotingV1 is
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    IBaseFreezeVotingV1,
    ERC165
{
    uint48 public freezeProposalCreated;

    uint32 public freezeProposalPeriod;

    uint32 public freezePeriod;

    uint256 public freezeVotesThreshold;

    uint256 public freezeProposalVoteCount;

    mapping(address => mapping(uint48 => bool)) public userHasFreezeVoted;

    event FreezeVoteCast(address indexed voter, uint256 votesCast);
    event FreezeProposalCreated(address indexed creator);
    event FreezeVotesThresholdUpdated(uint256 freezeVotesThreshold);
    event FreezePeriodUpdated(uint32 freezePeriod);
    event FreezeProposalPeriodUpdated(uint32 freezeProposalPeriod);

    constructor() {
        _disableInitializers();
    }

    function __BaseFreezeVotingV1_init(
        address _owner,
        uint32 _freezeProposalPeriod,
        uint32 _freezePeriod,
        uint256 _freezeVotesThreshold
    ) internal initializer {
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
        _updateFreezeProposalPeriod(_freezeProposalPeriod);
        _updateFreezePeriod(_freezePeriod);
        _updateFreezeVotesThreshold(_freezeVotesThreshold);
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal virtual override onlyOwner {}

    function castFreezeVote() external virtual;

    function isFrozen() external view virtual returns (bool) {
        return
            freezeProposalVoteCount >= freezeVotesThreshold &&
            block.timestamp < freezeProposalCreated + freezePeriod;
    }

    function unfreeze() external virtual onlyOwner {
        freezeProposalCreated = 0;
        freezeProposalVoteCount = 0;
    }

    function updateFreezeVotesThreshold(
        uint256 _freezeVotesThreshold
    ) external virtual onlyOwner {
        _updateFreezeVotesThreshold(_freezeVotesThreshold);
    }

    function updateFreezeProposalPeriod(
        uint32 _freezeProposalPeriod
    ) external virtual onlyOwner {
        _updateFreezeProposalPeriod(_freezeProposalPeriod);
    }

    function updateFreezePeriod(
        uint32 _freezePeriod
    ) external virtual onlyOwner {
        _updateFreezePeriod(_freezePeriod);
    }

    function _updateFreezeVotesThreshold(
        uint256 _freezeVotesThreshold
    ) internal virtual {
        freezeVotesThreshold = _freezeVotesThreshold;
        emit FreezeVotesThresholdUpdated(_freezeVotesThreshold);
    }

    function _updateFreezeProposalPeriod(
        uint32 _freezeProposalPeriod
    ) internal virtual {
        freezeProposalPeriod = _freezeProposalPeriod;
        emit FreezeProposalPeriodUpdated(_freezeProposalPeriod);
    }

    function _updateFreezePeriod(uint32 _freezePeriod) internal virtual {
        freezePeriod = _freezePeriod;
        emit FreezePeriodUpdated(_freezePeriod);
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(IBaseFreezeVotingV1).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
