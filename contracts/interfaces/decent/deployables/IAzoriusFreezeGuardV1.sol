// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IBaseFreezeGuardV1} from "./IBaseFreezeGuardV1.sol";

interface IAzoriusFreezeGuardV1 is IBaseFreezeGuardV1 {
    function initialize(address owner_, address freezeVoting_) external;
}
