// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.28;

interface IModuleProxyFactory {
    event ModuleProxyCreation(
        address indexed proxy,
        address indexed masterCopy
    );

    /// `target` can not be zero.
    error ZeroAddress(address target);

    /// `target` has no code deployed.
    error TargetHasNoCode(address target);

    /// `address_` is already taken.
    error TakenAddress(address address_);

    /// @notice Initialization failed.
    error FailedInitialization();

    function deployModule(
        address masterCopy,
        bytes memory initializer,
        uint256 saltNonce
    ) external returns (address proxy);
}
