// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {ILightAccountFactory} from "../interfaces/light-account/ILightAccountFactory.sol";

contract MockLightAccountFactory is ILightAccountFactory {
    mapping(address => mapping(uint256 => address)) private _accountAddresses;

    function setAccountAddress(
        address owner,
        uint256 salt,
        address account
    ) external {
        _accountAddresses[owner][salt] = account;
    }

    /**
     * @dev Returns a deterministically calculated mock address for a given owner and salt.
     * If an expected address was set via `setExpectedAddress`, it returns that.
     * Otherwise, it falls back to a calculated address (though not strictly CREATE2).
     */
    function getAddress(
        address _owner,
        uint256 _salt
    ) public view override returns (address accountAddress) {
        if (_accountAddresses[_owner][_salt] != address(0)) {
            return _accountAddresses[_owner][_salt];
        }

        // Fallback: A simplified way to generate a pseudo-random, owner-dependent address for testing.
        // This path would typically be used if we weren't pre-setting the address.
        bytes32 MOCK_FACTORY_SALT = keccak256(
            abi.encodePacked("MockLightAccountFactory.salt")
        );
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                _owner,
                MOCK_FACTORY_SALT,
                _salt
            )
        );
        return address(uint160(uint256(hash)));
    }
}
