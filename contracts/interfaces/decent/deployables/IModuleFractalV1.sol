// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Transaction} from "../Module.sol";

interface IModuleFractalV1 {
    // --- Errors ---

    error TxFailed();

    // --- Initializer Functions ---

    function initialize(
        address owner_,
        address avatar_,
        address target_
    ) external;

    // --- State-Changing Functions ---

    function execTx(Transaction calldata transaction_) external;
}
