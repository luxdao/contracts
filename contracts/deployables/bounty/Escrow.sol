// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IEscrow} from "../../interfaces/dao/deployables/IEscrow.sol";
import {IVersion} from "../../interfaces/dao/deployables/IVersion.sol";
import {IDeploymentBlock} from "../../interfaces/dao/IDeploymentBlock.sol";
import {DeploymentBlockInitializable} from "../../DeploymentBlockInitializable.sol";
import {InitializerEventEmitter} from "../../InitializerEventEmitter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

/**
 * @title Escrow
 * @author Lux Industries Inc
 * @notice Conservation-safe multi-asset value vault driven by a single controller contract
 * @dev The single canonical value-custody half of the work-market. It holds native coin,
 * ERC-20, ERC-721 and ERC-1155 assets in named deposits and releases/refunds them ONLY on
 * instruction from its configured controller (Bounty). It is pure custody mechanism with no
 * business policy — decomplecting value-holding from the work-market lifecycle (Rich Hickey).
 *
 * EIP-7201 namespaced ("DAO.Escrow.main") and deployed as a UUPS proxy.
 *
 * Implementation details:
 * - EIP-7201 namespaced storage and UUPS, deployable as master-copy + proxy.
 * - Reentrancy-safe via OZ ReentrancyGuardTransient + strict checks-effects-interactions: a
 *   deposit's `remaining` is debited BEFORE any outbound transfer. The ERC-721/1155
 *   `safeTransfer` on release/refund calls into the recipient (onERC{721,1155}Received); a
 *   reentrant release/refund is blocked by the guard AND finds `remaining` already debited,
 *   so no deposit can double-release.
 * - Conservation: every unit paid out was first deposited; the escrow never mints or burns.
 * - Exact custody: an NFT enters the ledger only through a controller-driven deposit() pull
 *   (guarded by a transient receive flag); an unsolicited direct ERC-721/1155 transfer is
 *   rejected, so the escrow holds exactly the NFTs its ledger tracks.
 * - ERC-20 fee-on-transfer / deflationary tokens are rejected at deposit (received != nominal).
 *   Rebasing tokens are NOT caught (their balance drifts AFTER a conformant deposit) and are
 *   unsupported — accounting is nominal, not balance-tracking.
 * - ERC-721 is indivisible: amount fixed at 1, released/refunded only whole.
 *
 * `token == address(0)` denotes the native coin (AssetKind.Native) everywhere.
 *
 * @custom:security-contact security@lux.network
 */
