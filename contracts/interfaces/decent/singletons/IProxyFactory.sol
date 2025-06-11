// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IProxyFactory {
    // --- Errors ---

    error ImplementationMustBeAContract();

    // --- Events ---

    event ProxyDeployed(address indexed proxy, address indexed implementation);

    // --- View Functions ---

    function predictProxyAddress(
        address implementation_,
        bytes calldata initData_,
        bytes32 salt_
    ) external view returns (address proxy);

    // --- State-Changing Functions ---

    function deployProxy(
        address implementation_,
        bytes calldata initData_,
        bytes32 salt_
    ) external returns (address proxy);
}
