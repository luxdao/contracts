// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Enum} from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";

interface ISafe {
    function nonce() external view returns (uint256);

    function setGuard(address _guard) external;

    function execTransaction(
        address _to,
        uint256 _value,
        bytes calldata _data,
        Enum.Operation _operation,
        uint256 _safeTxGas,
        uint256 _baseGas,
        uint256 _gasPrice,
        address _gasToken,
        address payable _refundReceiver,
        bytes memory _signatures
    ) external payable returns (bool success);

    function checkSignatures(
        bytes32 _dataHash,
        bytes memory _data,
        bytes memory _signatures
    ) external view;

    function encodeTransactionData(
        address _to,
        uint256 _value,
        bytes calldata _data,
        Enum.Operation _operation,
        uint256 _safeTxGas,
        uint256 _baseGas,
        uint256 _gasPrice,
        address _gasToken,
        address _refundReceiver,
        uint256 _nonce
    ) external view returns (bytes memory);

    function isOwner(address _owner) external view returns (bool);
}
