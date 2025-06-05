// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Transaction} from "../Module.sol";

interface IFractalModuleV1 {
    error TxFailed();

    function initialize(address owner, address avatar, address target) external;

    function execTx(Transaction calldata _transaction) external;
}
