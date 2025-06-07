// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IAzoriusFreezeVotingV1 {
    error InvalidVotingAdapter();

    struct VotingAdapterVoteData {
        address votingAdapter;
        bytes adapterVoteData;
    }

    event FreezeProposalCreated(
        address indexed proposer,
        address indexed strategy
    );

    function initialize(
        address owner_,
        uint256 freezeVotesThreshold_,
        uint32 freezeProposalPeriod_,
        uint32 freezePeriod_,
        address parentAzorius_,
        address lightAccountFactory_
    ) external;

    function castFreezeVote(
        VotingAdapterVoteData[] calldata votingAdaptersToUse
    ) external;

    function parentAzorius() external view returns (address);

    function freezeProposalStrategy() external view returns (address);
}
