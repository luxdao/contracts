// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IProposerAdapterV1 {
    function isProposer(
        address _address,
        bytes memory _data
    ) external view returns (bool);
}
