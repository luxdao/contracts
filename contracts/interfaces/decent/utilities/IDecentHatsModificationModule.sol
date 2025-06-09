// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {DecentHatsModuleUtils} from "../../../utilities/DecentHatsModuleUtils.sol";

interface IDecentHatsModificationModule {
    // --- State-Changing Functions ---

    function createRoleHats(
        DecentHatsModuleUtils.CreateRoleHatsParams calldata roleHatsParams_
    ) external;
}
