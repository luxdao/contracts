// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IPublicSaleV1 {
    // --- Errors ---

    error InvalidSaleStartTimestamp();

    error InvalidSaleTimestamps();

    error InvalidCommitmentAmounts();

    error InvalidTotalCommitmentAmounts();

    error TransferFailed();

    error InvalidBidAmount();

    error SaleCloseTimestampNotElapsed();

    error SaleNotStarted();

    error SaleNotActive();

    error SaleNotEnded();

    error AlreadySettled();

    error DecreaseAmountExceedsCommitment();

    error SaleEnded();

    error MinimumCommitment();

    error MaximumCommitment();

    error MaximumTotalCommitment();

    error NoChangeToCommitment();

    error ZeroAmount();

    error KYCVerificationFailed();

    error InvalidDecreaseCommitmentFee();

    error NoFeesToClaim();

    error ZeroCommitment();

    error InvalidProtocolFee();

    error InvalidCommitmentToken();

    // --- Structs ---

    struct InitializerParams {
        address owner;
        address commitmentToken;
        address saleToken;
        uint256 minimumCommitment;
        uint256 maximumCommitment;
        uint256 minimumTotalCommitment;
        uint256 maximumTotalCommitment;
        uint256 saleTokenPrice;
        uint48 saleStartTimestamp;
        uint48 saleEndTimestamp;
        uint256 decreaseCommitmentFee;
        uint256 protocolFee;
        address saleProceedsReceiver;
        address protocolFeeReceiver;
        address saleTokenHolder;
        address kycVerifier;
    }

    // --- Enums ---

    enum SaleState {
        NOT_STARTED,
        ACTIVE,
        SUCCEEDED,
        FAILED
    }

    // --- Events ---

    event CommitmentIncreased(address indexed account, uint256 amount);

    event CommitmentDecreased(address indexed account, uint256 amount);

    // event FeesClaimed(address indexed recipient, uint256 amount);

    event SuccessfulSaleSettled(address indexed account, address indexed recipient, uint256 saleTokenAmount);

    event FailedSaleSettled(address indexed account, address indexed recipient, uint256 commitmentTokenAmount);

    event SuccessfulSaleOwnerSettled(address indexed owner, uint256 saleProceeds, uint256 protocolFee);

    event FailedSaleOwnerSettled(address indexed owner, uint256 saleTokenAmount, uint256 decreaseCommitmentFees);

    // --- Initializer Functions ---

    function initialize(InitializerParams memory params_) external;

    // --- View Functions ---

    // --- State-Changing Functions ---

}
