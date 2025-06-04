// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {BaseFreezeVotingV1} from "./BaseFreezeVotingV1.sol";
import {Version} from "../Version.sol";
import {IERC20FreezeVotingV1} from "../../interfaces/decent/deployables/IERC20FreezeVotingV1.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

contract ERC20FreezeVotingV1 is
    IERC20FreezeVotingV1,
    BaseFreezeVotingV1,
    Version
{
    uint16 private constant VERSION = 1;

    IVotes internal _votesERC20;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        uint256 freezeVotesThreshold_,
        uint32 freezeProposalPeriod_,
        uint32 freezePeriod_,
        address votesERC20_
    ) public virtual override initializer {
        __BaseFreezeVotingV1_init(
            owner_,
            freezeProposalPeriod_,
            freezePeriod_,
            freezeVotesThreshold_
        );
        _votesERC20 = IVotes(votesERC20_);
    }

    function votesERC20() external view virtual override returns (address) {
        return address(_votesERC20);
    }

    function castFreezeVote() external virtual override {
        uint256 userVotes;

        if (block.timestamp > _freezeProposalCreated + _freezeProposalPeriod) {
            _freezeProposalCreated = uint48(block.timestamp);

            userVotes = _votesERC20.getPastVotes(
                msg.sender,
                _freezeProposalCreated - 1
            );

            if (userVotes == 0) {
                revert NoVotes();
            }

            _freezeProposalVoteCount = userVotes;

            emit FreezeProposalCreated(msg.sender);
        } else {
            if (_userHasFreezeVoted[msg.sender][_freezeProposalCreated]) {
                revert AlreadyVoted();
            }

            userVotes = _votesERC20.getPastVotes(
                msg.sender,
                _freezeProposalCreated - 1
            );

            if (userVotes == 0) {
                revert NoVotes();
            }

            _freezeProposalVoteCount += userVotes;
        }

        _userHasFreezeVoted[msg.sender][_freezeProposalCreated] = true;

        emit FreezeVoteCast(msg.sender, userVotes);
    }

    function version() public view virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(BaseFreezeVotingV1, Version) returns (bool) {
        return
            interfaceId == type(IERC20FreezeVotingV1).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
