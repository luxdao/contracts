// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IWarrantV1 {
    // --- Errors ---

    error OnlyWarrantHolder();
    error AddressZero();
    error Expired();
    error TokenLocked();
    error HedgeyStartNotElapsed();
    error WarrantNotExpired();

    // --- Structs ---

    // --- Events ---

    event Executed(address indexed recipient);
    event Clawback(address indexed recipient, uint256 amount);

    // --- Initializer Functions ---

    function initialize(
        bool relativeTime_,
        address owner_,
        address warrantHolder_,
        address token_,
        bytes memory tokenInitData_,
        address feeToken_,
        uint256 tokenAmount_,
        uint256 tokenPrice_,
        address feeReceiver_,
        uint256 expiration_,
        address hedgeyTokenLockupPlans_,
        uint256 hedgeyStart_,
        uint256 hedgeyCliff_,
        uint256 hedgeyRate_,
        uint256 hedgeyPeriod_
    ) external;

    // --- View Functions ---

    function relativeTime() external view returns (bool);

    function warrantHolder() external view returns (address);

    function token() external view returns (address);

    function tokenInitData() external view returns (bytes memory);

    function feeToken() external view returns (address);

    function tokenAmount() external view returns (uint256);

    function tokenPrice() external view returns (uint256);

    function feeReceiver() external view returns (address);

    function expiration() external view returns (uint256);

    function hedgeyTokenLockupPlans() external view returns (address);

    function hedgeyStart() external view returns (uint256);

    function hedgeyRelativeCliff() external view returns (uint256);

    function hedgeyRate() external view returns (uint256);

    function hedgeyPeriod() external view returns (uint256);

    // --- State-Changing Functions ---

    function execute(address recipient_) external;

    function clawback(address recipient_) external;
}
