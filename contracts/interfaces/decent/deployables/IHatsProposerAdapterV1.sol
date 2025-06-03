// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IProposerAdapterV1} from "./IProposerAdapterV1.sol";

interface IHatsProposerAdapterV1 is IProposerAdapterV1 {
    error MissingHatsContract();
    error NoHatsWhitelisted();
    error HatAlreadyWhitelisted();

    function initialize(
        address hatsContractAddress,
        uint256[] memory whitelistedHats
    ) external;

    function hatsContract() external view returns (address);

    function whitelistedHatIds() external view returns (uint256[] memory);
}
