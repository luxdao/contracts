// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IBaseFreezeVotingV1} from "../../interfaces/decent/deployables/IBaseFreezeVotingV1.sol";
import {IMultisigFreezeVotingV1} from "../../interfaces/decent/deployables/IMultisigFreezeVotingV1.sol";
import {IVersion} from "../../interfaces/decent/deployables/IVersion.sol";
import {ISafe} from "../../interfaces/safe/ISafe.sol";
import {BaseFreezeVotingV1} from "./BaseFreezeVotingV1.sol";
import {Version} from "../Version.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

contract MultisigFreezeVotingV1 is
    IMultisigFreezeVotingV1,
    BaseFreezeVotingV1,
    Version,
    ERC165
{
    uint16 private constant VERSION = 1;

    ISafe internal _parentSafe;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        uint256 freezeVotesThreshold_,
        uint32 freezeProposalPeriod_,
        uint32 freezePeriod_,
        address parentSafe_
    ) public virtual override initializer {
        __BaseFreezeVotingV1_init(
            owner_,
            freezeProposalPeriod_,
            freezePeriod_,
            freezeVotesThreshold_
        );
        _parentSafe = ISafe(parentSafe_);
    }

    function parentSafe() external view virtual override returns (address) {
        return address(_parentSafe);
    }

    function castFreezeVote() external virtual override {
        if (!_parentSafe.isOwner(msg.sender)) revert NotOwner();

        if (block.timestamp > _freezeProposalCreated + _freezeProposalPeriod) {
            _freezeProposalCreated = uint48(block.timestamp);
            _freezeProposalVoteCount = 1;
            emit FreezeProposalCreated(msg.sender);
        } else {
            if (_userHasFreezeVoted[msg.sender][_freezeProposalCreated]) {
                revert AlreadyVoted();
            }
            _freezeProposalVoteCount++;
        }

        _userHasFreezeVoted[msg.sender][_freezeProposalCreated] = true;
        emit FreezeVoteCast(msg.sender, 1);
    }

    function version() public view virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(IMultisigFreezeVotingV1).interfaceId ||
            interfaceId == type(IBaseFreezeVotingV1).interfaceId ||
            interfaceId == type(IVersion).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
