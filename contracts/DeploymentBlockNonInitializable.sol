// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IDeploymentBlock} from "./interfaces/decent/IDeploymentBlock.sol";

/**
 * @title DeploymentBlockNonInitializable
 * @author Decent Labs
 * @notice Abstract implementation of deployment block tracking for non-initializable contracts
 * @dev This abstract contract implements IDeploymentBlock, providing a standard
 * way to record when non-initializable contracts are deployed.
 *
 * Implementation details:
 * - Uses EIP-7201 namespaced storage pattern for consistency
 * - Records block number in constructor
 * - Deployment block is immutable once set
 * - Designed for singleton and utility contracts
 * - Must be inherited by non-initializable contracts
 *
 * Usage:
 * - Simply inherit this contract - no initialization needed
 * - The deployment block number is automatically set in the constructor
 * - Query deploymentBlock() to get the recorded value
 *
 * Differences from DeploymentBlockInitializable:
 * - No initializer pattern - uses constructor
 * - No reinitialization concerns
 * - Simpler implementation for non-initializable contracts
 *
 * @custom:security-contact security@decentlabs.io
 */
abstract contract DeploymentBlockNonInitializable is IDeploymentBlock {
    // ======================================================================
    // STATE VARIABLES
    // ======================================================================

    /**
     * @notice Main storage struct for DeploymentBlockNonInitializable following EIP-7201
     * @dev Stores the block number when the contract was deployed
     * @custom:storage-location erc7201:Decent.DeploymentBlockNonInitializable.main
     */
    struct DeploymentBlockNonInitializableStorage {
        /** @notice The block number when this contract was deployed */
        uint256 deploymentBlock;
    }

    /**
     * @dev Storage slot for DeploymentBlockNonInitializableStorage calculated using EIP-7201 formula:
     * keccak256(abi.encode(uint256(keccak256("Decent.DeploymentBlockNonInitializable.main")) - 1)) & ~bytes32(uint256(0xff))
     */
    bytes32
        internal
        constant DEPLOYMENT_BLOCK_NON_INITIALIZABLE_STORAGE_LOCATION =
            0xc876427e52b318a712159f977ed7a1e39aae5351664dbef5e7bad41bfb337800;

    /**
     * @dev Returns the storage struct for DeploymentBlockNonInitializable
     * Following the EIP-7201 namespaced storage pattern to avoid storage collisions
     * @return $ The storage struct for DeploymentBlockNonInitializable
     */
    function _getDeploymentBlockNonInitializableStorage()
        internal
        pure
        returns (DeploymentBlockNonInitializableStorage storage $)
    {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := DEPLOYMENT_BLOCK_NON_INITIALIZABLE_STORAGE_LOCATION
        }
    }

    // ======================================================================
    // CONSTRUCTOR
    // ======================================================================

    /**
     * @notice Records the deployment block during contract construction
     * @dev Automatically captures the current block number when the contract
     * is deployed. This happens once and the value is immutable.
     */
    constructor() {
        DeploymentBlockNonInitializableStorage
            storage $ = _getDeploymentBlockNonInitializableStorage();
        $.deploymentBlock = block.number;
    }

    // ======================================================================
    // IDeploymentBlock
    // ======================================================================

    // --- View Functions ---

    /**
     * @inheritdoc IDeploymentBlock
     */
    function deploymentBlock() public view virtual override returns (uint256) {
        DeploymentBlockNonInitializableStorage
            storage $ = _getDeploymentBlockNonInitializableStorage();
        return $.deploymentBlock;
    }
}
