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

contract DecentPaymasterV1 is
    IDecentPaymasterV1,
    Version,
    BasePaymasterV1,
    SmartAccountValidationV1,
    UUPSUpgradeable
{
    uint16 private constant VERSION = 1;

    // Mapping: contract address => function selector => validator contract
    mapping(address => mapping(bytes4 => address)) private _functionValidators;

    event FunctionValidatorSet(
        address target,
        bytes4 selector,
        address validator
    );
    event FunctionValidatorRemoved(address target, bytes4 selector);

    error NoValidatorSet(address target, bytes4 selector);
    error ValidationFailed(address target, bytes4 selector);
    error InvalidValidator();

    constructor() {
        _disableInitializers();
    }

    /**
     * Initialize function for the proxy deployment. This standardizes the initialization
     * to better work with ProxyFactory.
     *
     * @param _owner Address that will own the proxy and be able to upgrade it
     * @param _entryPoint The EntryPoint address this paymaster will work with
     */
    function initialize(
        address _owner,
        address _entryPoint,
        address _lightAccountFactory
    ) public initializer {
        __BasePaymasterV1_init(_owner, IEntryPoint(_entryPoint));
        __SmartAccountValidationV1_init(_lightAccountFactory);
    }

    /**
     * @dev Function that should revert when `msg.sender` is not authorized to upgrade the contract.
     * Called by {upgradeTo} and {upgradeToAndCall}.
     *
     * Reverts if the sender is not the owner of the contract.
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal virtual override onlyOwner {
        // Authorization is handled by the onlyOwner modifier
    }

    /**
     * Set validator for a specific function
     * @param target The target contract address
     * @param selector Function selector to validate
     * @param validator Address of the validator contract
     */
    function setFunctionValidator(
        address target,
        bytes4 selector,
        address validator
    ) external onlyOwner {
        if (validator == address(0)) revert InvalidValidator();

        // Verify the validator implements IFunctionValidator interface
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

    /**
     * Remove validator for a specific function
     * @param target The target contract address
     * @param selector Function selector to remove validation for
     */
    function removeFunctionValidator(
        address target,
        bytes4 selector
    ) external onlyOwner {
        _functionValidators[target][selector] = address(0);
        emit FunctionValidatorRemoved(target, selector);
    }

    /*
     * Get a function's validator
     * @param target The contract address
     * @param selector The function selector to check
     * @return address The validator address, or zero if no validator is set
     */
    function getFunctionValidator(
        address target,
        bytes4 selector
    ) public view returns (address) {
        return _functionValidators[target][selector];
    }

    /// @inheritdoc BasePaymasterV1
    function _validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32,
        uint256
    )
        internal
        view
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

    /// @inheritdoc Version
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
}
