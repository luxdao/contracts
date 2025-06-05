// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IVersion} from "../interfaces/decent/deployables/IVersion.sol";

abstract contract Version is IVersion {
    function version() public view virtual override returns (uint16);
}
