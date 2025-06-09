// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IDecentPaymasterV1} from "../../interfaces/decent/deployables/IDecentPaymasterV1.sol";
import {IFunctionValidator} from "../../interfaces/decent/deployables/IFunctionValidator.sol";
import {ISmartAccountValidationV1} from "../../interfaces/decent/deployables/ISmartAccountValidationV1.sol";
import {IVersion} from "../../interfaces/decent/deployables/IVersion.sol";
import {BasePaymasterV1} from "./BasePaymasterV1.sol";
import {SmartAccountValidationV1} from "./SmartAccountValidationV1.sol";
import {Version} from "../Version.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation, IPaymaster} from "@account-abstraction/contracts/interfaces/IPaymaster.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract DecentPaymasterV1 is
    IDecentPaymasterV1,
    Version,
    BasePaymasterV1,
    SmartAccountValidationV1,
    Ownable2StepUpgradeable,
    UUPSUpgradeable,
    ERC165
{
    uint16 private constant VERSION = 1;

    mapping(address target => mapping(bytes4 selector => address validator))
        internal _functionValidators;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address entryPoint_,
        address lightAccountFactory_
    ) external virtual override initializer {
        __BasePaymasterV1_init(owner_, IEntryPoint(entryPoint_));
        __SmartAccountValidationV1_init(lightAccountFactory_);
    }

    function _authorizeUpgrade(
        address newImplementation_
    ) internal virtual override onlyOwner {}

    function setFunctionValidator(
        address target_,
        bytes4 selector_,
        address validator_
    ) external virtual override onlyOwner {
        if (validator_ == address(0)) revert InvalidValidator();

        if (
            !IERC165(validator_).supportsInterface(
                type(IFunctionValidator).interfaceId
            )
        ) {
            revert InvalidValidator();
        }

        _functionValidators[target_][selector_] = validator_;
        emit FunctionValidatorSet(target_, selector_, validator_);
    }

    function removeFunctionValidator(
        address target_,
        bytes4 selector_
    ) external virtual override onlyOwner {
        _functionValidators[target_][selector_] = address(0);
        emit FunctionValidatorRemoved(target_, selector_);
    }

    function getFunctionValidator(
        address target_,
        bytes4 selector_
    ) public view virtual override returns (address) {
        return _functionValidators[target_][selector_];
    }

    function _validatePaymasterUserOp(
        PackedUserOperation calldata userOp_,
        bytes32,
        uint256
    ) internal view virtual override returns (bytes memory, uint256) {
        (
            address lightAccountOwner,
            address target,
            bytes memory innerCallData
        ) = validateUserOp(userOp_);

        bytes4 selector = bytes4(innerCallData);

        // Check if function has a validator
        address validator = _functionValidators[target][selector];
        if (validator == address(0)) {
            revert NoValidatorSet(target, selector);
        }

        // Validate the operation will succeed
        bool isValid = IFunctionValidator(validator).validateOperation(
            userOp_.sender,
            lightAccountOwner,
            target,
            innerCallData
        );

        if (!isValid) {
            revert ValidationFailed(target, selector);
        }

        return (abi.encode(), 0);
    }

    function version() public view virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId_
    ) public view virtual override returns (bool) {
        return
            interfaceId_ == type(IDecentPaymasterV1).interfaceId ||
            interfaceId_ == type(ISmartAccountValidationV1).interfaceId ||
            interfaceId_ == type(IPaymaster).interfaceId ||
            interfaceId_ == type(IVersion).interfaceId ||
            super.supportsInterface(interfaceId_);
    }

    function _transferOwnership(
        address newOwner_
    ) internal virtual override(Ownable2StepUpgradeable, OwnableUpgradeable) {
        Ownable2StepUpgradeable._transferOwnership(newOwner_);
    }

    function transferOwnership(
        address newOwner_
    )
        public
        virtual
        override(Ownable2StepUpgradeable, OwnableUpgradeable)
        onlyOwner
    {
        Ownable2StepUpgradeable.transferOwnership(newOwner_);
    }
}
