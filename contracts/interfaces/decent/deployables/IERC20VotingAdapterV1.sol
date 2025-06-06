// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IERC20VotingAdapterV1 {
    error ProposalNotReadyForSnapshot();
    error AlreadyVoted();

    function initialize(
        address token,
        address strategy,
        uint256 weightPerToken
    ) external;

    function token() external view returns (address);

    function weightPerToken() external view returns (uint256);
}
