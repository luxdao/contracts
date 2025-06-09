// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IProposerAdapterBaseV1 {
    // --- View Functions ---

    function isProposer(
        address address_,
        bytes calldata data_
    ) external view returns (bool isProposer);
}