contract Escrow is
    IEscrow,
    IVersion,
    IERC721Receiver,
    IERC1155Receiver,
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
     * @notice Main storage struct for Escrow following EIP-7201
     * @dev Contains the controller and the deposit ledger
     * @custom:storage-location erc7201:DAO.Escrow.main
     */
    struct EscrowStorage {
        /** @notice The only address allowed to move funds (the policy contract) */
        address controller;
        /** @notice Mapping from deposit id to its record */
        mapping(bytes32 depositId => Deposit deposit) deposits;
        /**
         * @notice Claimable balances credited when an OUTWARD transfer failed (H1 pull-payment).
         * @dev Keyed by (recipient, assetKey) where assetKey = keccak256(kind, token, tokenId).
         * A failed release/refund never reverts the settlement: it debits the deposit and credits
         * the recipient here (the asset stays in escrow), and the recipient later withdraw()s.
         */
        mapping(address recipient => mapping(bytes32 assetKey => uint256 amount)) credits;
    }

    /**
     * @dev Storage slot for EscrowStorage calculated using EIP-7201 formula:
     * keccak256(abi.encode(uint256(keccak256("DAO.Escrow.main")) - 1)) & ~bytes32(uint256(0xff))
     */
    bytes32 internal constant ESCROW_STORAGE_LOCATION =
        0x54c8a2ceece909add6676b1f9f13f9d6fa7c3dff413f1b272041937b37c79300;

    /**
     * @dev Transient-storage slot for the NFT receive guard, keccak256("DAO.Escrow.receiving").
     * True only while deposit() is actively pulling an ERC-721/1155 in; onERC{721,1155}Received
     * requires it, so any unsolicited direct NFT transfer reverts. Transient (EIP-1153): auto
     * clears at end of tx, and a dedicated keccak slot can never collide with the reentrancy
     * guard's slot.
     */
    bytes32 private constant RECEIVING_NFT_SLOT =
        0x3d7b16636346d447aa60d379028db24d6f9cbf444f500da6cbcca0ecf314c1cd;

    /**
     * @dev Returns the storage struct for Escrow
     * @return $ The storage struct for Escrow
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
     * @param owner_ The UUPS upgrade authority
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
    // IEscrow — View Functions
    // ======================================================================

    /**
     * @inheritdoc IEscrow
     */
    function controller() public view virtual override returns (address) {
        return _getEscrowStorage().controller;
    }

    /**
     * @inheritdoc IEscrow
     */
    function deposits(
        bytes32 depositId_
    ) public view virtual override returns (AssetKind, address, address, uint256, uint256, uint256) {
        Deposit storage d = _getEscrowStorage().deposits[depositId_];
        return (d.kind, d.token, d.funder, d.tokenId, d.amount, d.remaining);
    }

    /**
     * @inheritdoc IEscrow
     */
    function remainingOf(bytes32 depositId_) public view virtual override returns (uint256) {
        return _getEscrowStorage().deposits[depositId_].remaining;
    }

    /**
     * @inheritdoc IEscrow
     */
    function creditOf(
        address recipient_,
        AssetKind kind_,
        address token_,
        uint256 tokenId_
    ) public view virtual override returns (uint256) {
        return _getEscrowStorage().credits[recipient_][_assetKey(kind_, token_, tokenId_)];
    }

    // ======================================================================
    // IEscrow — State-Changing Functions
    // ======================================================================

    /**
     * @inheritdoc IEscrow
     * @dev Creates a deposit of one asset. Native: msg.value == amount. ERC-20/721/1155:
     * msg.value == 0 and the asset is pulled from `funder`. The whole tx reverts on any
     * mismatch so no partial deposit is recorded.
     */
    function deposit(
        bytes32 depositId_,
        AssetKind kind_,
        address token_,
        address funder_,
        uint256 tokenId_,
        uint256 amount_
    ) public payable virtual override onlyController nonReentrant {
        if (amount_ == 0) revert ZeroAmount();

        EscrowStorage storage $ = _getEscrowStorage();
        Deposit storage d = $.deposits[depositId_];
        if (d.amount != 0) revert DepositExists(depositId_);

        if (kind_ == AssetKind.Native) {
            // Native coin: the value sent IS the deposit.
            if (msg.value != amount_) revert NativeValueMismatch(amount_, msg.value);
        } else if (kind_ == AssetKind.ERC20) {
            // ERC-20: no native value; pull the EXACT nominal amount (fee-on-transfer /
            // deflationary tokens where received != amount are rejected).
            if (msg.value != 0) revert UnexpectedNativeValue();
            IERC20 erc20 = IERC20(token_);
            uint256 balBefore = erc20.balanceOf(address(this));
            erc20.safeTransferFrom(funder_, address(this), amount_);
            uint256 received = erc20.balanceOf(address(this)) - balBefore;
            if (received != amount_) revert DepositAmountMismatch(amount_, received);
        } else if (kind_ == AssetKind.ERC721) {
            // ERC-721: exactly one indivisible token. Pull it in under the receive guard so
            // our own onERC721Received accepts it; an unsolicited transfer would revert.
            if (msg.value != 0) revert UnexpectedNativeValue();
            if (amount_ != 1) revert BadERC721Amount(amount_);
            _setReceiving(true);
            IERC721(token_).safeTransferFrom(funder_, address(this), tokenId_);
            _setReceiving(false);
        } else {
            // ERC-1155: a quantity of a semi-fungible id, pulled under the receive guard.
            if (msg.value != 0) revert UnexpectedNativeValue();
            _setReceiving(true);
            IERC1155(token_).safeTransferFrom(funder_, address(this), tokenId_, amount_, "");
            _setReceiving(false);
        }

        d.kind = kind_;
        d.token = token_;
        d.funder = funder_;
        d.tokenId = tokenId_;
        d.amount = amount_;
        d.remaining = amount_;

        emit Deposited(depositId_, kind_, token_, funder_, tokenId_, amount_);
    }

    /**
     * @inheritdoc IEscrow
     */
    function release(
        bytes32 depositId_,
        address to_,
        uint256 amount_
    ) public virtual override onlyController nonReentrant returns (bool delivered) {
        return _payout(depositId_, to_, amount_, true);
    }

    /**
     * @inheritdoc IEscrow
     */
    function refund(
        bytes32 depositId_,
        address to_,
        uint256 amount_
    ) public virtual override onlyController nonReentrant returns (bool delivered) {
        return _payout(depositId_, to_, amount_, false);
    }

    /**
     * @inheritdoc IEscrow
     * @dev Recipient-only pull of a credited (previously-failed) payout. Reverts if the retry
     * still fails, restoring the credit — so a permanently-unable recipient simply keeps the
     * claim; a settlement is never in this path, so reverting here is safe.
     */
    function withdraw(
        AssetKind kind_,
        address token_,
        uint256 tokenId_
    ) public virtual override nonReentrant returns (uint256 amount) {
        EscrowStorage storage $ = _getEscrowStorage();
        bytes32 key = _assetKey(kind_, token_, tokenId_);
        amount = $.credits[msg.sender][key];
        if (amount == 0) revert NoCredit();
        // Effects: zero before the transfer; a failed transfer reverts and restores it.
        $.credits[msg.sender][key] = 0;
        if (!_tryTransferOut(kind_, token_, tokenId_, msg.sender, amount)) revert WithdrawFailed();
        emit CreditWithdrawn(msg.sender, kind_, token_, tokenId_, amount);
    }

    /**
     * @inheritdoc IEscrow
     * @dev Controller-only reassignment of an EXACT amount of a credit from one recipient to
     * another (moves the claim, transfers nothing). The policy layer uses this for post-grace
     * funder-recovery of a reward a worker provably cannot receive (H1): the funder recovers
     * EXACTLY the bounty's credited reward — never the whole aggregated balance. Because a fungible
     * credit key can hold a worker's reward AND their stake (native reward + native stake collide),
     * bounding the move to the reward amount is what preserves the H2 stake floor and prevents one
     * funder from sweeping another funder's credited reward under the same asset.
     */
    function reassignCredit(
        address from_,
        address to_,
        AssetKind kind_,
        address token_,
        uint256 tokenId_,
        uint256 amount_
    ) public virtual override onlyController returns (uint256 amount) {
        if (to_ == address(0)) revert InvalidRecipient();
        if (amount_ == 0) revert ZeroAmount();
        EscrowStorage storage $ = _getEscrowStorage();
        bytes32 key = _assetKey(kind_, token_, tokenId_);
        uint256 avail = $.credits[from_][key];
        if (avail < amount_) revert InsufficientCredit(avail, amount_);
        $.credits[from_][key] = avail - amount_;
        $.credits[to_][key] += amount_;
        emit CreditReassigned(from_, to_, kind_, token_, tokenId_, amount_);
        return amount_;
    }

    // ======================================================================
    // ERC-721 / ERC-1155 Receiver hooks
    // ======================================================================

    /**
     * @inheritdoc IERC721Receiver
     * @dev Accepts an incoming ERC-721 ONLY while deposit() is pulling one in (the transient
     * receive guard is set); a direct unsolicited transfer reverts UnsolicitedTransfer, so the
     * escrow only ever holds NFTs its ledger tracks.
     */
    function onERC721Received(address, address, uint256, bytes calldata) external view override returns (bytes4) {
        if (!_isReceiving()) revert UnsolicitedTransfer();
        return IERC721Receiver.onERC721Received.selector;
    }

    /**
     * @inheritdoc IERC1155Receiver
     * @dev Accepts an incoming ERC-1155 ONLY while deposit() is pulling one in.
     */
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external view override returns (bytes4) {
        if (!_isReceiving()) revert UnsolicitedTransfer();
        return IERC1155Receiver.onERC1155Received.selector;
    }

    /**
     * @inheritdoc IERC1155Receiver
     * @dev The escrow never initiates a batch transfer, so a batch receive is always
     * unsolicited and is rejected — one deposit holds exactly one (id, quantity).
     */
    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert UnsolicitedTransfer();
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
     * @dev Supports IEscrow, IVersion, IDeploymentBlock, IERC721Receiver, IERC1155Receiver,
     * and IERC165.
     */
    function supportsInterface(
        bytes4 interfaceId_
    ) public view virtual override(ERC165, IERC165) returns (bool) {
        return
            interfaceId_ == type(IEscrow).interfaceId ||
            interfaceId_ == type(IVersion).interfaceId ||
            interfaceId_ == type(IDeploymentBlock).interfaceId ||
            interfaceId_ == type(IERC721Receiver).interfaceId ||
            interfaceId_ == type(IERC1155Receiver).interfaceId ||
            super.supportsInterface(interfaceId_);
    }

    // ======================================================================
    // INTERNAL HELPERS
    // ======================================================================

    /**
     * @notice Debits a deposit and transfers the asset out (release or refund), CREDITING the
     * recipient on transfer failure instead of reverting (H1 pull-payment)
     * @dev Checks-effects-interactions: `remaining` is decremented before the external transfer,
     * and the whole call is nonReentrant. This is the single point through which any value leaves
     * the escrow. The outward transfer is ATTEMPTED without bubbling — if it fails (a reverting /
     * non-receiver / blocklisted / paused recipient for native / ERC-20 / ERC-721 / ERC-1155), the
     * deposit is still debited and the amount is CREDITED to `to` (the asset stays in escrow), so a
     * bad recipient can never brick a settlement. `to` withdraw()s the credit later.
     * @param depositId_ The deposit to draw from
     * @param to_ The recipient
     * @param amount_ The amount to move out
     * @param isRelease_ True for a release (payout), false for a refund
     * @return delivered True if the asset was transferred out; false if it was credited instead.
     */
    function _payout(
        bytes32 depositId_,
        address to_,
        uint256 amount_,
        bool isRelease_
    ) internal returns (bool delivered) {
        if (amount_ == 0) revert ZeroAmount();
        if (to_ == address(0)) revert InvalidRecipient();

        Deposit storage d = _getEscrowStorage().deposits[depositId_];
        if (d.amount == 0) revert UnknownDeposit(depositId_);
        uint256 remaining = d.remaining;
        if (amount_ > remaining) revert InsufficientDeposit(depositId_, remaining, amount_);

        AssetKind kind = d.kind;
        address token = d.token;
        uint256 tokenId = d.tokenId;
        // ERC-721 is indivisible: it moves whole or not at all.
        if (kind == AssetKind.ERC721 && amount_ != remaining) revert PartialERC721Move(depositId_, amount_);

        // Effects: debit before interaction.
        d.remaining = remaining - amount_;

        // Interaction: ATTEMPT the outward transfer (never bubbles). Credit on failure.
        delivered = _tryTransferOut(kind, token, tokenId, to_, amount_);
        if (!delivered) {
            _getEscrowStorage().credits[to_][_assetKey(kind, token, tokenId)] += amount_;
            emit PayoutCredited(depositId_, to_, kind, token, tokenId, amount_);
        }

        if (isRelease_) {
            emit Released(depositId_, to_, amount_);
        } else {
            emit Refunded(depositId_, to_, amount_);
        }
    }

    /**
     * @notice Attempts to move an asset out WITHOUT bubbling a failure
     * @dev NO external call on this settlement path may revert-bubble, so no token/recipient can
     * brick a payout:
     * - Native: a low-level call (returns false on failure, never reverts).
     * - ERC-20: a low-level `transfer` call whose success is judged by the escrow's BALANCE DELTA,
     *   NOT the return value — immune to malformed returns (wrong length / non-0/1 word) that an
     *   `abi.decode(bool)` would revert on (M-1). BOTH balance reads use `staticcall` (via
     *   {_tokenBalance}): a token whose `balanceOf` reverts or short-returns is UNVERIFIABLE, so we
     *   cannot prove delivery and credit (ok=false) rather than bubble (R3-M1). Delivered only when
     *   the call did not revert AND both balances were readable AND at least `amount` actually left.
     * - ERC-721/1155: `safeTransferFrom` in try/catch, so a non-receiver / reverting-hook recipient
     *   is a caught failure. The caller forwards adequate gas; the recipient can burn at most 63/64
     *   (EIP-150), leaving the settlement enough to credit.
     * @return ok True if the asset was transferred out, false if it must be credited.
     */
    function _tryTransferOut(
        AssetKind kind_,
        address token_,
        uint256 tokenId_,
        address to_,
        uint256 amount_
    ) internal returns (bool ok) {
        if (kind_ == AssetKind.Native) {
            (ok, ) = payable(to_).call{value: amount_}("");
        } else if (kind_ == AssetKind.ERC20) {
            (bool okBefore, uint256 balBefore) = _tokenBalance(token_);
            (bool called, ) = token_.call(abi.encodeCall(IERC20.transfer, (to_, amount_)));
            (bool okAfter, uint256 balAfter) = _tokenBalance(token_);
            // Delivered only if the transfer did not revert, BOTH balances were verifiable, and at
            // least `amount` left. Any unverifiable balance (reverting / short-returning balanceOf)
            // => credit, never a bubble.
            ok = called && okBefore && okAfter && balAfter + amount_ <= balBefore;
        } else if (kind_ == AssetKind.ERC721) {
            try IERC721(token_).safeTransferFrom(address(this), to_, tokenId_) {
                ok = true;
            } catch {
                ok = false;
            }
        } else {
            try IERC1155(token_).safeTransferFrom(address(this), to_, tokenId_, amount_, "") {
                ok = true;
            } catch {
                ok = false;
            }
        }
    }

    /**
     * @dev Reads an ERC-20's balance of the escrow via low-level staticcall so a reverting or
     * short-returning `balanceOf` can never bubble on the settlement path (R3-M1). Returns
     * (false, 0) when the balance is UNVERIFIABLE (the view reverted or returned < 32 bytes), which
     * the outbound path treats as a failed delivery -> credit.
     */
    function _tokenBalance(address token_) internal view returns (bool ok, uint256 balance) {
        (bool success, bytes memory ret) = token_.staticcall(
            abi.encodeCall(IERC20.balanceOf, (address(this)))
        );
        if (success && ret.length >= 32) {
            return (true, abi.decode(ret, (uint256)));
        }
        return (false, 0);
    }

    /**
     * @dev Deterministic key for a credited asset: an outward failure for the same
     * (kind, token, tokenId) aggregates under one claim per recipient.
     */
    function _assetKey(AssetKind kind_, address token_, uint256 tokenId_) internal pure returns (bytes32) {
        return keccak256(abi.encode(kind_, token_, tokenId_));
    }

    /**
     * @dev Sets the transient NFT-receive guard.
     */
    function _setReceiving(bool value_) private {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            tstore(RECEIVING_NFT_SLOT, value_)
        }
    }

    /**
     * @dev Reads the transient NFT-receive guard.
     */
    function _isReceiving() private view returns (bool value_) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            value_ := tload(RECEIVING_NFT_SLOT)
        }
    }
}
