// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.28;

import {BaseGuardV1} from "../../../../deployables/freeze-guard/BaseGuardV1.sol";
import {Enum} from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";

/**
 * A concrete implementation of BaseGuardV1 for testing
 */
contract ConcreteBaseGuardV1 is BaseGuardV1 {
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
