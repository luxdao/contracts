// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IVotingAdapterV1} from "./IVotingAdapterV1.sol";

interface IERC20VotingAdapterV1 is IVotingAdapterV1 {
    error ProposalNotReadyForSnapshot();
    error AlreadyVoted();

    function initialize(
        address token,
        address strategy,
        uint256 weightPerToken
    ) external;

    function strategy() external view returns (address);

    function token() external view returns (address);

    function weightPerToken() external view returns (uint256);
}
