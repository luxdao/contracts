// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IDecentHatsModuleUtils} from "../interfaces/decent/utilities/IDecentHatsModuleUtils.sol";
import {IERC6551Registry} from "../interfaces/erc6551/IERC6551Registry.sol";
import {IHats} from "../interfaces/hats/IHats.sol";
import {IHatsElectionsEligibility} from "../interfaces/hats/modules/IHatsElectionsEligibility.sol";
import {IHatsModuleFactory} from "../interfaces/hats/IHatsModuleFactory.sol";
import {IKeyValuePairsV1} from "../interfaces/decent/singletons/IKeyValuePairsV1.sol";
import {ISablierV2LockupLinear} from "../interfaces/sablier/ISablierV2LockupLinear.sol";
import {LockupLinear} from "../interfaces/sablier/types/DataTypes.sol";
import {Enum} from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";
import {IAvatar} from "@gnosis-guild/zodiac/contracts/interfaces/IAvatar.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title DecentHatsModuleUtils
 * @author Decent Labs
 * @notice Abstract utility contract for Hats Protocol role management with payment streams
 * @dev This abstract contract implements IDecentHatsModuleUtils, providing reusable
 * functionality for creating organizational roles with automated compensation.
 *
 * Implementation details:
 * - Abstract contract providing utilities for concrete implementations
 * - Temporarily attached as Safe module during execution
 * - Handles batch creation of Hats with Sablier streams
 * - Supports both termed (elected) and untermed positions
 * - Uses ERC6551 for token-bound accounts as stream recipients
 * - Integrates with HatsElectionsEligibility for termed roles
 *
 * Key workflows:
 * 1. Create eligibility modules for termed positions
 * 2. Create and mint Hats with specified parameters
 * 3. Set up stream recipients (wearer or token-bound account)
 * 4. Create Sablier payment streams for compensation
 * 5. Emit metadata for stream-Hat associations
 *
 * Security considerations:
 * - All external calls go through Safe's execTransactionFromModule
 * - Requires module to be enabled on Safe before use
 * - Should be disabled after execution to prevent misuse
 *
 * @custom:security-contact security@decentlabs.io
 */
