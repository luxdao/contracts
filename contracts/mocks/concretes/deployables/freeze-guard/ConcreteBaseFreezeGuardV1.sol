// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.28;

import {BaseFreezeGuardV1} from "../../../../deployables/freeze-guard/BaseFreezeGuardV1.sol";
import {Enum} from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";

/**
 * A concrete implementation of BaseGuardV1 for testing
 */
contract ConcreteBaseFreezeGuardV1 is BaseFreezeGuardV1 {
    function setUp(bytes memory initializeParams) public override initializer {
        address _owner = abi.decode(initializeParams, (address));
        __Ownable_init(_owner);
    }

    function checkTransaction(
        address,
        uint256,
        bytes memory,
        Enum.Operation,
        uint256,
        uint256,
        uint256,
        address,
        address payable,
        bytes memory,
        address
    ) external view override {
        // Mock implementation
    }

    function checkAfterExecution(bytes32, bool) external view override {
        // Mock implementation
    }
}
