// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IDecentHatsModificationModule} from "../interfaces/decent/utilities/IDecentHatsModificationModule.sol";
import {DecentHatsModuleUtils} from "./DecentHatsModuleUtils.sol";

/**
 * @title DecentHatsModificationModule
 * @author Decent Labs
 * @notice Implementation for adding roles to existing Hats Protocol trees
 * @dev This contract implements IDecentHatsModificationModule, providing
 * functionality to expand existing organizational structures.
 *
 * Implementation details:
 * - Temporarily attached as Safe module during execution
 * - Adds new roles to existing hat trees
 * - Inherits all functionality from DecentHatsModuleUtils
 * - Prevents race conditions in concurrent proposals
 * - Non-upgradeable utility contract
 *
 * Key differences from CreationModule:
 * - Assumes hat tree already exists
 * - Does not create top hat or admin hat
 * - Focuses only on adding new role hats
 * - Simpler execution flow
 *
 * Security considerations:
 * - Must be enabled as module before execution
 * - Should be disabled immediately after use
 * - All external calls go through Safe's execTransactionFromModule
 *
 * @custom:security-contact security@decentlabs.io
 */
contract DecentHatsModificationModule is
    IDecentHatsModificationModule,
    DecentHatsModuleUtils
{
    // ======================================================================
    // IDecentHatsModificationModule
    // ======================================================================

    // --- State-Changing Functions ---

    /**
     * @inheritdoc IDecentHatsModificationModule
     * @dev Simply delegates to the inherited _processRoleHats function from
     * DecentHatsModuleUtils, which handles all the complex logic for creating
     * roles with payment streams.
     */
    function createRoleHats(
        CreateRoleHatsParams calldata roleHatsParams_
    ) public virtual override {
        _processRoleHats(roleHatsParams_);
    }
}
