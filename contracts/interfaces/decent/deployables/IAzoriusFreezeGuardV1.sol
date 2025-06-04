// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IFreezeGuardBaseV1} from "./IFreezeGuardBaseV1.sol";

interface IAzoriusFreezeGuardV1 is IFreezeGuardBaseV1 {
    function initialize(address owner_, address freezeVoting_) external;
}
