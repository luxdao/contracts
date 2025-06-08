// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IStrategyV1} from "../../interfaces/decent/deployables/IStrategyV1.sol";
import {IAzoriusV1} from "../../interfaces/decent/deployables/IAzoriusV1.sol";
import {Transaction} from "../../interfaces/decent/Module.sol";
import {IVersion} from "../../interfaces/decent/deployables/IVersion.sol";
import {Version} from "../Version.sol";
import {GuardableModule} from "@gnosis-guild/zodiac/contracts/core/GuardableModule.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

contract AzoriusV1 is
    IAzoriusV1,
    GuardableModule,
    Ownable2StepUpgradeable,
    Version,
    UUPSUpgradeable,
    ERC165
{
    uint16 private constant VERSION = 1;
    /**
     * ```
     * keccak256(
     *      "EIP712Domain(uint256 chainId,address verifyingContract)"
     * );
     * ```
     *
     * A unique hash intended to prevent signature collisions.
     *
     * See https://eips.ethereum.org/EIPS/eip-712.
     */
    bytes32 public constant DOMAIN_SEPARATOR_TYPEHASH =
        0x47e79534a245952e8b16893a336b85a3d9ea9fa8c573f3d803afb92a79469218;

    /**
     * ```
     * keccak256(
     *      "Transaction(address to,uint256 value,bytes data,uint8 operation,uint256 nonce)"
     * );
     * ```
     *
     * See https://eips.ethereum.org/EIPS/eip-712.
     */
    bytes32 public constant TRANSACTION_TYPEHASH =
        0x72e9670a7ee00f5fbf1049b8c38e3f22fab7e9b85029e85cf9412f17fdd5c2ad;

    uint32 internal _totalProposalCount;
    uint32 internal _timelockPeriod;
    uint32 internal _executionPeriod;
    mapping(uint32 proposalId => Proposal proposal) internal _proposals;
    IStrategyV1 internal _strategy;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address avatar_,
        address target_,
        address strategy_,
        uint32 timelockPeriod_,
        uint32 executionPeriod_
    ) public virtual override initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();

        setAvatar(avatar_);
        setTarget(target_);

        _updateStrategy(strategy_);
        _updateTimelockPeriod(timelockPeriod_);
        _updateExecutionPeriod(executionPeriod_);

        _transferOwnership(owner_);
    }

    function setUp(
        bytes memory initializeParams
    ) public virtual override initializer {
        (
            address owner_,
            address avatar_,
            address target_,
            address strategy_,
            uint32 timelockPeriod_,
            uint32 executionPeriod_
        ) = abi.decode(
                initializeParams,
                (address, address, address, address, uint32, uint32)
            );
        initialize(
            owner_,
            avatar_,
            target_,
            strategy_,
            timelockPeriod_,
            executionPeriod_
        );
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal virtual override onlyOwner {}

    function totalProposalCount()
        external
        view
        virtual
        override
        returns (uint32)
    {
        return _totalProposalCount;
    }

    function timelockPeriod() external view virtual override returns (uint32) {
        return _timelockPeriod;
    }

    function executionPeriod() external view virtual override returns (uint32) {
        return _executionPeriod;
    }

    function proposals(
        uint32 _proposalId
    ) external view virtual override returns (Proposal memory) {
        return _proposals[_proposalId];
    }

    function strategy() external view virtual override returns (address) {
        return address(_strategy);
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

    function updateStrategy(
        address strategy_
    ) external virtual override onlyOwner {
        _updateStrategy(strategy_);
    }

    function submitProposal(
        Transaction[] calldata _transactions,
        string calldata _metadata,
        address _proposerAdapter,
        bytes calldata _proposerAdapterData,
        bytes calldata _proposalInitializerData
    ) external virtual override {
        if (
            !_strategy.isProposer(
                msg.sender,
                _proposerAdapter,
                _proposerAdapterData
            )
        ) revert InvalidProposer();

        bytes32[] memory txHashes = new bytes32[](_transactions.length);
        uint256 transactionsLength = _transactions.length;
        for (uint256 i; i < transactionsLength; ) {
            txHashes[i] = getTxHash(_transactions[i]);
            unchecked {
                ++i;
            }
        }

        _proposals[_totalProposalCount].strategy = address(_strategy);
        _proposals[_totalProposalCount].txHashes = txHashes;
        _proposals[_totalProposalCount].timelockPeriod = _timelockPeriod;
        _proposals[_totalProposalCount].executionPeriod = _executionPeriod;

        _strategy.initializeProposal(
            _totalProposalCount,
            txHashes,
            _proposalInitializerData
        );

        emit ProposalCreated(
            address(_strategy),
            _totalProposalCount,
            msg.sender,
            _transactions,
            _metadata
        );

        _totalProposalCount++;
    }

    function executeProposal(
        uint32 _proposalId,
        Transaction[] calldata _transactions
    ) external virtual override {
        if (_transactions.length == 0) revert InvalidTxs();
        if (
            _proposals[_proposalId].executionCounter + _transactions.length >
            _proposals[_proposalId].txHashes.length
        ) revert InvalidTxs();
        uint256 transactionsLength = _transactions.length;
        bytes32[] memory txHashes = new bytes32[](transactionsLength);
        for (uint256 i; i < transactionsLength; ) {
            txHashes[i] = _executeProposalTx(_proposalId, _transactions[i]);
            unchecked {
                ++i;
            }
        }
        emit ProposalExecuted(_proposalId, txHashes);
    }

    function getProposalTxHash(
        uint32 _proposalId,
        uint32 _txIndex
    ) external view virtual override returns (bytes32) {
        return _proposals[_proposalId].txHashes[_txIndex];
    }

    function getProposalTxHashes(
        uint32 _proposalId
    ) external view virtual override returns (bytes32[] memory) {
        return _proposals[_proposalId].txHashes;
    }

    function getProposal(
        uint32 _proposalId
    )
        external
        view
        virtual
        override
        returns (
            address strategy_,
            bytes32[] memory txHashes_,
            uint32 timelockPeriod_,
            uint32 executionPeriod_,
            uint32 executionCounter_
        )
    {
        Proposal memory _proposal = _proposals[_proposalId];
        strategy_ = _proposal.strategy;
        txHashes_ = _proposal.txHashes;
        timelockPeriod_ = _proposal.timelockPeriod;
        executionPeriod_ = _proposal.executionPeriod;
        executionCounter_ = _proposal.executionCounter;
    }

    function proposalState(
        uint32 _proposalId
    ) public view virtual override returns (ProposalState) {
        if (_proposalId >= _totalProposalCount) revert InvalidProposal();
        Proposal memory _proposal = _proposals[_proposalId];
        IStrategyV1 strategy_ = IStrategyV1(_proposal.strategy);

        (, uint48 votingEndTimestamp) = strategy_.getVotingTimestamps(
            _proposalId
        );

        if (block.timestamp <= votingEndTimestamp) {
            return ProposalState.ACTIVE;
        } else if (!strategy_.isPassed(_proposalId)) {
            return ProposalState.FAILED;
        } else if (_proposal.executionCounter == _proposal.txHashes.length) {
            return ProposalState.EXECUTED;
        } else if (
            block.timestamp <= votingEndTimestamp + _proposal.timelockPeriod
        ) {
            return ProposalState.TIMELOCKED;
        } else if (
            block.timestamp <=
            votingEndTimestamp +
                _proposal.timelockPeriod +
                _proposal.executionPeriod
        ) {
            return ProposalState.EXECUTABLE;
        } else {
            return ProposalState.EXPIRED;
        }
    }

    function generateTxHashData(
        Transaction calldata _transaction,
        uint256 _nonce
    ) public view virtual override returns (bytes memory) {
        uint256 chainId = block.chainid;
        bytes32 domainSeparator = keccak256(
            abi.encode(DOMAIN_SEPARATOR_TYPEHASH, chainId, this)
        );
        bytes32 transactionHash = keccak256(
            abi.encode(
                TRANSACTION_TYPEHASH,
                _transaction.to,
                _transaction.value,
                keccak256(_transaction.data),
                _transaction.operation,
                _nonce
            )
        );
        return
            abi.encodePacked(
                bytes1(0x19),
                bytes1(0x01),
                domainSeparator,
                transactionHash
            );
    }

    function getTxHash(
        Transaction calldata _transaction
    ) public view virtual override returns (bytes32) {
        return keccak256(generateTxHashData(_transaction, 0));
    }

    function _executeProposalTx(
        uint32 _proposalId,
        Transaction calldata _transaction
    ) internal virtual returns (bytes32 txHash) {
        if (proposalState(_proposalId) != ProposalState.EXECUTABLE)
            revert ProposalNotExecutable();
        txHash = getTxHash(_transaction);
        if (
            _proposals[_proposalId].txHashes[
                _proposals[_proposalId].executionCounter
            ] != txHash
        ) revert InvalidTxHash();

        _proposals[_proposalId].executionCounter++;

        if (
            !exec(
                _transaction.to,
                _transaction.value,
                _transaction.data,
                _transaction.operation
            )
        ) revert TxFailed();
    }

    function _updateTimelockPeriod(uint32 timelockPeriod_) internal virtual {
        _timelockPeriod = timelockPeriod_;
        emit TimelockPeriodUpdated(timelockPeriod_);
    }

    function _updateExecutionPeriod(uint32 executionPeriod_) internal virtual {
        _executionPeriod = executionPeriod_;
        emit ExecutionPeriodUpdated(executionPeriod_);
    }

    function _updateStrategy(address strategy_) internal virtual {
        if (strategy_ == address(0)) revert InvalidStrategy();
        _strategy = IStrategyV1(strategy_);
        emit StrategyUpdated(strategy_);
    }

    function version() public view virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(IAzoriusV1).interfaceId ||
            interfaceId == type(IVersion).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    function _transferOwnership(
        address newOwner
    ) internal virtual override(Ownable2StepUpgradeable, OwnableUpgradeable) {
        Ownable2StepUpgradeable._transferOwnership(newOwner);
    }

    function transferOwnership(
        address newOwner
    )
        public
        virtual
        override(Ownable2StepUpgradeable, OwnableUpgradeable)
        onlyOwner
    {
        Ownable2StepUpgradeable.transferOwnership(newOwner);
    }
}
