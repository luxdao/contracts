// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IERC6551Registry} from "../interfaces/erc6551/IERC6551Registry.sol";
import {IHats} from "../interfaces/hats/IHats.sol";
import {IHatsModuleFactory} from "../interfaces/hats/IHatsModuleFactory.sol";
import {ISablierV2LockupLinear} from "../interfaces/sablier/ISablierV2LockupLinear.sol";
import {LockupLinear, Broker} from "../interfaces/sablier/types/DataTypes.sol";
import {Enum} from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";
import {IAvatar} from "@gnosis-guild/zodiac/contracts/interfaces/IAvatar.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

abstract contract DecentHatsModuleUtils {
    bytes32 public constant SALT =
        0x5d0e6ce4fd951366cc55da93f6e79d8b81483109d79676a04bcc2bed6a4b5072;

    struct SablierStreamParams {
        ISablierV2LockupLinear sablier;
        address sender;
        address asset;
        LockupLinear.Timestamps timestamps;
        Broker broker;
        uint128 totalAmount;
        bool cancelable;
        bool transferable;
    }

    struct HatParams {
        address wearer;
        string details;
        string imageURI;
        SablierStreamParams[] sablierStreamsParams;
        uint128 termEndDateTs; // If 0, this is an untermed Hat
        uint32 maxSupply;
        bool isMutable;
    }

    struct CreateRoleHatsParams {
        IHats hatsProtocol;
        IERC6551Registry erc6551Registry;
        address hatsAccountImplementation;
        uint256 topHatId;
        address topHatAccount;
        address keyValuePairs;
        IHatsModuleFactory hatsModuleFactory;
        address hatsElectionsEligibilityImplementation;
        uint256 adminHatId;
        HatParams[] hats;
    }

    function _processRoleHats(
        CreateRoleHatsParams memory roleHatsParams_
    ) internal {
        for (uint256 i = 0; i < roleHatsParams_.hats.length; ) {
            HatParams memory hatParams = roleHatsParams_.hats[i];

            // Create eligibility module if needed
            address eligibilityAddress = _createEligibilityModule(
                roleHatsParams_.hatsProtocol,
                roleHatsParams_.hatsModuleFactory,
                roleHatsParams_.hatsElectionsEligibilityImplementation,
                roleHatsParams_.topHatId,
                roleHatsParams_.topHatAccount,
                roleHatsParams_.adminHatId,
                hatParams.termEndDateTs
            );

            // Create and Mint the Role Hat
            uint256 hatId = _createAndMintHat(
                roleHatsParams_.hatsProtocol,
                roleHatsParams_.adminHatId,
                hatParams,
                eligibilityAddress,
                roleHatsParams_.topHatAccount
            );

            // Get the stream recipient (based on termed or not)
            address streamRecipient = _setupStreamRecipient(
                roleHatsParams_.erc6551Registry,
                roleHatsParams_.hatsAccountImplementation,
                address(roleHatsParams_.hatsProtocol),
                hatParams.termEndDateTs,
                hatParams.wearer,
                hatId
            );

            // Create streams
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
        IHats hatsProtocol_,
        IHatsModuleFactory hatsModuleFactory_,
        address hatsElectionsEligibilityImplementation_,
        uint256 topHatId_,
        address topHatAccount_,
        uint256 adminHatId_,
        uint128 termEndDateTs_
    ) private returns (address) {
        // If the Hat is termed, create the eligibility module
        if (termEndDateTs_ != 0) {
            return
                hatsModuleFactory_.createHatsModule(
                    hatsElectionsEligibilityImplementation_,
                    hatsProtocol_.getNextId(adminHatId_),
                    abi.encode(topHatId_, uint256(0)), // [BALLOT_BOX_ID, ADMIN_HAT_ID]
                    abi.encode(termEndDateTs_),
                    uint256(SALT)
                );
        }

        // Otherwise, return the Top Hat account
        return topHatAccount_;
    }

    function _createAndMintHat(
        IHats hatsProtocol_,
        uint256 adminHatId_,
        HatParams memory hat_,
        address eligibilityAddress_,
        address topHatAccount_
    ) private returns (uint256) {
        // Grab the next Hat ID (before creating it)
        uint256 hatId = hatsProtocol_.getNextId(adminHatId_);

        // Create the new Hat
        IAvatar(msg.sender).execTransactionFromModule(
            address(hatsProtocol_),
            0,
            abi.encodeWithSignature(
                "createHat(uint256,string,uint32,address,address,bool,string)",
                adminHatId_,
                hat_.details,
                hat_.maxSupply,
                eligibilityAddress_,
                topHatAccount_,
                hat_.isMutable,
                hat_.imageURI
            ),
            Enum.Operation.Call
        );

        // If the Hat is termed, nominate the wearer as the eligible member
        if (hat_.termEndDateTs != 0) {
            address[] memory nominatedWearers = new address[](1);
            nominatedWearers[0] = hat_.wearer;

            IAvatar(msg.sender).execTransactionFromModule(
                eligibilityAddress_,
                0,
                abi.encodeWithSignature(
                    "elect(uint128,address[])",
                    hat_.termEndDateTs,
                    nominatedWearers
                ),
                Enum.Operation.Call
            );
        }

        // Mint the Hat
        IAvatar(msg.sender).execTransactionFromModule(
            address(hatsProtocol_),
            0,
            abi.encodeWithSignature(
                "mintHat(uint256,address)",
                hatId,
                hat_.wearer
            ),
            Enum.Operation.Call
        );
        return hatId;
    }

    // Exists to avoid stack too deep errors
    function _setupStreamRecipient(
        IERC6551Registry erc6551Registry_,
        address hatsAccountImplementation_,
        address hatsProtocol_,
        uint128 termEndDateTs_,
        address wearer_,
        uint256 hatId_
    ) private returns (address) {
        // If the hat is termed, the wearer is the stream recipient
        if (termEndDateTs_ != 0) {
            return wearer_;
        }

        // Otherwise, the Hat's smart account is the stream recipient
        return
            erc6551Registry_.createAccount(
                hatsAccountImplementation_,
                SALT,
                block.chainid,
                hatsProtocol_,
                hatId_
            );
    }

    function _processSablierStreams(
        SablierStreamParams[] memory streamParams_,
        address streamRecipient_,
        address keyValuePairs_,
        uint256 hatId_
    ) private {
        for (uint256 i = 0; i < streamParams_.length; ) {
            SablierStreamParams memory sablierStreamParams = streamParams_[i];

            // Approve tokens for Sablier
            IAvatar(msg.sender).execTransactionFromModule(
                sablierStreamParams.asset,
                0,
                abi.encodeWithSignature(
                    "approve(address,uint256)",
                    sablierStreamParams.sablier,
                    sablierStreamParams.totalAmount
                ),
                Enum.Operation.Call
            );
            uint256 streamId = ISablierV2LockupLinear(
                sablierStreamParams.sablier
            ).nextStreamId();

            // Proxy the Sablier call through IAvatar
            IAvatar(msg.sender).execTransactionFromModule(
                address(sablierStreamParams.sablier),
                0,
                abi.encodeWithSignature(
                    "createWithTimestamps((address,address,uint128,address,bool,bool,(uint40,uint40,uint40),(address,uint256)))",
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
                ),
                Enum.Operation.Call
            );

            // Update KeyValuePairs with the stream ID and Hat ID
            string[] memory keys = new string[](1);
            string[] memory values = new string[](1);
            keys[0] = "hatIdToStreamId";
            values[0] = string(
                abi.encodePacked(
                    Strings.toString(hatId_),
                    ":",
                    Strings.toString(streamId)
                )
            );

            IAvatar(msg.sender).execTransactionFromModule(
                keyValuePairs_,
                0,
                abi.encodeWithSignature(
                    "updateValues(string[],string[])",
                    keys,
                    values
                ),
                Enum.Operation.Call
            );

            unchecked {
                ++i;
            }
        }
    }
}
