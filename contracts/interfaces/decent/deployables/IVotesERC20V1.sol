// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IVotesERC20V1 {
    function initialize(
        string memory _name,
        string memory _symbol,
        address[] memory _allocationAddresses,
        uint256[] memory _allocationAmounts,
        address owner
    ) external;

    function clock() external view returns (uint48);

    function CLOCK_MODE() external pure returns (string memory);
}
