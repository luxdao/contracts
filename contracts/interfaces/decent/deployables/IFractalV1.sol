// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Transaction} from "../Module.sol";

interface IFractalV1 {
    error TxFailed();

    function initialize(
        address owner_,
        address avatar_,
        address target_
    ) external;

    function execTx(Transaction calldata transaction_) external;
}
