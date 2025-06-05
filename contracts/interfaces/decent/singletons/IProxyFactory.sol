// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IProxyFactory {
    event ProxyDeployed(address indexed proxy, address indexed implementation);

    function deployProxy(
        address implementation,
        bytes calldata initData,
        bytes32 salt
    ) external returns (address proxy);

    function predictProxyAddress(
        address implementation,
        bytes calldata initData,
        bytes32 salt,
        address deployer
    ) external view returns (address);
}
