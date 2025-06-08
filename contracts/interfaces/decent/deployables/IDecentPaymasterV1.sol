// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IDecentPaymasterV1 {
    // --- Errors ---

    error NoValidatorSet(address target, bytes4 selector);
    error ValidationFailed(address target, bytes4 selector);
    error InvalidValidator();

    // --- Events ---

    event FunctionValidatorSet(
        address target,
        bytes4 selector,
        address validator
    );
    event FunctionValidatorRemoved(address target, bytes4 selector);

    // --- Initializer Functions ---

    function initialize(
        address owner_,
        address entryPoint_,
        address lightAccountFactory_
    ) external;

    // --- View Functions ---

    function getFunctionValidator(
        address contractAddress_,
        bytes4 selector_
    ) external view returns (address functionValidator);

    // --- State-Changing Functions ---

    function setFunctionValidator(
        address contractAddress_,
        bytes4 selector_,
        address validator_
    ) external;

    function removeFunctionValidator(
        address contractAddress_,
        bytes4 selector_
    ) external;
}
