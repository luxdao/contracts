// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Enum} from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

interface IFractalModuleV1 {
    function execTx(bytes memory execTxData) external;
}
