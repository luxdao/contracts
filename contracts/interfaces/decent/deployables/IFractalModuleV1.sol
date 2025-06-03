// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Enum} from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";

interface IFractalModuleV1 {
    error TxFailed();

    function initialize(address owner, address avatar, address target) external;

    function execTx(
        address _target,
        uint256 _value,
        bytes memory _data,
        Enum.Operation _operation
    ) external;
}
