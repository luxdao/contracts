// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {BaseFreezeVotingV1} from "./BaseFreezeVotingV1.sol";
import {Version} from "../Version.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/**
 * A [BaseFreezeVoting](./BaseFreezeVoting.md) implementation which handles
 * freezes on ERC20 based token voting DAOs.
 */
contract ERC20FreezeVotingV1 is BaseFreezeVotingV1, Version {
    uint16 private constant VERSION = 1;

    /** A reference to the ERC20 voting token of the subDAO. */
    IVotes public votesERC20;

    event ERC20FreezeVotingSetUp(
        address indexed owner,
        address indexed votesERC20
    );

    error NoVotes();
    error AlreadyVoted();

    constructor() {
        _disableInitializers();
    }

    /**
     * Initialize function, will be triggered when a new instance is deployed.
     *
     * @param _owner The owner of the contract
     * @param _freezeVotesThreshold The number of votes required to activate a freeze
     * @param _freezeProposalPeriod The number of blocks a freeze proposal has to succeed
     * @param _freezePeriod The number of blocks a freeze lasts
     * @param _votesERC20 The ERC20 voting token contract address
     */
    function initialize(
        address _owner,
        uint256 _freezeVotesThreshold,
        uint32 _freezeProposalPeriod,
        uint32 _freezePeriod,
        address _votesERC20
    ) public initializer {
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
        _updateFreezeVotesThreshold(_freezeVotesThreshold);
        _updateFreezeProposalPeriod(_freezeProposalPeriod);
        _updateFreezePeriod(_freezePeriod);
        votesERC20 = IVotes(_votesERC20);

        emit ERC20FreezeVotingSetUp(_owner, _votesERC20);
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
        uint256 userVotes;

        if (block.number > freezeProposalCreatedBlock + freezeProposalPeriod) {
            // create a new freeze proposal and set total votes to msg.sender's vote count

            freezeProposalCreatedBlock = uint32(block.number);

            userVotes = votesERC20.getPastVotes(
                msg.sender,
                freezeProposalCreatedBlock - 1
            );

            if (userVotes == 0) revert NoVotes();

            freezeProposalVoteCount = userVotes;

            emit FreezeProposalCreated(msg.sender);
        } else {
            // there is an existing freeze proposal, count user's votes toward it

            if (userHasFreezeVoted[msg.sender][freezeProposalCreatedBlock])
                revert AlreadyVoted();

            userVotes = votesERC20.getPastVotes(
                msg.sender,
                freezeProposalCreatedBlock - 1
            );

            if (userVotes == 0) revert NoVotes();

            freezeProposalVoteCount += userVotes;
        }

        userHasFreezeVoted[msg.sender][freezeProposalCreatedBlock] = true;

        emit FreezeVoteCast(msg.sender, userVotes);
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
