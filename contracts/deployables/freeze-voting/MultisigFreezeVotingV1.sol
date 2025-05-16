// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {BaseFreezeVotingV1} from "./BaseFreezeVotingV1.sol";
import {ISafe} from "../../interfaces/safe/ISafe.sol";
import {Version} from "../Version.sol";

/**
 * A BaseFreezeVoting implementation which handles freezes on multi-sig (Safe) based DAOs.
 */
contract MultisigFreezeVotingV1 is BaseFreezeVotingV1, Version {
    uint16 private constant VERSION = 1;

    ISafe public parentSafe;

    event MultisigFreezeVotingSetup(
        address indexed owner,
        address indexed parentSafe
    );

    error NotOwner();
    error AlreadyVoted();

    constructor() {
        _disableInitializers();
    }

    /**
     * Initialize function, will be triggered when a new instance is deployed.
     *
     * @param _owner The owner of the contract
     * @param _freezeVotesThreshold The number of votes required to activate a freeze
     * @param _freezeProposalPeriod The number of seconds a freeze proposal has to succeed
     * @param _freezePeriod The number of seconds a freeze lasts
     * @param _parentSafe The address of the parent Safe contract
     */
    function initialize(
        address _owner,
        uint256 _freezeVotesThreshold,
        uint32 _freezeProposalPeriod,
        uint32 _freezePeriod,
        address _parentSafe
    ) public initializer {
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
        _updateFreezeVotesThreshold(_freezeVotesThreshold);
        _updateFreezeProposalPeriod(_freezeProposalPeriod);
        _updateFreezePeriod(_freezePeriod);
        parentSafe = ISafe(_parentSafe);

        emit MultisigFreezeVotingSetup(_owner, _parentSafe);
    }

    /**
     * @dev Function that authorizes an upgrade. Only the owner can upgrade the implementation.
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal virtual override onlyOwner {}

    /** @inheritdoc BaseFreezeVotingV1*/
    function castFreezeVote() external override {
        if (!parentSafe.isOwner(msg.sender)) revert NotOwner();

        if (block.timestamp > freezeProposalCreated + freezeProposalPeriod) {
            // create a new freeze proposal and count the caller's vote

            freezeProposalCreated = uint48(block.timestamp);

            freezeProposalVoteCount = 1;

            emit FreezeProposalCreated(msg.sender);
        } else {
            // there is an existing freeze proposal, count the caller's vote

            if (userHasFreezeVoted[msg.sender][freezeProposalCreated])
                revert AlreadyVoted();

            freezeProposalVoteCount++;
        }

        userHasFreezeVoted[msg.sender][freezeProposalCreated] = true;

        emit FreezeVoteCast(msg.sender, 1);
    }

    /// Implementation for the version
    function getVersion() public view virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(BaseFreezeVotingV1, Version) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
