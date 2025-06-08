// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IFreezeVotingBaseV1 {
    // --- Errors ---

    error NoVotes();

    // --- Events ---

    event FreezeVoteCast(address indexed voter_, uint256 votesCast_);

    // --- View Functions ---

    function freezeProposalCreated()
        external
        view
        returns (uint48 freezeProposalCreated);

    function freezeProposalVoteCount()
        external
        view
        returns (uint256 freezeProposalVoteCount);

    function freezeProposalPeriod()
        external
        view
        returns (uint32 freezeProposalPeriod);

    function freezePeriod() external view returns (uint32 freezePeriod);

    function freezeVotesThreshold()
        external
        view
        returns (uint256 freezeVotesThreshold);

    function freezeActivated() external view returns (uint48 freezeActivated);

    function isFrozen() external view returns (bool isFrozen);

    // --- State-Changing Functions ---

    function unfreeze() external;
}
