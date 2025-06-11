// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IProxyFactory} from "../interfaces/decent/singletons/IProxyFactory.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title ProxyFactory
 * @dev Simplified factory contract for deploying ERC1967 proxies with deterministic addresses
 * This factory allows anyone to deploy proxies for any implementation contract
 * using CREATE2 for deterministic addresses
 */
contract ProxyFactory is IProxyFactory {
    // ======================================================================
    // IProxyFactory
    // ======================================================================

    // --- View Functions ---

    function predictProxyAddress(
        address implementation_,
        bytes calldata initData_,
        bytes32 salt_
    ) public view override returns (address) {
        // Validate the implementation address
        if (implementation_.code.length == 0) {
            revert ImplementationMustBeAContract();
        }

        // Calculate the proxy bytecode (implementation address + init data)
        bytes memory proxyConstructorData = abi.encode(
            implementation_,
            initData_
        );
        bytes memory bytecode = abi.encodePacked(
            type(ERC1967Proxy).creationCode,
            proxyConstructorData
        );

        // Calculate the CREATE2 address
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt_,
                keccak256(bytecode)
            )
        );

        return address(uint160(uint256(hash)));
    }

    // --- State-Changing Functions ---

    function deployProxy(
        address implementation_,
        bytes calldata initData_,
        bytes32 salt_
    ) public override returns (address) {
        // Validate the implementation address
        if (implementation_.code.length == 0) {
            revert ImplementationMustBeAContract();
        }

        // Deploy the proxy using CREATE2
        address proxy = address(
            new ERC1967Proxy{salt: salt_}(implementation_, initData_)
        );

        emit ProxyDeployed(proxy, implementation_);
        return proxy;
    }
}
