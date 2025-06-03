// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface ISmartAccountValidationV1 {
    error InvalidSmartAccount();
    error InvalidUserOpCallDataLength();
    error InvalidCallData();
    error InvalidInnerCallDataLength();

    function lightAccountFactory() external view returns (address);
}
