// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IBaseFreezeVotingV1} from "./IBaseFreezeVotingV1.sol";

interface IMultisigFreezeVotingV1 is IBaseFreezeVotingV1 {
    error NotOwner();
    error AlreadyVoted();

    function initialize(
        address owner,
        uint256 freezeVotesThreshold,
        uint32 freezeProposalPeriod,
        uint32 freezePeriod,
        address parentSafe
    ) external;

    function parentSafe() external view returns (address);

    function castFreezeVote() external;
}
