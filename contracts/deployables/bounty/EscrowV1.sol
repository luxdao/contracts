// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IEscrowV1} from "../../interfaces/dao/deployables/IEscrowV1.sol";
import {IVersion} from "../../interfaces/dao/deployables/IVersion.sol";
import {IDeploymentBlock} from "../../interfaces/dao/IDeploymentBlock.sol";
import {DeploymentBlockInitializable} from "../../DeploymentBlockInitializable.sol";
import {InitializerEventEmitter} from "../../InitializerEventEmitter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

/**
 * @title EscrowV1
 * @author Lux Industries Inc
 * @notice Conservation-safe value vault driven by a single controller contract
 * @dev Holds native coin and ERC-20 funds in named deposits and releases/refunds
 * them ONLY on instruction from its configured controller (e.g. BountyV1). It is
 * pure custody mechanism with no business policy — decomplecting value-holding from
 * the work-market lifecycle.
 *
 * Implementation details:
 * - EIP-7201 namespaced storage and UUPS, deployable as master-copy + proxy.
 * - Reentrancy-safe via OZ ReentrancyGuardTransient (transient storage, EIP-1153);
 *   combined with strict checks-effects-interactions (a deposit's `remaining` is
 *   debited before any external transfer), no deposit can ever overpay.
 * - Conservation: every payout is debited from a specific deposit's `remaining`,
 *   and a deposit can only be created by actually receiving funds, so total paid
 *   out per asset can never exceed total deposited. The escrow never mints or burns.
 * - Fee-on-transfer safe: ERC-20 deposits credit the exact observed balance delta.
 *
 * `token == address(0)` denotes the native coin everywhere.
 *
 * @custom:security-contact security@lux.network
 */
