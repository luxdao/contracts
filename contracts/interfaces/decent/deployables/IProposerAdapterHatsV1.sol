// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IProposerAdapterBaseV1} from "./IProposerAdapterBaseV1.sol";

interface IProposerAdapterHatsV1 is IProposerAdapterBaseV1 {
    function initialize(
        address hatsContractAddress_,
        uint256[] calldata whitelistedHats_
    ) external;

    function hatsContract() external view returns (address hatsContract);

    function whitelistedHatIds()
        external
        view
        returns (uint256[] memory whitelistedHatIds);
}
