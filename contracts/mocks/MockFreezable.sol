// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IFreezable} from "../interfaces/decent/deployables/IFreezable.sol";

/**
 * @title MockFreezable
 * @notice Mock implementation of IFreezable for testing freeze guards
 * @dev Provides simple getter/setter functionality for freeze state
 */
contract MockFreezable is IFreezable {
    bool private _isFrozen;

    /**
     * @notice Sets the frozen state for testing
     * @param frozen Whether the DAO should be frozen
     */
    function setIsFrozen(bool frozen) external {
        _isFrozen = frozen;
    }

    /**
     * @inheritdoc IFreezable
     */
    function isFrozen() external view override returns (bool) {
        return _isFrozen;
    }
}
