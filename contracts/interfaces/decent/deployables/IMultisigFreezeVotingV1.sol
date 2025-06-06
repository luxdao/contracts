// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IMultisigFreezeVotingV1 {
    event FreezeProposalCreated(address indexed creator);

    function initialize(
        address owner,
        uint256 freezeVotesThreshold,
        uint32 freezeProposalPeriod,
        uint32 freezePeriod,
        address parentSafe,
        address lightAccountFactory
    ) external;

    function parentSafe() external view returns (address);

    function castFreezeVote() external;

    function userHasFreezeVoted(
        uint48 freezeProposalCreated,
        address voter
    ) external view returns (bool);
}
