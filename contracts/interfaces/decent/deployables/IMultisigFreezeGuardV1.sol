// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Enum} from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";
import {IBaseFreezeGuardV1} from "./IBaseFreezeGuardV1.sol";

interface IMultisigFreezeGuardV1 is IBaseFreezeGuardV1 {
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
        uint32 timelockPeriod_,
        uint32 executionPeriod_,
        address owner_,
        address freezeVoting_,
        address childGnosisSafe_
    ) external;

    function timelockPeriod() external view returns (uint32 timelockPeriod);

    function executionPeriod() external view returns (uint32 executionPeriod);

    function childGnosisSafe() external view returns (address childGnosisSafe);

    function timelockTransaction(
        address to_,
        uint256 value_,
        bytes memory data_,
        Enum.Operation operation_,
        uint256 safeTxGas_,
        uint256 baseGas_,
        uint256 gasPrice_,
        address gasToken_,
        address payable refundReceiver_,
        bytes calldata signatures_,
        uint256 nonce_
    ) external;

    function updateTimelockPeriod(uint32 timelockPeriod_) external;

    function updateExecutionPeriod(uint32 executionPeriod_) external;

    function getTransactionTimelocked(
        bytes32 signaturesHash_
    ) external view returns (uint48 timelockedTimestamp);
}
