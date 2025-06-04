// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IProposerAdapterBaseV1 {
    function isProposer(
        address _address,
        bytes memory _data
    ) external view returns (bool);
}
