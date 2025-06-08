// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IVotesERC20V1 {
    struct Metadata {
        string name;
        string symbol;
    }

    struct Allocation {
        address to;
        uint256 amount;
    }

    function initialize(
        Metadata calldata metadata_,
        Allocation[] calldata allocations_,
        address owner_
    ) external;

    function clock() external view returns (uint48 clock);

    function CLOCK_MODE() external pure returns (string memory CLOCK_MODE);
}
