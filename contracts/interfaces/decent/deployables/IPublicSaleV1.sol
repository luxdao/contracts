// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IPublicSaleV1 {
    // --- Errors ---

    error InvalidSaleCloseTimestamp();

    error InvalidSaleTokenAmounts();

    // --- Structs ---

    // --- Events ---

    // --- Initializer Functions ---

    function initialize(
        address owner_,
        address feeToken_,
        address saleToken_,
        uint256 saleTokenMinimumAmount_,
        uint256 saleTokenMaximumAmount_,
        uint256 saleTokenPrice_,
        uint48 saleStartTimestamp_,
        uint48 saleCloseTimestamp_
    ) external;

    // --- View Functions ---

    // --- State-Changing Functions ---
}
