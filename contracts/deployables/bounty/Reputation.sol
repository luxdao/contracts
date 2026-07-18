// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IReputation, IKarmaSource} from "../../interfaces/dao/deployables/IReputation.sol";
import {IVersion} from "../../interfaces/dao/deployables/IVersion.sol";
import {IDeploymentBlock} from "../../interfaces/dao/IDeploymentBlock.sol";
import {DeploymentBlockInitializable} from "../../DeploymentBlockInitializable.sol";
import {InitializerEventEmitter} from "../../InitializerEventEmitter.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

/**
 * @title Reputation
 * @author Lux Industries Inc
 * @notice Composable worker completion history that ALSO bridges into global Karma
 * @dev The single canonical reputation half of the work-market: a minimal append-only ledger
 * of work outcomes per address (completed, disputesLost, totalEarned) PLUS a one-way bridge
 * that projects each accepted completion into the global, cross-DAO Karma reputation.
 * EIP-7201 namespaced ("DAO.Reputation.main") and deployed as a UUPS proxy.
 *
 * Exactly ONE writer (Bounty) may record outcomes, fixed at initialization. The completion
 * record carries a `source` tag (the market encodes keccak256(chainid, market, bountyId))
 * that is the Karma reason AND a once-only key.
 *
 * MONEY-PATH SAFETY — the load-bearing property. recordCompletion runs DURING a payout,
 * after the escrow already released the reward + stake. So the Karma bridge is BEST-EFFORT:
 *  - the local ledger increment is pure storage and always succeeds;
 *  - the external earnKarma call is wrapped in try/catch, so ANY revert (Karma soft-cap
 *    reached, controller paused, KARMA_SOURCE role not yet granted, a controller bug) is
 *    caught and emitted (KarmaBridgeFailed) — it can NEVER bubble up and brick the payout.
 * A worker who delivered is always paid; global Karma is an opportunistic projection.
 *
 * Karma amount is a flat, owner-configurable `karmaPerCompletion`, NOT the reward amount —
 * rewards span native/ERC-20/ERC-721/ERC-1155 with incommensurable units, and a
 * reward-proportional score would let a self-funded whale bounty farm the Karma cap.
 *
 * Karma slashing is NOT here: dispute losses record locally only. Slashing global Karma stays
 * Safe-governed on the Karma token itself (SLASHER role), orthogonal to this market.
 *
 * @custom:security-contact security@lux.network
 */
