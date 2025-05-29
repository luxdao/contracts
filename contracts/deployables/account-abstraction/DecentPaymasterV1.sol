// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IDecentPaymasterV1} from "../../interfaces/decent/deployables/IDecentPaymasterV1.sol";
import {IFunctionValidator} from "../../interfaces/decent/deployables/IFunctionValidator.sol";
import {BasePaymasterV1} from "./BasePaymasterV1.sol";
import {SmartAccountValidationV1} from "./SmartAccountValidationV1.sol";
import {Version} from "../Version.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation, IPaymaster} from "@account-abstraction/contracts/interfaces/IPaymaster.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract DecentPaymasterV1 is
    IDecentPaymasterV1,
    Version,
    BasePaymasterV1,
    SmartAccountValidationV1,
    Ownable2StepUpgradeable,
    UUPSUpgradeable
{
    uint16 private constant VERSION = 1;

    mapping(address => mapping(bytes4 => address)) internal _functionValidators;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address entryPoint_,
        address lightAccountFactory_
    ) public virtual override initializer {
        __BasePaymasterV1_init(owner_, IEntryPoint(entryPoint_));
        __SmartAccountValidationV1_init(lightAccountFactory_);
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal virtual override onlyOwner {}

    function setFunctionValidator(
        address target,
        bytes4 selector,
        address validator
    ) external virtual override onlyOwner {
        if (validator == address(0)) revert InvalidValidator();

        if (
            !IFunctionValidator(validator).supportsInterface(
                type(IFunctionValidator).interfaceId
            )
        ) {
            revert InvalidValidator();
        }

        _functionValidators[target][selector] = validator;
        emit FunctionValidatorSet(target, selector, validator);
    }

    function removeFunctionValidator(
        address target,
        bytes4 selector
    ) external virtual override onlyOwner {
        _functionValidators[target][selector] = address(0);
        emit FunctionValidatorRemoved(target, selector);
    }

    function getFunctionValidator(
        address target,
        bytes4 selector
    ) public view virtual override returns (address) {
        return _functionValidators[target][selector];
    }

    function _validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32,
        uint256
    )
        internal
        view
        virtual
        override
        returns (bytes memory context, uint256 validationData)
    {
        (
            address lightAccountOwner,
            address target,
            bytes4 selector
        ) = validateUserOp(userOp);

        // Check if function has a validator
        address validator = _functionValidators[target][selector];
        if (validator == address(0)) {
            revert NoValidatorSet(target, selector);
        }

        // Extract the inner calldata from the UserOp
        (, , bytes memory innerCallData) = abi.decode(
            userOp.callData[4:],
            (address, uint256, bytes)
        );

        // Validate the operation will succeed
        bool isValid = IFunctionValidator(validator).validateOperation(
            userOp.sender,
            lightAccountOwner,
            target,
            innerCallData
        );

        if (!isValid) {
            revert ValidationFailed(target, selector);
        }

        return (abi.encode(), 0);
    }

    function getVersion() public view virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(IDecentPaymasterV1).interfaceId ||
            interfaceId == type(IPaymaster).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    function _transferOwnership(
        address newOwner
    ) internal virtual override(Ownable2StepUpgradeable, OwnableUpgradeable) {
        Ownable2StepUpgradeable._transferOwnership(newOwner);
    }

    function transferOwnership(
        address newOwner
    )
        public
        virtual
        override(Ownable2StepUpgradeable, OwnableUpgradeable)
        onlyOwner
    {
        Ownable2StepUpgradeable.transferOwnership(newOwner);
    }
}
