// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IGuard} from "@gnosis-guild/zodiac/contracts/interfaces/IGuard.sol";

interface IFreezeGuardBaseV1 is IGuard {
    // --- Errors ---

    error DAOFrozen();

    // --- View Functions ---

    function freezeVoting() external view returns (address freezeVoting);
}
