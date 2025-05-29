// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IBaseFreezeVotingV1} from "./IBaseFreezeVotingV1.sol";

interface IERC20FreezeVotingV1 is IBaseFreezeVotingV1 {
    error NoVotes();
    error AlreadyVoted();

    function initialize(
        address owner,
        uint256 freezeVotesThreshold,
        uint32 freezeProposalPeriod,
        uint32 freezePeriod,
        address votesERC20
    ) external;

    function castFreezeVote() external;

    function votesERC20() external view returns (address);
}
