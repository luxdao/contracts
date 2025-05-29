// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {BaseFreezeVotingV1} from "./BaseFreezeVotingV1.sol";
import {Version} from "../Version.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

contract ERC20FreezeVotingV1 is BaseFreezeVotingV1, Version {
    uint16 private constant VERSION = 1;

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

    function initialize(
        address _owner,
        uint256 _freezeVotesThreshold,
        uint32 _freezeProposalPeriod,
        uint32 _freezePeriod,
        address _votesERC20
    ) public virtual initializer {
        __BaseFreezeVotingV1_init(
            _owner,
            _freezeProposalPeriod,
            _freezePeriod,
            _freezeVotesThreshold
        );
        votesERC20 = IVotes(_votesERC20);

        emit ERC20FreezeVotingSetUp(_owner, _votesERC20);
    }

    function castFreezeVote() external virtual override {
        uint256 userVotes;

        if (block.timestamp > freezeProposalCreated + freezeProposalPeriod) {
            freezeProposalCreated = uint48(block.timestamp);

            userVotes = votesERC20.getPastVotes(
                msg.sender,
                freezeProposalCreated - 1
            );

            if (userVotes == 0) {
                revert NoVotes();
            }

            freezeProposalVoteCount = userVotes;

            emit FreezeProposalCreated(msg.sender);
        } else {
            if (userHasFreezeVoted[msg.sender][freezeProposalCreated]) {
                revert AlreadyVoted();
            }

            userVotes = votesERC20.getPastVotes(
                msg.sender,
                freezeProposalCreated - 1
            );

            if (userVotes == 0) {
                revert NoVotes();
            }

            freezeProposalVoteCount += userVotes;
        }

        userHasFreezeVoted[msg.sender][freezeProposalCreated] = true;

        emit FreezeVoteCast(msg.sender, userVotes);
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
