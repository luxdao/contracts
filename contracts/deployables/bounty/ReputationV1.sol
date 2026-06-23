// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IReputationV1} from "../../interfaces/dao/deployables/IReputationV1.sol";
import {IVersion} from "../../interfaces/dao/deployables/IVersion.sol";
import {IDeploymentBlock} from "../../interfaces/dao/IDeploymentBlock.sol";
import {DeploymentBlockInitializable} from "../../DeploymentBlockInitializable.sol";
import {InitializerEventEmitter} from "../../InitializerEventEmitter.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

/**
 * @title ReputationV1
 * @author Lux Industries Inc
 * @notice Composable, non-transferable worker completion history for a work market
 * @dev A minimal append-only ledger of work outcomes per address: completed
 * (accepted) bounties, total value earned, and disputes lost. It is deliberately
 * NOT a token — there is nothing transferable — so it is pure reputation that any
 * contract or UI can read and compose with (Rich Hickey: values, not places). The
 * simplest representation that is composable and gas-sane is a mapping plus view
 * functions; no soulbound NFT machinery is needed to read a worker's standing.
 *
 * Exactly ONE writer (the work-market contract, e.g. BountyV1) may record outcomes,
 * fixed at initialization. The "who adjudicated" authority stays with the contract
 * that runs the lifecycle; the "who may read" set stays open.
 *
 * Implementation details:
 * - EIP-7201 namespaced storage and UUPS, deployable as master-copy + proxy.
 * - No external value transfers, so no reentrancy surface.
 *
 * @custom:security-contact security@lux.network
 */
contract ReputationV1 is
    IReputationV1,
    IVersion,
    DeploymentBlockInitializable,
    InitializerEventEmitter,
    Ownable2StepUpgradeable,
    UUPSUpgradeable,
    ERC165
{
    // ======================================================================
    // STATE VARIABLES
    // ======================================================================

    /**
     * @notice Main storage struct for ReputationV1 following EIP-7201
     * @dev Contains the authorized writer and the per-worker reputation ledger
     * @custom:storage-location erc7201:DAO.Reputation.main
     */
    struct ReputationStorage {
        /** @notice The only address permitted to record outcomes (the work market) */
        address writer;
        /** @notice Mapping from worker address to cumulative reputation */
        mapping(address worker => Reputation reputation) reputations;
    }

    /**
     * @dev Storage slot for ReputationStorage calculated using EIP-7201 formula:
     * keccak256(abi.encode(uint256(keccak256("DAO.Reputation.main")) - 1)) & ~bytes32(uint256(0xff))
     */
    bytes32 internal constant REPUTATION_STORAGE_LOCATION =
        0xf899599c038ada4c407907b72cc4ff6a918eed5f442aad20ecfda2dc38201b00;

    /**
     * @dev Returns the storage struct for ReputationV1
     * Following the EIP-7201 namespaced storage pattern to avoid storage collisions
     * @return $ The storage struct for ReputationV1
     */
    function _getReputationStorage() internal pure returns (ReputationStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := REPUTATION_STORAGE_LOCATION
        }
    }

    // ======================================================================
    // MODIFIERS
    // ======================================================================

    /**
     * @notice Restricts a function to the configured writer
     * @custom:throws OnlyWriter if msg.sender is not the writer
     */
    modifier onlyWriter() {
        if (msg.sender != _getReputationStorage().writer) revert OnlyWriter();
        _;
    }

    // ======================================================================
    // CONSTRUCTOR & INITIALIZERS
    // ======================================================================

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the reputation ledger
     * @param owner_ The upgrade authority
     * @param writer_ The only address permitted to record outcomes (the work market)
     */
    function initialize(address owner_, address writer_) public virtual initializer {
        if (writer_ == address(0)) revert InvalidWriter();

        __InitializerEventEmitter_init(abi.encode(owner_, writer_));
        __Ownable_init(owner_);
        __DeploymentBlockInitializable_init();

        _getReputationStorage().writer = writer_;
    }

    /**
     * @notice Zodiac/module-style initializer for proxy-factory deployment
     * @param initializeParams_ ABI-encoded (owner, writer)
     */
    function setUp(bytes memory initializeParams_) public virtual initializer {
        (address owner_, address writer_) = abi.decode(initializeParams_, (address, address));
        if (writer_ == address(0)) revert InvalidWriter();

        __InitializerEventEmitter_init(initializeParams_);
        __Ownable_init(owner_);
        __DeploymentBlockInitializable_init();

        _getReputationStorage().writer = writer_;
    }

    // ======================================================================
    // UUPSUpgradeable
    // ======================================================================

    /**
     * @inheritdoc UUPSUpgradeable
     * @dev Restricted to the owner.
     */
    function _authorizeUpgrade(address newImplementation_) internal virtual override onlyOwner {
        // solhint-disable-previous-line no-empty-blocks
        // Authorization handled by onlyOwner.
    }

    // ======================================================================
    // IReputationV1
    // ======================================================================

    // --- View Functions ---

    /**
     * @inheritdoc IReputationV1
     */
    function writer() public view virtual override returns (address) {
        return _getReputationStorage().writer;
    }

    /**
     * @inheritdoc IReputationV1
     */
    function reputationOf(
        address worker_
    ) public view virtual override returns (uint64, uint64, uint256) {
        Reputation storage r = _getReputationStorage().reputations[worker_];
        return (r.completed, r.disputesLost, r.totalEarned);
    }

    /**
     * @inheritdoc IReputationV1
     */
    function completedOf(address worker_) public view virtual override returns (uint64) {
        return _getReputationStorage().reputations[worker_].completed;
    }

    /**
     * @inheritdoc IReputationV1
     */
    function earnedOf(address worker_) public view virtual override returns (uint256) {
        return _getReputationStorage().reputations[worker_].totalEarned;
    }

    // --- State-Changing Functions ---

    /**
     * @inheritdoc IReputationV1
     */
    function recordCompletion(address worker_, uint256 amount_) public virtual override onlyWriter {
        if (worker_ == address(0)) revert InvalidWorker();

        Reputation storage r = _getReputationStorage().reputations[worker_];
        uint64 completed = r.completed + 1;
        uint256 totalEarned = r.totalEarned + amount_;
        r.completed = completed;
        r.totalEarned = totalEarned;

        emit CompletionRecorded(worker_, amount_, completed, totalEarned);
    }

    /**
     * @inheritdoc IReputationV1
     */
    function recordDisputeLoss(address worker_) public virtual override onlyWriter {
        if (worker_ == address(0)) revert InvalidWorker();

        Reputation storage r = _getReputationStorage().reputations[worker_];
        uint64 disputesLost = r.disputesLost + 1;
        r.disputesLost = disputesLost;

        emit DisputeLossRecorded(worker_, disputesLost);
    }

    // ======================================================================
    // IVersion
    // ======================================================================

    /**
     * @inheritdoc IVersion
     */
    function version() public pure virtual override returns (uint16) {
        return 1;
    }

    // ======================================================================
    // ERC165
    // ======================================================================

    /**
     * @inheritdoc ERC165
     * @dev Supports IReputationV1, IVersion, IDeploymentBlock, and IERC165.
     */
    function supportsInterface(bytes4 interfaceId_) public view virtual override returns (bool) {
        return
            interfaceId_ == type(IReputationV1).interfaceId ||
            interfaceId_ == type(IVersion).interfaceId ||
            interfaceId_ == type(IDeploymentBlock).interfaceId ||
            super.supportsInterface(interfaceId_);
    }
}
