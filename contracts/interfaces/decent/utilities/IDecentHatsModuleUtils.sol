// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {LockupLinear, Broker} from "../../sablier/types/DataTypes.sol";

/**
 * @title IDecentHatsModuleUtils
 * @notice Utility interface for creating and managing Hats Protocol roles with payment streams
 * @dev This interface provides a comprehensive system for creating role-based organizational
 * structures using Hats Protocol, with integrated Sablier payment streams. It's designed
 * as a utility module that can be temporarily attached to a Safe during execution.
 *
 * Key features:
 * - Batch creation of Hats (roles) with specific parameters
 * - Automatic setup of payment streams for role holders
 * - Support for both termed and untermed roles
 * - Integration with Hats eligibility modules for elections
 * - ERC6551 token-bound accounts for stream recipients
 *
 * Workflow:
 * 1. Safe temporarily enables this module
 * 2. Module creates Hats with specified parameters
 * 3. Module sets up Sablier streams for compensation
 * 4. Module creates eligibility modules for termed positions
 * 5. Safe disables the module after execution
 *
 * Use cases:
 * - Setting up contributor roles with automated payments
 * - Creating elected positions with term limits
 * - Establishing hierarchical organizational structures
 * - Automating compensation for DAO contributors
 */
interface IDecentHatsModuleUtils {
    // --- Structs ---

    /**
     * @notice Parameters for creating a Sablier payment stream
     * @param sablier The Sablier V2 LockupLinear contract address
     * @param sender The address funding the stream (usually the Safe)
     * @param asset The ERC20 token to stream
     * @param timestamps Start and cliff times for the stream
     * @param broker Fee configuration for stream creation
     * @param totalAmount Total tokens to stream over the duration
     * @param cancelable Whether the stream can be cancelled
     * @param transferable Whether the stream NFT can be transferred
     */
    struct SablierStreamParams {
        address sablier;
        address sender;
        address asset;
        LockupLinear.Timestamps timestamps;
        Broker broker;
        uint128 totalAmount;
        bool cancelable;
        bool transferable;
    }

    /**
     * @notice Parameters for creating a single Hat (role)
     * @param wearer Initial wearer of the Hat
     * @param details IPFS hash or description of the role
     * @param imageURI IPFS hash or URL for the Hat's image
     * @param sablierStreamsParams Array of payment streams for this role
     * @param termEndDateTs Term end timestamp (0 for untermed roles)
     * @param maxSupply Maximum number of this Hat that can exist
     * @param isMutable Whether the Hat's properties can be changed
     */
    struct HatParams {
        address wearer;
        string details;
        string imageURI;
        SablierStreamParams[] sablierStreamsParams;
        uint128 termEndDateTs;
        uint32 maxSupply;
        bool isMutable;
    }

    /**
     * @notice Parameters for creating multiple role Hats in one transaction
     * @param hatsProtocol The Hats Protocol contract address
     * @param erc6551Registry Registry for creating token-bound accounts
     * @param hatsAccountImplementation Implementation address for ERC6551 Hat accounts
     * @param topHatId The top Hat ID in the organization hierarchy
     * @param topHatAccount The account holding the top Hat
     * @param keyValuePairs Contract address for emitting metadata about streams
     * @param hatsModuleFactory Factory address for creating Hats modules
     * @param hatsElectionsEligibilityImplementation Election module implementation address
     * @param adminHatId The Hat ID that will admin the new Hats
     * @param hats Array of Hat configurations to create
     */
    struct CreateRoleHatsParams {
        address hatsProtocol;
        address erc6551Registry;
        address hatsAccountImplementation;
        uint256 topHatId;
        address topHatAccount;
        address keyValuePairs;
        address hatsModuleFactory;
        address hatsElectionsEligibilityImplementation;
        uint256 adminHatId;
        HatParams[] hats;
    }
}
