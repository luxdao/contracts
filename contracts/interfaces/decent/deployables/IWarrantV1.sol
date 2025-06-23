// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IWarrantV1 {
    // --- Errors ---

    // --- Structs ---

    // --- Events ---

    // --- Initializer Functions ---

    function initialize(
        address owner_,
        address investor_,
        address token_,
        uint256 tokenAmount_,
        uint256 tokenPrice_,
        address feeReceiver_,
        uint256 expiration_,
        uint256 hedgeyCliff_,
        uint256 hedgeyRate_,
        uint256 hedgeyPeriod_
    ) external;

    // --- View Functions ---

    function investor() external view returns (address);

    function token() external view returns (address);

    function tokenAmount() external view returns (uint256);

    function tokenPrice() external view returns (uint256);

    function feeReceiver() external view returns (address);

    function expiration() external view returns (uint256);

    function hedgeyCliff() external view returns (uint256);

    function hedgeyRate() external view returns (uint256);

    function hedgeyPeriod() external view returns (uint256);
    
}