contract EscrowV1 is
    IEscrowV1,
    IVersion,
    DeploymentBlockInitializable,
    InitializerEventEmitter,
    Ownable2StepUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardTransient,
    ERC165
{
    using SafeERC20 for IERC20;

    // ======================================================================
    // STATE VARIABLES
    // ======================================================================

    /**
     * @notice Main storage struct for EscrowV1 following EIP-7201
     * @dev Contains the controller and the deposit ledger
     * @custom:storage-location erc7201:DAO.Escrow.main
     */
    struct EscrowStorage {
        /** @notice The only address allowed to move funds (the policy contract) */
        address controller;
        /** @notice Mapping from deposit id to its record */
        mapping(bytes32 depositId => Deposit deposit) deposits;
    }

    /**
     * @dev Storage slot for EscrowStorage calculated using EIP-7201 formula:
     * keccak256(abi.encode(uint256(keccak256("DAO.Escrow.main")) - 1)) & ~bytes32(uint256(0xff))
     */
    bytes32 internal constant ESCROW_STORAGE_LOCATION =
        0x54c8a2ceece909add6676b1f9f13f9d6fa7c3dff413f1b272041937b37c79300;

    /**
     * @dev Returns the storage struct for EscrowV1
     * Following the EIP-7201 namespaced storage pattern to avoid storage collisions
     * @return $ The storage struct for EscrowV1
     */
    function _getEscrowStorage() internal pure returns (EscrowStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := ESCROW_STORAGE_LOCATION
        }
    }

    // ======================================================================
    // MODIFIERS
    // ======================================================================

    /**
     * @notice Restricts a function to the configured controller
     * @custom:throws OnlyController if msg.sender is not the controller
     */
    modifier onlyController() {
        if (msg.sender != _getEscrowStorage().controller) revert OnlyController();
        _;
    }

    // ======================================================================
    // CONSTRUCTOR & INITIALIZERS
    // ======================================================================

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the escrow
     * @dev Sets the owner (UUPS upgrade authority) and the controller (fund mover).
     * @param owner_ The upgrade authority
     * @param controller_ The only address permitted to deposit/release/refund
     */
    function initialize(address owner_, address controller_) public virtual initializer {
        if (controller_ == address(0)) revert InvalidController();

        __InitializerEventEmitter_init(abi.encode(owner_, controller_));
        __Ownable_init(owner_);
        __DeploymentBlockInitializable_init();

        _getEscrowStorage().controller = controller_;
    }

    /**
     * @notice Zodiac/module-style initializer for proxy-factory deployment
     * @dev Decodes packed params and calls initialize.
     * @param initializeParams_ ABI-encoded (owner, controller)
     */
    function setUp(bytes memory initializeParams_) public virtual initializer {
        (address owner_, address controller_) = abi.decode(initializeParams_, (address, address));
        if (controller_ == address(0)) revert InvalidController();

        __InitializerEventEmitter_init(initializeParams_);
        __Ownable_init(owner_);
        __DeploymentBlockInitializable_init();

        _getEscrowStorage().controller = controller_;
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
    // IEscrowV1
    // ======================================================================

    // --- View Functions ---

    /**
     * @inheritdoc IEscrowV1
     */
    function controller() public view virtual override returns (address) {
        return _getEscrowStorage().controller;
    }

    /**
     * @inheritdoc IEscrowV1
     */
    function deposits(
        bytes32 depositId_
    ) public view virtual override returns (address, address, uint256, uint256) {
        Deposit storage d = _getEscrowStorage().deposits[depositId_];
        return (d.token, d.funder, d.amount, d.remaining);
    }

    /**
     * @inheritdoc IEscrowV1
     */
    function remainingOf(bytes32 depositId_) public view virtual override returns (uint256) {
        return _getEscrowStorage().deposits[depositId_].remaining;
    }

    // --- State-Changing Functions ---

    /**
     * @inheritdoc IEscrowV1
     * @dev Creates a deposit. Native: msg.value must equal amount. ERC-20: msg.value
     * must be 0 and the exact received balance delta is credited.
     */
    function deposit(
        bytes32 depositId_,
        address token_,
        address funder_,
        uint256 amount_
    ) public payable virtual override onlyController nonReentrant {
        if (amount_ == 0) revert ZeroAmount();

        EscrowStorage storage $ = _getEscrowStorage();
        Deposit storage d = $.deposits[depositId_];
        if (d.amount != 0) revert DepositExists(depositId_);

        uint256 credited;
        if (token_ == address(0)) {
            // Native coin: the value sent IS the deposit.
            if (msg.value != amount_) revert NativeValueMismatch(amount_, msg.value);
            credited = amount_;
        } else {
            // ERC-20: no native value, pull from funder, credit exact delta received.
            if (msg.value != 0) revert UnexpectedNativeValue();
            IERC20 erc20 = IERC20(token_);
            uint256 balBefore = erc20.balanceOf(address(this));
            erc20.safeTransferFrom(funder_, address(this), amount_);
            credited = erc20.balanceOf(address(this)) - balBefore;
            if (credited == 0) revert ZeroAmount();
        }

        d.token = token_;
        d.funder = funder_;
        d.amount = credited;
        d.remaining = credited;

        emit Deposited(depositId_, token_, funder_, credited);
    }

    /**
     * @inheritdoc IEscrowV1
     */
    function release(
        bytes32 depositId_,
        address to_,
        uint256 amount_
    ) public virtual override onlyController nonReentrant {
        _payout(depositId_, to_, amount_, true);
    }

    /**
     * @inheritdoc IEscrowV1
     */
    function refund(
        bytes32 depositId_,
        address to_,
        uint256 amount_
    ) public virtual override onlyController nonReentrant {
        _payout(depositId_, to_, amount_, false);
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
     * @dev Supports IEscrowV1, IVersion, IDeploymentBlock, and IERC165.
     */
    function supportsInterface(bytes4 interfaceId_) public view virtual override returns (bool) {
        return
            interfaceId_ == type(IEscrowV1).interfaceId ||
            interfaceId_ == type(IVersion).interfaceId ||
            interfaceId_ == type(IDeploymentBlock).interfaceId ||
            super.supportsInterface(interfaceId_);
    }

    // ======================================================================
    // INTERNAL HELPERS
    // ======================================================================

    /**
     * @notice Debits a deposit and transfers funds out (release or refund)
     * @dev Checks-effects-interactions: `remaining` is decremented before the
     * external transfer, and the whole call is nonReentrant. This is the single
     * point through which any value leaves the escrow, so conservation is enforced
     * in exactly one place.
     * @param depositId_ The deposit to draw from
     * @param to_ The recipient
     * @param amount_ The amount to move out
     * @param isRelease True for a release (payout), false for a refund
     */
    function _payout(bytes32 depositId_, address to_, uint256 amount_, bool isRelease) internal {
        if (amount_ == 0) revert ZeroAmount();
        if (to_ == address(0)) revert InvalidRecipient();

        Deposit storage d = _getEscrowStorage().deposits[depositId_];
        if (d.amount == 0) revert UnknownDeposit(depositId_);
        uint256 remaining = d.remaining;
        if (amount_ > remaining) revert InsufficientDeposit(depositId_, remaining, amount_);

        // Effects: debit before interaction.
        d.remaining = remaining - amount_;

        // Interaction.
        address token = d.token;
        if (token == address(0)) {
            (bool ok, ) = payable(to_).call{value: amount_}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(to_, amount_);
        }

        if (isRelease) {
            emit Released(depositId_, to_, amount_);
        } else {
            emit Refunded(depositId_, to_, amount_);
        }
    }
}