abstract contract DecentHatsModuleUtils is IDecentHatsModuleUtils {
    // ======================================================================
    // STATE VARIABLES
    // ======================================================================

    /** @notice Salt used for deterministic ERC6551 account creation */
    bytes32 public constant SALT =
        0x5d0e6ce4fd951366cc55da93f6e79d8b81483109d79676a04bcc2bed6a4b5072;

    // ======================================================================
    // INTERNAL HELPERS
    // ======================================================================

    /**
     * @notice Processes batch creation of role Hats with payment streams
     * @dev Main orchestration function that coordinates Hat creation workflow.
     * For each Hat: creates eligibility module, mints Hat, sets up recipient, creates streams.
     * @param roleHatsParams_ Complete configuration for all Hats to create
     */
    function _processRoleHats(
        CreateRoleHatsParams memory roleHatsParams_
    ) internal virtual {
        for (uint256 i = 0; i < roleHatsParams_.hats.length; ) {
            HatParams memory hatParams = roleHatsParams_.hats[i];

            // Step 1: Create eligibility module for termed positions
            // Returns election module for termed, top hat account for untermed
            address eligibilityAddress = _createEligibilityModule(
                roleHatsParams_.hatsProtocol,
                roleHatsParams_.hatsModuleFactory,
                roleHatsParams_.hatsElectionsEligibilityImplementation,
                roleHatsParams_.topHatId,
                roleHatsParams_.topHatAccount,
                roleHatsParams_.adminHatId,
                hatParams.termEndDateTs
            );

            // Step 2: Create the Hat and mint to initial wearer
            uint256 hatId = _createAndMintHat(
                roleHatsParams_.hatsProtocol,
                roleHatsParams_.adminHatId,
                hatParams,
                eligibilityAddress,
                roleHatsParams_.topHatAccount
            );

            // Step 3: Determine stream recipient based on termed status
            // Termed: wearer receives directly, Untermed: ERC6551 account receives
            address streamRecipient = _setupStreamRecipient(
                roleHatsParams_.erc6551Registry,
                roleHatsParams_.hatsAccountImplementation,
                roleHatsParams_.hatsProtocol,
                hatParams.termEndDateTs,
                hatParams.wearer,
                hatId
            );

            // Step 4: Create payment streams for this role
            _processSablierStreams(
                hatParams.sablierStreamsParams,
                streamRecipient,
                roleHatsParams_.keyValuePairs,
                hatId
            );

            unchecked {
                ++i;
            }
        }
    }

    function _createEligibilityModule(
        address hatsProtocol_,
        address hatsModuleFactory_,
        address hatsElectionsEligibilityImplementation_,
        uint256 topHatId_,
        address topHatAccount_,
        uint256 adminHatId_,
        uint128 termEndDateTs_
    ) internal virtual returns (address) {
        // If the Hat is termed, create the eligibility module
        if (termEndDateTs_ != 0) {
            return
                IHatsModuleFactory(hatsModuleFactory_).createHatsModule(
                    hatsElectionsEligibilityImplementation_,
                    IHats(hatsProtocol_).getNextId(adminHatId_),
                    abi.encode(topHatId_, uint256(0)), // [BALLOT_BOX_ID, ADMIN_HAT_ID]
                    abi.encode(termEndDateTs_),
                    uint256(SALT)
                );
        }

        // Otherwise, return the Top Hat account
        return topHatAccount_;
    }

    /**
     * @notice Creates a Hat and mints it to the initial wearer
     * @dev Handles both termed and untermed Hat creation. For termed positions,
     * also nominates the wearer through the election module.
     * @param hatsProtocol_ Hats Protocol contract address
     * @param adminHatId_ Parent Hat that will admin the new Hat
     * @param hat_ Configuration for the Hat to create
     * @param eligibilityAddress_ Eligibility module address (election or top hat)
     * @param topHatAccount_ Account holding the top hat (for toggle permissions)
     * @return hatId The ID of the newly created Hat
     */
    function _createAndMintHat(
        address hatsProtocol_,
        uint256 adminHatId_,
        HatParams memory hat_,
        address eligibilityAddress_,
        address topHatAccount_
    ) internal virtual returns (uint256) {
        // Calculate the next Hat ID before creation
        uint256 hatId = IHats(hatsProtocol_).getNextId(adminHatId_);

        // Create the Hat with specified parameters
        IAvatar(msg.sender).execTransactionFromModule(
            hatsProtocol_,
            0,
            abi.encodeCall(
                IHats.createHat,
                (
                    adminHatId_,
                    hat_.details,
                    hat_.maxSupply,
                    eligibilityAddress_,
                    topHatAccount_,
                    hat_.isMutable,
                    hat_.imageURI
                )
            ),
            Enum.Operation.Call
        );

        // For termed positions, elect the initial wearer
        if (hat_.termEndDateTs != 0) {
            address[] memory nominatedWearers = new address[](1);
            nominatedWearers[0] = hat_.wearer;

            // Elect through the eligibility module
            IAvatar(msg.sender).execTransactionFromModule(
                eligibilityAddress_,
                0,
                abi.encodeCall(
                    IHatsElectionsEligibility.elect,
                    (hat_.termEndDateTs, nominatedWearers)
                ),
                Enum.Operation.Call
            );
        }

        // Mint the Hat to the wearer
        IAvatar(msg.sender).execTransactionFromModule(
            hatsProtocol_,
            0,
            abi.encodeCall(IHats.mintHat, (hatId, hat_.wearer)),
            Enum.Operation.Call
        );
        return hatId;
    }

    function _setupStreamRecipient(
        address erc6551Registry_,
        address hatsAccountImplementation_,
        address hatsProtocol_,
        uint128 termEndDateTs_,
        address wearer_,
        uint256 hatId_
    ) internal virtual returns (address) {
        // If the hat is termed, the wearer is the stream recipient
        if (termEndDateTs_ != 0) {
            return wearer_;
        }

        // Otherwise, the Hat's smart account is the stream recipient
        return
            IERC6551Registry(erc6551Registry_).createAccount(
                hatsAccountImplementation_,
                SALT,
                block.chainid,
                hatsProtocol_,
                hatId_
            );
    }

    /**
     * @notice Creates Sablier payment streams for a Hat role
     * @dev Handles token approvals, stream creation, and metadata emission.
     * Each stream is associated with the Hat ID in KeyValuePairs for tracking.
     * @param streamParams_ Array of stream configurations
     * @param streamRecipient_ Address that will receive stream payments
     * @param keyValuePairs_ Contract for emitting stream-Hat associations
     * @param hatId_ The Hat ID to associate with streams
     */
    function _processSablierStreams(
        SablierStreamParams[] memory streamParams_,
        address streamRecipient_,
        address keyValuePairs_,
        uint256 hatId_
    ) internal virtual {
        for (uint256 i = 0; i < streamParams_.length; ) {
            SablierStreamParams memory sablierStreamParams = streamParams_[i];

            // Step 1: Approve Sablier to spend tokens
            IAvatar(msg.sender).execTransactionFromModule(
                sablierStreamParams.asset,
                0,
                abi.encodeCall(
                    IERC20.approve,
                    (
                        sablierStreamParams.sablier,
                        sablierStreamParams.totalAmount
                    )
                ),
                Enum.Operation.Call
            );

            // Get the stream ID that will be created
            uint256 streamId = ISablierV2LockupLinear(
                sablierStreamParams.sablier
            ).nextStreamId();

            // Step 2: Create the Sablier stream
            IAvatar(msg.sender).execTransactionFromModule(
                sablierStreamParams.sablier,
                0,
                abi.encodeCall(
                    ISablierV2LockupLinear.createWithTimestamps,
                    (
                        LockupLinear.CreateWithTimestamps({
                            sender: sablierStreamParams.sender,
                            recipient: streamRecipient_,
                            totalAmount: sablierStreamParams.totalAmount,
                            asset: IERC20(sablierStreamParams.asset),
                            cancelable: sablierStreamParams.cancelable,
                            transferable: sablierStreamParams.transferable,
                            timestamps: sablierStreamParams.timestamps,
                            broker: sablierStreamParams.broker
                        })
                    )
                ),
                Enum.Operation.Call
            );

            // Step 3: Emit metadata linking Hat ID to stream ID
            // Format: "hatId:streamId" for easy parsing
            IKeyValuePairsV1.KeyValuePair[]
                memory keyValuePairs = new IKeyValuePairsV1.KeyValuePair[](1);
            keyValuePairs[0] = IKeyValuePairsV1.KeyValuePair({
                key: "hatIdToStreamId",
                value: string(
                    abi.encodePacked(
                        Strings.toString(hatId_),
                        ":",
                        Strings.toString(streamId)
                    )
                )
            });

            IAvatar(msg.sender).execTransactionFromModule(
                keyValuePairs_,
                0,
                abi.encodeCall(IKeyValuePairsV1.updateValues, (keyValuePairs)),
                Enum.Operation.Call
            );

            unchecked {
                ++i;
            }
        }
    }
}
