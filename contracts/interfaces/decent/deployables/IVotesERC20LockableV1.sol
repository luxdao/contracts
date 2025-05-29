// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IVotesERC20LockableV1 {
    event Locked(bool isLocked);
    event Whitelisted(address indexed account, bool isWhitelisted);

    error IsLocked();
    error CannotSwitchLockState(bool newLockState);

    function initialize(
        address owner_,
        bool locked_,
        string memory name_,
        string memory symbol_,
        address[] memory allocationAddresses_,
        uint256[] memory allocationAmounts_
    ) external;

    function lock(bool _locked) external;

    function locked() external view returns (bool);

    function whitelist(address account, bool isWhitelisted) external;

    function whitelisted(address account) external view returns (bool);

    function mint(address to, uint256 amount) external;
}
