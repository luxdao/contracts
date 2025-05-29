// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {BaseFreezeGuardV1} from "./BaseFreezeGuardV1.sol";
import {Version} from "../Version.sol";
import {IMultisigFreezeGuardV1} from "../../interfaces/decent/deployables/IMultisigFreezeGuardV1.sol";
import {IBaseFreezeVotingV1} from "../../interfaces/decent/deployables/IBaseFreezeVotingV1.sol";
import {ISafe} from "../../interfaces/safe/ISafe.sol";
import {Enum} from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";

contract MultisigFreezeGuardV1 is
    IMultisigFreezeGuardV1,
    Version,
    BaseFreezeGuardV1
{
    uint16 private constant VERSION = 1;

    uint32 public timelockPeriod;

    uint32 public executionPeriod;

    IBaseFreezeVotingV1 public freezeVoting;

    ISafe public childGnosisSafe;

    mapping(bytes32 => uint48) internal transactionTimelocked;

    event MultisigFreezeGuardSetup(
        address creator,
        address indexed owner,
        address indexed freezeVoting,
        address indexed childGnosisSafe
    );
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
    error DAOFrozen();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        uint32 _timelockPeriod,
        uint32 _executionPeriod,
        address _owner,
        address _freezeVoting,
        address _childGnosisSafe
    ) public initializer {
        __BaseFreezeGuardV1_init(_owner);
        _updateTimelockPeriod(_timelockPeriod);
        _updateExecutionPeriod(_executionPeriod);
        freezeVoting = IBaseFreezeVotingV1(_freezeVoting);
        childGnosisSafe = ISafe(_childGnosisSafe);

        emit MultisigFreezeGuardSetup(
            msg.sender,
            _owner,
            _freezeVoting,
            _childGnosisSafe
        );
    }

    function timelockTransaction(
        address to,
        uint256 value,
        bytes memory data,
        Enum.Operation operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures,
        uint256 nonce
    ) external {
        bytes32 signaturesHash = keccak256(signatures);

        if (transactionTimelocked[signaturesHash] != 0)
            revert AlreadyTimelocked();

        bytes memory transactionHashData = childGnosisSafe
            .encodeTransactionData(
                to,
                value,
                data,
                operation,
                safeTxGas,
                baseGas,
                gasPrice,
                gasToken,
                refundReceiver,
                nonce
            );

        bytes32 transactionHash = keccak256(transactionHashData);

        childGnosisSafe.checkSignatures(
            transactionHash,
            transactionHashData,
            signatures
        );

        transactionTimelocked[signaturesHash] = uint48(block.timestamp);

        emit TransactionTimelocked(msg.sender, transactionHash, signatures);
    }

    function updateTimelockPeriod(uint32 _timelockPeriod) external onlyOwner {
        _updateTimelockPeriod(_timelockPeriod);
    }

    function updateExecutionPeriod(uint32 _executionPeriod) external onlyOwner {
        _updateExecutionPeriod(_executionPeriod);
    }

    function checkTransaction(
        address,
        uint256,
        bytes memory,
        Enum.Operation,
        uint256,
        uint256,
        uint256,
        address,
        address payable,
        bytes memory signatures,
        address
    ) external view override(BaseFreezeGuardV1) {
        bytes32 signaturesHash = keccak256(signatures);

        if (transactionTimelocked[signaturesHash] == 0) revert NotTimelocked();

        if (
            block.timestamp <
            transactionTimelocked[signaturesHash] + timelockPeriod
        ) revert Timelocked();

        if (
            block.timestamp >
            transactionTimelocked[signaturesHash] +
                timelockPeriod +
                executionPeriod
        ) revert Expired();

        if (freezeVoting.isFrozen()) revert DAOFrozen();
    }

    function checkAfterExecution(
        bytes32,
        bool
    ) external view override(BaseFreezeGuardV1) {}

    function getTransactionTimelocked(
        bytes32 _signaturesHash
    ) public view returns (uint48) {
        return transactionTimelocked[_signaturesHash];
    }

    function _updateTimelockPeriod(uint32 _timelockPeriod) internal {
        timelockPeriod = _timelockPeriod;
        emit TimelockPeriodUpdated(_timelockPeriod);
    }

    function _updateExecutionPeriod(uint32 _executionPeriod) internal {
        executionPeriod = _executionPeriod;
        emit ExecutionPeriodUpdated(_executionPeriod);
    }

    function getVersion() public view virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(BaseFreezeGuardV1, Version) returns (bool) {
        return
            interfaceId == type(IMultisigFreezeGuardV1).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
