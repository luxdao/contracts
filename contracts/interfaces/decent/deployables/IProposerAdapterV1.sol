// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IProposerAdapterV1 {
    function isProposer(
        address address_,
        bytes calldata data_
    ) external view returns (bool isProposer);
}
