// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IGuard} from "@gnosis-guild/zodiac/contracts/interfaces/IGuard.sol";

interface IBaseFreezeGuardV1 is IGuard {
    error DAOFrozen();

    function freezeVoting() external view returns (address freezeVoting);
}