contract Reputation is
    IReputation,
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
     * @notice Main storage struct for Reputation following EIP-7201
     * @dev Contains the authorized writer, the Karma bridge config, the per-worker ledger,
     * and the once-only Karma mint guard.
     * @custom:storage-location erc7201:DAO.Reputation.main
     */
    struct ReputationStorage {
        /** @notice The only address permitted to record outcomes (the work market) */
        address writer;
        /** @notice The global Karma controller completions bridge into (0 => bridge off) */
        address karmaController;
        /** @notice The flat Karma award minted per completion (0 => bridge off) */
        uint256 karmaPerCompletion;
        /** @notice Mapping from worker address to cumulative local reputation */
        mapping(address worker => Reputation reputation) reputations;
        /** @notice Whether a completion source already bridged Karma (double-mint guard) */
        mapping(bytes32 source => bool minted) karmaMinted;
    }

    /**
     * @dev Storage slot for ReputationStorage calculated using EIP-7201 formula:
     * keccak256(abi.encode(uint256(keccak256("DAO.Reputation.main")) - 1)) & ~bytes32(uint256(0xff))
     */
    bytes32 internal constant REPUTATION_STORAGE_LOCATION =
        0xf899599c038ada4c407907b72cc4ff6a918eed5f442aad20ecfda2dc38201b00;

    /**
     * @dev Returns the storage struct for Reputation
     * @return $ The storage struct for Reputation
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
     * @notice Initializes the reputation ledger and its Karma bridge
     * @param owner_ The UUPS upgrade + config authority (the org Safe in production)
     * @param writer_ The only address permitted to record outcomes (the work market)
     * @param karmaController_ The global Karma controller (address(0) => bridge disabled)
     * @param karmaPerCompletion_ The flat Karma award per completion (0 => no minting)
     */
    function initialize(
        address owner_,
        address writer_,
        address karmaController_,
        uint256 karmaPerCompletion_
    ) public virtual initializer {
        if (writer_ == address(0)) revert InvalidWriter();

        __InitializerEventEmitter_init(abi.encode(owner_, writer_, karmaController_, karmaPerCompletion_));
        __Ownable_init(owner_);
        __DeploymentBlockInitializable_init();

        ReputationStorage storage $ = _getReputationStorage();
        $.writer = writer_;
        $.karmaController = karmaController_;
        $.karmaPerCompletion = karmaPerCompletion_;
    }

    /**
     * @notice Zodiac/module-style initializer for proxy-factory deployment
     * @param initializeParams_ ABI-encoded (owner, writer, karmaController, karmaPerCompletion)
     */
    function setUp(bytes memory initializeParams_) public virtual initializer {
        (address owner_, address writer_, address karmaController_, uint256 karmaPerCompletion_) = abi.decode(
            initializeParams_,
            (address, address, address, uint256)
        );
        if (writer_ == address(0)) revert InvalidWriter();

        __InitializerEventEmitter_init(initializeParams_);
        __Ownable_init(owner_);
        __DeploymentBlockInitializable_init();

        ReputationStorage storage $ = _getReputationStorage();
        $.writer = writer_;
        $.karmaController = karmaController_;
        $.karmaPerCompletion = karmaPerCompletion_;
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
    // IReputation — View Functions
    // ======================================================================

    /**
     * @inheritdoc IReputation
     */
    function writer() public view virtual override returns (address) {
        return _getReputationStorage().writer;
    }

    /**
     * @inheritdoc IReputation
     */
    function reputationOf(address worker_) public view virtual override returns (uint64, uint64, uint256) {
        Reputation storage r = _getReputationStorage().reputations[worker_];
        return (r.completed, r.disputesLost, r.totalEarned);
    }

    /**
     * @inheritdoc IReputation
     */
    function completedOf(address worker_) public view virtual override returns (uint64) {
        return _getReputationStorage().reputations[worker_].completed;
    }

    /**
     * @inheritdoc IReputation
     */
    function earnedOf(address worker_) public view virtual override returns (uint256) {
        return _getReputationStorage().reputations[worker_].totalEarned;
    }

    /**
     * @inheritdoc IReputation
     */
    function karmaController() public view virtual override returns (address) {
        return _getReputationStorage().karmaController;
    }

    /**
     * @inheritdoc IReputation
     */
    function karmaPerCompletion() public view virtual override returns (uint256) {
        return _getReputationStorage().karmaPerCompletion;
    }

    /**
     * @inheritdoc IReputation
     */
    function karmaMinted(bytes32 source_) public view virtual override returns (bool) {
        return _getReputationStorage().karmaMinted[source_];
    }

    // ======================================================================
    // IReputation — State-Changing Functions
    // ======================================================================

    /**
     * @inheritdoc IReputation
     * @dev Writer-only. Local increment (always succeeds) then a best-effort Karma bridge.
     */
    function recordCompletion(
        address worker_,
        uint256 amount_,
        bytes32 source_
    ) public virtual override onlyWriter {
        if (worker_ == address(0)) revert InvalidWorker();

        ReputationStorage storage $ = _getReputationStorage();
        Reputation storage r = $.reputations[worker_];
        uint64 completed = r.completed + 1;
        uint256 totalEarned = r.totalEarned + amount_;
        r.completed = completed;
        r.totalEarned = totalEarned;

        emit CompletionRecorded(worker_, amount_, completed, totalEarned);

        _bridgeKarma($, worker_, source_);
    }

    /**
     * @inheritdoc IReputation
     * @dev Writer-only. Local only — dispute losses never slash global Karma.
     */
    function recordDisputeLoss(address worker_) public virtual override onlyWriter {
        if (worker_ == address(0)) revert InvalidWorker();

        Reputation storage r = _getReputationStorage().reputations[worker_];
        uint64 disputesLost = r.disputesLost + 1;
        r.disputesLost = disputesLost;

        emit DisputeLossRecorded(worker_, disputesLost);
    }

    /**
     * @inheritdoc IReputation
     */
    function retryKarmaBridge(address worker_, bytes32 source_) public virtual override onlyOwner {
        if (worker_ == address(0)) revert InvalidWorker();
        _bridgeKarma(_getReputationStorage(), worker_, source_);
    }

    /**
     * @inheritdoc IReputation
     */
    function setKarmaController(address karmaController_) public virtual override onlyOwner {
        ReputationStorage storage $ = _getReputationStorage();
        $.karmaController = karmaController_;
        emit KarmaConfigUpdated(karmaController_, $.karmaPerCompletion);
    }

    /**
     * @inheritdoc IReputation
     */
    function setKarmaPerCompletion(uint256 amount_) public virtual override onlyOwner {
        ReputationStorage storage $ = _getReputationStorage();
        $.karmaPerCompletion = amount_;
        emit KarmaConfigUpdated($.karmaController, amount_);
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
     * @dev Supports IReputation, IVersion, IDeploymentBlock, and IERC165.
     */
    function supportsInterface(bytes4 interfaceId_) public view virtual override returns (bool) {
        return
            interfaceId_ == type(IReputation).interfaceId ||
            interfaceId_ == type(IVersion).interfaceId ||
            interfaceId_ == type(IDeploymentBlock).interfaceId ||
            super.supportsInterface(interfaceId_);
    }

    // ======================================================================
    // INTERNAL HELPERS
    // ======================================================================

    /**
     * @notice Best-effort projection of a completion into global Karma
     * @dev Never reverts. If the bridge is disabled (no controller / zero per-completion) or the
     * source already MINTED, it is a no-op (KarmaBridgeSkipped). Otherwise it marks the source minted
     * BEFORE the external call (checks-effects-interactions — a reentrant source can never
     * double-mint) and attempts earnKarma. The `minted` flag is CONSUMED only on SUCCESS: on a
     * transient failure (soft-cap / paused / role) it is RESET so the same completion can be
     * re-bridged later (e.g. once the org Safe unpauses or raises the cap), rather than being
     * permanently marked done. Exactly-once is still guaranteed: a success is never re-attempted.
     * @param $ The reputation storage
     * @param worker_ The worker credited with Karma
     * @param source_ The once-only source tag (also the Karma reason)
     */
    function _bridgeKarma(ReputationStorage storage $, address worker_, bytes32 source_) internal {
        address controllerAddr = $.karmaController;
        uint256 karmaAmount = $.karmaPerCompletion;

        if (controllerAddr == address(0) || karmaAmount == 0 || $.karmaMinted[source_]) {
            emit KarmaBridgeSkipped(worker_, source_);
            return;
        }

        // Effects before interaction: claim the once-only key up front (reentrancy double-mint guard).
        $.karmaMinted[source_] = true;

        // Interaction: best-effort. A Karma failure can NEVER revert the completion/payout, and on
        // failure the key is released so the completion remains retryable.
        try IKarmaSource(controllerAddr).earnKarma(worker_, karmaAmount, source_) {
            emit KarmaBridged(worker_, karmaAmount, source_);
        } catch (bytes memory reason) {
            $.karmaMinted[source_] = false;
            emit KarmaBridgeFailed(worker_, karmaAmount, source_, reason);
        }
    }
}
