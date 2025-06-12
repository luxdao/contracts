// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IZKMEVerify} from "../interfaces/decent/deployables/IZKMEVerify.sol";

contract MockZKMEVerify is IZKMEVerify {

    bool public approve;

    constructor() {}

    function hasApproved(
        address,
        address
    ) external view returns (bool) {
        return approve;
    }

    function setApproved(bool approved_) external {
        approve = approved_;
    }
}