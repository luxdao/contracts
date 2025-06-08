// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface ISmartAccountValidationV1 {
    // --- Errors ---

    error InvalidSmartAccount();
    error InvalidUserOpCallDataLength();
    error InvalidCallData();
    error InvalidInnerCallDataLength();

    // --- View Functions ---

    function lightAccountFactory()
        external
        view
        returns (address lightAccountFactory);
}
