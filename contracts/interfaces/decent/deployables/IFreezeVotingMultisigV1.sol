// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IFreezeVotingMultisigV1 {
    event FreezeProposalCreated(address indexed creator);

    function initialize(
        address owner_,
        uint256 freezeVotesThreshold_,
        uint32 freezeProposalPeriod_,
        uint32 freezePeriod_,
        address parentSafe_,
        address lightAccountFactory
    ) external;

    function parentSafe() external view returns (address parentSafe);

    function castFreezeVote() external;

    function accountHasFreezeVoted(
        uint48 freezeProposalCreated_,
        address account_
    ) external view returns (bool accountHasFreezeVoted);
}
