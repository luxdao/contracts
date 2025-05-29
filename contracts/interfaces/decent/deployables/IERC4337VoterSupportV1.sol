// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IERC4337VoterSupportV1 {
    event VotingPeriodEnded(
        uint32 indexed proposalId,
        uint48 votingEndTimestamp,
        uint48 currentTimestamp
    );

    function voter(address _msgSender) external view returns (address);

    function votingPeriodEnded(uint32 _proposalId) external view returns (bool);
}
