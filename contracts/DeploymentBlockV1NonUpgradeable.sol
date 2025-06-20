// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IDeploymentBlockV1} from "./interfaces/decent/IDeploymentBlockV1.sol";

/**
 * @title DeploymentBlockV1NonUpgradeable
 * @author Decent Labs
 * @notice Abstract implementation of deployment block tracking for non-upgradeable contracts
 * @dev This abstract contract implements IDeploymentBlockV1, providing a standard
 * way to record when non-upgradeable contracts are deployed.
 *
 * Implementation details:
 * - Uses EIP-7201 namespaced storage pattern for consistency
 * - Records block number in constructor
 * - Deployment block is immutable once set
 * - Designed for singleton and utility contracts
 * - Must be inherited by non-upgradeable contracts
 *
 * Usage:
 * - Simply inherit this contract - no initialization needed
 * - The deployment block number is automatically set in the constructor
 * - Query deploymentBlock() to get the recorded value
 *
 * Differences from DeploymentBlockV1:
 * - No initializer pattern - uses constructor
 * - No reinitialization concerns
 * - Simpler implementation for immutable contracts
 *
 * @custom:security-contact security@decentlabs.io
 */
abstract contract DeploymentBlockV1NonUpgradeable is IDeploymentBlockV1 {
    // ======================================================================
    // STATE VARIABLES
    // ======================================================================

    /**
     * @notice Main storage struct for DeploymentBlockV1NonUpgradeable following EIP-7201
     * @dev Stores the block number when the contract was deployed
     * @custom:storage-location erc7201:Decent.DeploymentBlockNonUpgradeable.main
     */
    struct DeploymentBlockNonUpgradeableStorage {
        /** @notice The block number when this contract was deployed */
        uint256 deploymentBlock;
    }

    /**
     * @dev Storage slot for DeploymentBlockNonUpgradeableStorage calculated using EIP-7201 formula:
     * keccak256(abi.encode(uint256(keccak256("Decent.DeploymentBlockNonUpgradeable.main")) - 1)) & ~bytes32(uint256(0xff))
     */
    bytes32
        internal constant DEPLOYMENT_BLOCK_NON_UPGRADEABLE_STORAGE_LOCATION =
        0x75420419808cf80485ed57399dff70df3a6d545855667cf2ad8ee38294f38000;

    /**
     * @dev Returns the storage struct for DeploymentBlockV1NonUpgradeable
     * Following the EIP-7201 namespaced storage pattern to avoid storage collisions
     */
    function _getDeploymentBlockNonUpgradeableStorage()
        internal
        pure
        returns (DeploymentBlockNonUpgradeableStorage storage $)
    {
        assembly {
            $.slot := DEPLOYMENT_BLOCK_NON_UPGRADEABLE_STORAGE_LOCATION
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
        DeploymentBlockNonUpgradeableStorage
            storage $ = _getDeploymentBlockNonUpgradeableStorage();
        $.deploymentBlock = block.number;
    }

    // ======================================================================
    // IDeploymentBlockV1
    // ======================================================================

    // --- View Functions ---

    /**
     * @inheritdoc IDeploymentBlockV1
     */
    function deploymentBlock() public view virtual override returns (uint256) {
        DeploymentBlockNonUpgradeableStorage
            storage $ = _getDeploymentBlockNonUpgradeableStorage();
        return $.deploymentBlock;
    }
}
