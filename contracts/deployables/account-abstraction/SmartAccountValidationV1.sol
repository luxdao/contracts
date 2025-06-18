// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {ILightAccount} from "../../interfaces/light-account/ILightAccount.sol";
import {ILightAccountFactory} from "../../interfaces/light-account/ILightAccountFactory.sol";
import {ISmartAccountValidationV1} from "../../interfaces/decent/deployables/ISmartAccountValidationV1.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/IPaymaster.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

abstract contract SmartAccountValidationV1 is
    ISmartAccountValidationV1,
    Initializable
{
    // ======================================================================
    // STATE VARIABLES
    // ======================================================================

    /// @custom:storage-location erc7201:Decent.SmartAccountValidation.main
    struct SmartAccountValidationStorage {
        ILightAccountFactory lightAccountFactory;
    }

    // EIP-7201: keccak256(abi.encode(uint256(keccak256("Decent.SmartAccountValidation.main")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SMART_ACCOUNT_VALIDATION_STORAGE_LOCATION =
        0x568d143de11f3fce0a7f79d63a29e7883a7d0c6cd1aea20082c2ea951d7b4e00;

    function _getSmartAccountValidationStorage()
        internal
        pure
        returns (SmartAccountValidationStorage storage $)
    {
        assembly {
            $.slot := SMART_ACCOUNT_VALIDATION_STORAGE_LOCATION
        }
    }

    // ======================================================================
    // CONSTRUCTOR & INITIALIZERS
    // ======================================================================

    constructor() {
        _disableInitializers();
    }

    function __SmartAccountValidationV1_init(
        address lightAccountFactory_
    ) internal onlyInitializing {
        SmartAccountValidationStorage
            storage $ = _getSmartAccountValidationStorage();
        $.lightAccountFactory = ILightAccountFactory(lightAccountFactory_);
    }

    // ======================================================================
    // ISmartAccountValidationV1
    // ======================================================================

    // --- View Functions ---

    function lightAccountFactory()
        public
        view
        virtual
        override
        returns (address)
    {
        SmartAccountValidationStorage
            storage $ = _getSmartAccountValidationStorage();
        return address($.lightAccountFactory);
    }

    // ======================================================================
    // INTERNAL HELPERS
    // ======================================================================

    function _validateSmartAccount(
        address smartAccount_
    ) internal view virtual returns (bool, address) {
        // First check if the address has code (is a contract)
        uint256 size;
        assembly {
            size := extcodesize(smartAccount_)
        }

        // If it's an EOA (no code), it's not a `LightAccount`
        if (size == 0) {
            return (false, address(0));
        }

        try ILightAccount(smartAccount_).owner() returns (
            address lightAccountOwner_
        ) {
            SmartAccountValidationStorage
                storage $ = _getSmartAccountValidationStorage();

            // Regenerate the expected light account address
            address lightAccountAddress = $.lightAccountFactory.getAddress(
                lightAccountOwner_,
                0 // we assume that Decent App is only creating one account per user
            );

            // If the given `smartAccount` address is the same as the derived
            // `lightAccountAddress`, then we know that the `smartAccount`
            // was created by the `LightAccountFactory` and therefore can be trusted.
            return (lightAccountAddress == smartAccount_, lightAccountOwner_);
        } catch {
            // `smartAccount` does not implement `owner()`
            // so it's definitely not a `LightAccount`
            return (false, address(0));
        }
    }

    function _validateUserOp(
        PackedUserOperation calldata userOp_
    ) internal view virtual returns (address, address, bytes memory) {
        (bool isValid, address lightAccountOwner) = _validateSmartAccount(
            userOp_.sender
        );
        if (!isValid) {
            revert InvalidSmartAccount();
        }

        // If we're here, we've confirmed that the sender is an actual instance of a LightAccount,
        // and so therefore its "execute" function behaves as expected.
        //
        // This prevents a potential exploit where a user crafts a malicious UserOp
        // which targets a contract that is expected to be a LightAccount, but is not,
        // and allows the implementation of that contract's "execute" function to perform
        // any arbitrary logic (aka logic which does not execute the whitelisted function
        // encoded in the UserOp).

        // Validate that we have at least 4 bytes for the selector
        if (userOp_.callData.length < 4) {
            revert InvalidUserOpCallDataLength();
        }

        // Extract and validate the LightAccount's "execute" function selector
        // 0xb61d27f6 = bytes4(keccak256("execute(address,uint256,bytes)"))
        if (bytes4(userOp_.callData) != 0xb61d27f6) {
            revert InvalidCallData();
        }

        // Decode the "execute" function parameters
        (address target, , bytes memory innerCallData) = abi.decode(
            userOp_.callData[4:],
            (address, uint256, bytes)
        );

        // Extract the actual function selector from the innerCallData
        if (innerCallData.length < 4) {
            revert InvalidInnerCallDataLength();
        }

        return (lightAccountOwner, target, innerCallData);
    }
}
