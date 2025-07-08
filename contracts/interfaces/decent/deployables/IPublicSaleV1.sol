// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IPublicSaleV1 {
    // --- Errors ---

    error InvalidSaleEndTimestamp();

    error InvalidSaleTimestamps();

    error InvalidCommitmentAmounts();

    error TransferFailed();

    error InvalidBidAmount();

    error SaleCloseTimestampNotElapsed();

    error SaleNotStarted();

    error SaleClosed();

    error MinimumCommitment();

    error MaximumCommitment();

    error MaximumTotalCommitment();

    // --- Structs ---

    struct InitializerParams {
        address owner_;
        address commitmentToken_;
        address saleToken_;
        uint256 minimumCommitment_;
        uint256 maximumCommitment_;
        uint256 minimumTotalCommitment_;
        uint256 maximumTotalCommitment_;
        uint256 saleTokenPrice_;
        uint48 saleStartTimestamp_;
        uint48 saleCloseTimestamp_;
        address saleTokenHolder_;
    }

    // --- Events ---

    event BidPlaced(address indexed user, uint256 amount);

    // --- Initializer Functions ---

    function initialize(InitializerParams memory params_) external;

    // --- View Functions ---

    // --- State-Changing Functions ---

    function commit(uint256 amount_) external payable;

    function close() external;
}
