// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface ILightAccountValidatorV1 {
    // --- Errors ---

    error InvalidLightAccount();
    error InvalidUserOpCallDataLength();
    error InvalidCallData();
    error InvalidInnerCallDataLength();

    // --- View Functions ---

    function lightAccountFactory()
        external
        view
        returns (address lightAccountFactory);

    function potentialLightAccountResolvedOwner(
        address potentialLightAccount_
    ) external view returns (address potentialLightAccountResolvedOwner);
}
