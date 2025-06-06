// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IBaseFreezeVotingV1} from "./IBaseFreezeVotingV1.sol";

interface IERC721FreezeVotingV1 is IBaseFreezeVotingV1 {
    error NoVotes();
    error UnequalArrays();

    function initialize(
        address owner,
        uint256 freezeVotesThreshold,
        uint32 freezeProposalPeriod,
        uint32 freezePeriod,
        address strategy
    ) external;

    function castFreezeVote(
        address[] calldata tokenAddresses,
        uint256[] calldata tokenIds
    ) external;

    function strategy() external view returns (address);

    function idHasFreezeVoted(
        uint48 freezeProposalCreated,
        address tokenAddress,
        uint256 tokenId
    ) external view returns (bool);
}
