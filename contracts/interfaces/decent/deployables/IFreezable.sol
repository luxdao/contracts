// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

/**
 * @title IFreezable
 * @notice Minimal interface for contracts that can be frozen
 * @dev This interface defines the core freeze state that guards need to check.
 * It allows different freeze mechanisms (voting-based, time-based, etc.) to be
 * used interchangeably by guards without coupling to specific implementations.
 *
 * Key design principles:
 * - Minimal surface area - only what guards actually need
 * - No assumptions about freeze mechanism (voting, multisig, time-based, etc.)
 * - Clear semantics for freeze state and timing
 *
 * Implementations may add their own mechanisms for freezing/unfreezing,
 * but must provide these two view functions for guard compatibility.
 */
interface IFreezable {
    /**
     * @notice Checks if the DAO is currently frozen
     * @dev This should return the current freeze state, taking into account
     * any auto-expiry or other state transitions that the implementation uses.
     * @return isFrozen True if the DAO is currently frozen, false otherwise
     */
    function isFrozen() external view returns (bool isFrozen);
}
