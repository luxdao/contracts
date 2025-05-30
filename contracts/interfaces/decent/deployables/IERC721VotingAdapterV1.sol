// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IVotingAdapterV1} from "./IVotingAdapterV1.sol";

interface IERC721VotingAdapterV1 is IVotingAdapterV1 {
    error InvalidTokenAddress();
    error InvalidWeightPerToken();

    function initialize(address token, uint256 weightPerToken) external;

    function token() external view returns (address);

    function weightPerToken() external view returns (uint256);

    function tokenIdUsedForVote(
        uint32 proposalId,
        uint256 tokenId
    ) external view returns (bool);
}
