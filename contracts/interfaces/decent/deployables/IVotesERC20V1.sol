// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IVotesERC20V1 {
    // --- Structs ---

    struct Metadata {
        string name;
        string symbol;
    }

    struct Allocation {
        address to;
        uint256 amount;
    }

    // --- Initializer Functions ---

    function initialize(
        Metadata calldata metadata_,
        Allocation[] calldata allocations_,
        address owner_
    ) external;

    // --- Pure Functions ---

    function CLOCK_MODE() external pure returns (string memory clockMode);

    // --- View Functions ---

    function clock() external view returns (uint48 clock);
}
