// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IFunctionValidator {
    function validateOperation(
        address userOpSender,
        address lightAccountOwner,
        address target,
        bytes calldata callData
    ) external view returns (bool isValid);
}
