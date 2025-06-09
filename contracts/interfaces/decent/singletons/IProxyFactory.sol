// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IProxyFactory {
    event ProxyDeployed(address indexed proxy, address indexed implementation);

    function deployProxy(
        address implementation_,
        bytes calldata initData_,
        bytes32 salt_
    ) external returns (address proxy);

    function predictProxyAddress(
        address implementation_,
        bytes calldata initData_,
        bytes32 salt_
    ) external view returns (address proxy);
}
