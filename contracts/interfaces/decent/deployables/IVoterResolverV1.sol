// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IVoterResolverV1 {
    // --- View Functions ---

    function voter(
        address voter_
    ) external view returns (address resolvedVoter);
}
