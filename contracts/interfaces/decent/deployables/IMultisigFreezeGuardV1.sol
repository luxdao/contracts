// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Enum} from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";
import {IFreezeGuardBaseV1} from "./IFreezeGuardBaseV1.sol";

interface IMultisigFreezeGuardV1 is IFreezeGuardBaseV1 {
    event TransactionTimelocked(
        address indexed timelocker,
        bytes32 indexed transactionHash,
        bytes indexed signatures
    );
    event TimelockPeriodUpdated(uint32 timelockPeriod);
    event ExecutionPeriodUpdated(uint32 executionPeriod);

    error AlreadyTimelocked();
    error NotTimelocked();
    error Timelocked();
    error Expired();

    function initialize(
        uint32 timelockPeriod,
        uint32 executionPeriod,
        address owner,
        address freezeVoting,
        address childGnosisSafe
    ) external;

    function timelockPeriod() external view returns (uint32);

    function executionPeriod() external view returns (uint32);

    function childGnosisSafe() external view returns (address);

    function timelockTransaction(
        address _to,
        uint256 _value,
        bytes memory _data,
        Enum.Operation _operation,
        uint256 _safeTxGas,
        uint256 _baseGas,
        uint256 _gasPrice,
        address _gasToken,
        address payable _refundReceiver,
        bytes memory _signatures,
        uint256 _nonce
    ) external;

    function updateTimelockPeriod(uint32 _timelockPeriod) external;

    function updateExecutionPeriod(uint32 _executionPeriod) external;

    function getTransactionTimelocked(
        bytes32 _signaturesHash
    ) external view returns (uint48);
}
