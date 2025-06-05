// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Enum} from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";

struct Transaction {
    address to;
    uint256 value;
    bytes data;
    Enum.Operation operation;
}
