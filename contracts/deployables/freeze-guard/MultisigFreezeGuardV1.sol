// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.28;

import {BaseFreezeGuardV1} from "./BaseFreezeGuardV1.sol";
import {Version} from "../Version.sol";
import {IMultisigFreezeGuardV1} from "../../interfaces/decent/deployables/IMultisigFreezeGuardV1.sol";
import {IBaseFreezeVotingV1} from "../../interfaces/decent/deployables/IBaseFreezeVotingV1.sol";
import {ISafe} from "../../interfaces/safe/ISafe.sol";
import {Enum} from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/**
 * Implementation of [IMultisigFreezeGuard](./interfaces/IMultisigFreezeGuard.md).
 */
contract MultisigFreezeGuardV1 is
    IMultisigFreezeGuardV1,
    Version,
    BaseFreezeGuardV1
{
    uint16 private constant VERSION = 1;

    /** Timelock period (in blocks). */
    uint32 public timelockPeriod;

    /** Execution period (in blocks). */
    uint32 public executionPeriod;

    /**
     * Reference to the [IBaseFreezeVoting](./interfaces/IBaseFreezeVoting.md)
     * implementation that determines whether the Safe is frozen.
     */
    IBaseFreezeVotingV1 public freezeVoting;

    /** Reference to the Safe that can be frozen. */
    ISafe public childGnosisSafe;

    /** Mapping of signatures hash to the block during which it was timelocked. */
    mapping(bytes32 => uint32) internal transactionTimelockedBlock;

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

    /**
     * Initialize function, will be triggered when a new instance is deployed.
     *
     * @param _timelockPeriod The timelock period in blocks
     * @param _executionPeriod The execution period in blocks
     * @param _owner The owner of the contract
     * @param _freezeVoting The address of the freeze voting contract
     * @param _childGnosisSafe The address of the child Gnosis Safe
     */
    function initialize(
        uint32 _timelockPeriod,
        uint32 _executionPeriod,
        address _owner,
        address _freezeVoting,
        address _childGnosisSafe
    ) public initializer {
        super.initialize(_owner);
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

    /**
     * @dev Function that authorizes an upgrade. Only the owner can upgrade the implementation.
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal virtual override onlyOwner {}

    /** @inheritdoc IMultisigFreezeGuardV1*/
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

        if (transactionTimelockedBlock[signaturesHash] != 0)
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

        // if signatures are not valid, this will revert
        childGnosisSafe.checkSignatures(
            transactionHash,
            transactionHashData,
            signatures
        );

        transactionTimelockedBlock[signaturesHash] = uint32(block.number);

        emit TransactionTimelocked(msg.sender, transactionHash, signatures);
    }

    /** @inheritdoc IMultisigFreezeGuardV1*/
    function updateTimelockPeriod(uint32 _timelockPeriod) external onlyOwner {
        _updateTimelockPeriod(_timelockPeriod);
    }

    /** @inheritdoc IMultisigFreezeGuardV1*/
    function updateExecutionPeriod(uint32 _executionPeriod) external onlyOwner {
        _updateExecutionPeriod(_executionPeriod);
    }

    /**
     * Called by the Safe to check if the transaction is able to be executed and reverts
     * if the guard conditions are not met.
     */
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

        if (transactionTimelockedBlock[signaturesHash] == 0)
            revert NotTimelocked();

        if (
            block.number <
            transactionTimelockedBlock[signaturesHash] + timelockPeriod
        ) revert Timelocked();

        if (
            block.number >
            transactionTimelockedBlock[signaturesHash] +
                timelockPeriod +
                executionPeriod
        ) revert Expired();

        if (freezeVoting.isFrozen()) revert DAOFrozen();
    }

    /**
     * A callback performed after a transaction is executed on the Safe. This is a required
     * function of the `BaseGuard` and `IGuard` interfaces that we do not make use of.
     */
    function checkAfterExecution(
        bytes32,
        bool
    ) external view override(BaseFreezeGuardV1) {
        // not implementated
    }

    /** @inheritdoc IMultisigFreezeGuardV1*/
    function getTransactionTimelockedBlock(
        bytes32 _signaturesHash
    ) public view returns (uint32) {
        return transactionTimelockedBlock[_signaturesHash];
    }

    /** Internal implementation of `updateTimelockPeriod` */
    function _updateTimelockPeriod(uint32 _timelockPeriod) internal {
        timelockPeriod = _timelockPeriod;
        emit TimelockPeriodUpdated(_timelockPeriod);
    }

    /** Internal implementation of `updateExecutionPeriod` */
    function _updateExecutionPeriod(uint32 _executionPeriod) internal {
        executionPeriod = _executionPeriod;
        emit ExecutionPeriodUpdated(_executionPeriod);
    }

    /// @inheritdoc Version
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
