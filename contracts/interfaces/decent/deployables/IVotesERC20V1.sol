// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IVotesERC20V1 {
    struct Allocation {
        address to;
        uint256 amount;
    }

    function initialize(
        string memory _name,
        string memory _symbol,
        Allocation[] memory _allocations,
        address owner
    ) external;

    function clock() external view returns (uint48);

    function CLOCK_MODE() external pure returns (string memory);
}
