// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {BaseFreezeVotingV1} from "./BaseFreezeVotingV1.sol";
import {ISafe} from "../../interfaces/safe/ISafe.sol";
import {Version} from "../Version.sol";

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

    function initialize(
        address _owner,
        uint256 _freezeVotesThreshold,
        uint32 _freezeProposalPeriod,
        uint32 _freezePeriod,
        address _parentSafe
    ) public virtual initializer {
        __BaseFreezeVotingV1_init(
            _owner,
            _freezeProposalPeriod,
            _freezePeriod,
            _freezeVotesThreshold
        );
        parentSafe = ISafe(_parentSafe);

        emit MultisigFreezeVotingSetup(_owner, _parentSafe);
    }

    function castFreezeVote() external virtual override {
        if (!parentSafe.isOwner(msg.sender)) revert NotOwner();

        if (block.timestamp > freezeProposalCreated + freezeProposalPeriod) {
            freezeProposalCreated = uint48(block.timestamp);
            freezeProposalVoteCount = 1;
            emit FreezeProposalCreated(msg.sender);
        } else {
            if (userHasFreezeVoted[msg.sender][freezeProposalCreated]) {
                revert AlreadyVoted();
            }
            freezeProposalVoteCount++;
        }

        userHasFreezeVoted[msg.sender][freezeProposalCreated] = true;
        emit FreezeVoteCast(msg.sender, 1);
    }

    function getVersion() public view virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(BaseFreezeVotingV1, Version) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
