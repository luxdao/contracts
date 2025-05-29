// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IVotingAdapterBaseV1} from "./IVotingAdapterBaseV1.sol";

interface IVotingAdapterV1 is IVotingAdapterBaseV1 {
    function weightOf(
        address _voter,
        uint32 _proposalId,
        bytes calldata _votingAdapterVoteData
    ) external view returns (uint256 weight);
}
