// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IDecentPaymasterV1 {
    event FunctionValidatorSet(
        address target,
        bytes4 selector,
        address validator
    );
    event FunctionValidatorRemoved(address target, bytes4 selector);

    error NoValidatorSet(address target, bytes4 selector);
    error ValidationFailed(address target, bytes4 selector);
    error InvalidValidator();

    function initialize(
        address _owner,
        address _entryPoint,
        address _lightAccountFactory
    ) external;

    function setFunctionValidator(
        address contractAddress,
        bytes4 selector,
        address validator
    ) external;

    function removeFunctionValidator(
        address contractAddress,
        bytes4 selector
    ) external;

    function getFunctionValidator(
        address contractAddress,
        bytes4 selector
    ) external view returns (address);
}
