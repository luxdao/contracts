// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IVersion} from "../../interfaces/decent/deployables/IVersion.sol";
import {IFreezeGuardMultisigV1} from "../../interfaces/decent/deployables/IFreezeGuardMultisigV1.sol";
import {IFreezeGuardBaseV1} from "../../interfaces/decent/deployables/IFreezeGuardBaseV1.sol";
import {IBaseFreezeVotingV1} from "../../interfaces/decent/deployables/IBaseFreezeVotingV1.sol";
import {ISafe} from "../../interfaces/safe/ISafe.sol";
import {Enum} from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";
import {IGuard} from "@gnosis-guild/zodiac/contracts/interfaces/IGuard.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

contract FreezeGuardMultisigV1 is
    IFreezeGuardMultisigV1,
    IVersion,
    Ownable2StepUpgradeable,
    UUPSUpgradeable,
    ERC165
{
    uint16 private constant VERSION = 1;

    IBaseFreezeVotingV1 internal _freezeVoting;
    uint32 internal _timelockPeriod;
    uint32 internal _executionPeriod;
    ISafe internal _childGnosisSafe;
    mapping(bytes32 signaturesHash => uint48 timelockedTimestamp)
        internal transactionTimelocked;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        uint32 timelockPeriod_,
        uint32 executionPeriod_,
        address owner_,
        address freezeVoting_,
        address childGnosisSafe_
    ) public virtual override initializer {
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        _updateTimelockPeriod(timelockPeriod_);
        _updateExecutionPeriod(executionPeriod_);
        _freezeVoting = IBaseFreezeVotingV1(freezeVoting_);
        _childGnosisSafe = ISafe(childGnosisSafe_);
    }

    function _authorizeUpgrade(
        address newImplementation_
    ) internal virtual override onlyOwner {}

    function timelockPeriod() external view virtual override returns (uint32) {
        return _timelockPeriod;
    }

    function executionPeriod() external view virtual override returns (uint32) {
        return _executionPeriod;
    }

    function freezeVoting() external view virtual override returns (address) {
        return address(_freezeVoting);
    }

    function childGnosisSafe()
        external
        view
        virtual
        override
        returns (address)
    {
        return address(_childGnosisSafe);
    }

    function timelockTransaction(
        address to_,
        uint256 value_,
        bytes memory data_,
        Enum.Operation operation,
        uint256 safeTxGas_,
        uint256 baseGas_,
        uint256 gasPrice_,
        address gasToken_,
        address payable refundReceiver_,
        bytes calldata signatures_,
        uint256 nonce_
    ) external virtual override {
        bytes32 signaturesHash = keccak256(signatures_);

        if (transactionTimelocked[signaturesHash] != 0)
            revert AlreadyTimelocked();

        bytes memory transactionHashData = _childGnosisSafe
            .encodeTransactionData(
                to_,
                value_,
                data_,
                operation,
                safeTxGas_,
                baseGas_,
                gasPrice_,
                gasToken_,
                refundReceiver_,
                nonce_
            );

        bytes32 transactionHash = keccak256(transactionHashData);

        _childGnosisSafe.checkSignatures(
            transactionHash,
            transactionHashData,
            signatures_
        );

        transactionTimelocked[signaturesHash] = uint48(block.timestamp);

        emit TransactionTimelocked(msg.sender, transactionHash, signatures_);
    }

    function updateTimelockPeriod(
        uint32 timelockPeriod_
    ) external virtual override onlyOwner {
        _updateTimelockPeriod(timelockPeriod_);
    }

    function updateExecutionPeriod(
        uint32 executionPeriod_
    ) external virtual override onlyOwner {
        _updateExecutionPeriod(executionPeriod_);
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
        bytes memory signatures_,
        address
    ) external view virtual override {
        bytes32 signaturesHash = keccak256(signatures_);

        if (transactionTimelocked[signaturesHash] == 0) revert NotTimelocked();

        if (
            block.timestamp <
            transactionTimelocked[signaturesHash] + _timelockPeriod
        ) revert Timelocked();

        if (
            block.timestamp >
            transactionTimelocked[signaturesHash] +
                _timelockPeriod +
                _executionPeriod
        ) revert Expired();

        if (_freezeVoting.isFrozen()) revert DAOFrozen();
    }

    function checkAfterExecution(
        bytes32,
        bool
    ) external view virtual override {}

    function getTransactionTimelocked(
        bytes32 signaturesHash_
    ) public view virtual override returns (uint48) {
        return transactionTimelocked[signaturesHash_];
    }

    function _updateTimelockPeriod(uint32 timelockPeriod_) internal virtual {
        _timelockPeriod = timelockPeriod_;
        emit TimelockPeriodUpdated(timelockPeriod_);
    }

    function _updateExecutionPeriod(uint32 executionPeriod_) internal virtual {
        _executionPeriod = executionPeriod_;
        emit ExecutionPeriodUpdated(executionPeriod_);
    }

    function version() external view virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId_
    ) public view virtual override returns (bool) {
        return
            interfaceId_ == type(IFreezeGuardMultisigV1).interfaceId ||
            interfaceId_ == type(IFreezeGuardBaseV1).interfaceId ||
            interfaceId_ == type(IGuard).interfaceId ||
            interfaceId_ == type(IVersion).interfaceId ||
            super.supportsInterface(interfaceId_);
    }
}
