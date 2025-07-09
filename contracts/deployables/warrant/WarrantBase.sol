// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {
    IWarrantBase
} from "../../interfaces/decent/deployables/IWarrantBase.sol";
import {
    IVotesERC20V1
} from "../../interfaces/decent/deployables/IVotesERC20V1.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {
    Ownable2StepUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

/**
 * @title WarrantBase
 * @author Decent Labs
 * @notice Abstract base contract for warrant implementations
 * @dev This abstract contract provides the core warrant functionality that can be extended
 * by specific implementations (e.g., Hedgey, Sablier). It handles fee collection,
 * expiration logic, and clawback functionality.
 *
 * Key features:
 * - EIP-7201 namespaced storage for upgradeability
 * - Support for both absolute and relative time modes
 * - Owner-restricted clawback after expiration
 * - Abstract execution logic for implementation flexibility
 *
 * Implementations must:
 * - Override _executeWarrant() to handle vesting creation
 * - Call __WarrantBase_init() in their initializer
 * - Add implementation-specific storage using separate namespace
 *
 * @custom:security-contact security@decentlabs.io
 */
abstract contract WarrantBase is IWarrantBase, Ownable2StepUpgradeable {
    using SafeERC20 for IERC20;

    // ======================================================================
    // STATE VARIABLES
    // ======================================================================

    /**
     * @notice Main storage struct for WarrantBase following EIP-7201
     * @dev Contains core warrant state shared by all implementations
     * @custom:storage-location erc7201:Decent.WarrantBase.main
     */
    struct WarrantBaseStorage {
        /** @notice Whether warrant uses relative time based on token unlock */
        bool relativeTime;
        /** @notice Whether the warrant has been executed */
        bool executed;
        /** @notice Address authorized to execute this warrant */
        address warrantHolder;
        /** @notice Token to be vested upon execution */
        address token;
        /** @notice Token used for fee payment */
        address feeToken;
        /** @notice Amount of tokens to be vested */
        uint256 tokenAmount;
        /** @notice Price per token in fee token units (18 decimal precision) */
        uint256 tokenPrice;
        /** @notice Address that receives fee payments */
        address feeReceiver;
        /** @notice Expiration timestamp or duration based on time mode */
        uint256 expiration;
    }

    /**
     * @dev Storage slot for WarrantBaseStorage calculated using EIP-7201 formula:
     * keccak256(abi.encode(uint256(keccak256("Decent.WarrantBase.main")) - 1)) & ~bytes32(uint256(0xff))
     */
    bytes32 internal constant WARRANT_BASE_STORAGE_LOCATION =
        0x11946e6c3a7ab0bdf8943cbfcc510153ac225d47cbb8b46653c31d17d2c7f700;

    /**
     * @dev Returns the storage struct for WarrantBase
     * Following the EIP-7201 namespaced storage pattern to avoid storage collisions
     */
    function _getWarrantBaseStorage()
        internal
        pure
        returns (WarrantBaseStorage storage)
    {
        WarrantBaseStorage storage $;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := WARRANT_BASE_STORAGE_LOCATION
        }
        return $;
    }

    /** @notice Precision for token price calculations (18 decimals) */
    uint256 internal constant PRECISION = 10 ** 18;

    // ======================================================================
    // CONSTRUCTOR & INITIALIZERS
    // ======================================================================

    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Internal initializer for base warrant functionality
     * @param relativeTime_ Whether to use relative time based on token unlock
     * @param owner_ Owner address who can clawback after expiration
     * @param warrantHolder_ Address authorized to execute the warrant
     * @param token_ Token to be vested
     * @param feeToken_ Token used for fee payment
     * @param tokenAmount_ Amount of tokens to vest
     * @param tokenPrice_ Price per token in fee token units (18 decimals)
     * @param feeReceiver_ Address that receives fee payments
     * @param expiration_ Expiration timestamp or duration
     */
    function __WarrantBase_init(
        // solhint-disable-previous-line func-name-mixedcase
        bool relativeTime_,
        address owner_,
        address warrantHolder_,
        address token_,
        address feeToken_,
        uint256 tokenAmount_,
        uint256 tokenPrice_,
        address feeReceiver_,
        uint256 expiration_
    ) internal onlyInitializing {
        __Ownable_init(owner_);

        // If relative time mode, verify token supports IVotesERC20V1
        if (relativeTime_) {
            bool supported;
            try
                ERC165(token_).supportsInterface(
                    type(IVotesERC20V1).interfaceId
                )
            returns (bool result) {
                supported = result;
            } catch {
                // solhint-disable-previous-line no-empty-blocks
                // supported is already false by default
            }
            if (!supported) revert UnsupportedToken();
        }

        WarrantBaseStorage storage $ = _getWarrantBaseStorage();
        $.relativeTime = relativeTime_;
        $.warrantHolder = warrantHolder_;
        $.token = token_;
        $.feeToken = feeToken_;
        $.tokenAmount = tokenAmount_;
        $.tokenPrice = tokenPrice_;
        $.feeReceiver = feeReceiver_;
        $.expiration = expiration_;
    }

    // ======================================================================
    // IWarrantBase
    // ======================================================================

    // --- View Functions ---

    /**
     * @inheritdoc IWarrantBase
     */
    function relativeTime() public view virtual override returns (bool) {
        WarrantBaseStorage storage $ = _getWarrantBaseStorage();
        return $.relativeTime;
    }

    /**
     * @inheritdoc IWarrantBase
     */
    function warrantHolder() public view virtual override returns (address) {
        WarrantBaseStorage storage $ = _getWarrantBaseStorage();
        return $.warrantHolder;
    }

    /**
     * @inheritdoc IWarrantBase
     */
    function token() public view virtual override returns (address) {
        WarrantBaseStorage storage $ = _getWarrantBaseStorage();
        return $.token;
    }

    /**
     * @inheritdoc IWarrantBase
     */
    function feeToken() public view virtual override returns (address) {
        WarrantBaseStorage storage $ = _getWarrantBaseStorage();
        return $.feeToken;
    }

    /**
     * @inheritdoc IWarrantBase
     */
    function tokenAmount() public view virtual override returns (uint256) {
        WarrantBaseStorage storage $ = _getWarrantBaseStorage();
        return $.tokenAmount;
    }

    /**
     * @inheritdoc IWarrantBase
     */
    function tokenPrice() public view virtual override returns (uint256) {
        WarrantBaseStorage storage $ = _getWarrantBaseStorage();
        return $.tokenPrice;
    }

    /**
     * @inheritdoc IWarrantBase
     */
    function feeReceiver() public view virtual override returns (address) {
        WarrantBaseStorage storage $ = _getWarrantBaseStorage();
        return $.feeReceiver;
    }

    /**
     * @inheritdoc IWarrantBase
     */
    function expiration() public view virtual override returns (uint256) {
        WarrantBaseStorage storage $ = _getWarrantBaseStorage();
        return $.expiration;
    }

    /**
     * @inheritdoc IWarrantBase
     */
    function executed() public view virtual override returns (bool) {
        WarrantBaseStorage storage $ = _getWarrantBaseStorage();
        return $.executed;
    }

    // --- State-Changing Functions ---

    /**
     * @inheritdoc IWarrantBase
     * @dev Validates conditions, collects fee, and delegates to _executeWarrant
     */
    function execute(address recipient_) public virtual override {
        WarrantBaseStorage storage $ = _getWarrantBaseStorage();

        // Validate caller and state
        if (msg.sender != $.warrantHolder) revert OnlyWarrantHolder();
        if ($.executed) revert AlreadyExecuted();

        // Check expiration based on time mode and token lock if relative time
        if ($.relativeTime) {
            if (IVotesERC20V1($.token).locked()) revert TokenLocked();
            if (
                block.timestamp >
                IVotesERC20V1($.token).getUnlockTime() + $.expiration
            ) revert Expired();
        } else {
            if (block.timestamp > $.expiration) revert Expired();
        }

        // Calculate and collect fee
        uint256 feeAmount = ($.tokenAmount * $.tokenPrice) / PRECISION;
        IERC20($.feeToken).safeTransferFrom(
            msg.sender,
            $.feeReceiver,
            feeAmount
        );

        // Mark as executed
        $.executed = true;

        // Delegate to implementation-specific logic
        _executeWarrant(recipient_);

        emit Executed(recipient_);
    }

    /**
     * @inheritdoc IWarrantBase
     */
    function clawback(address recipient_) public virtual override onlyOwner {
        WarrantBaseStorage storage $ = _getWarrantBaseStorage();

        if ($.executed) revert AlreadyExecuted();

        // Check expiration based on time mode
        if ($.relativeTime) {
            if (IVotesERC20V1($.token).locked()) revert TokenLocked();
            if (
                block.timestamp <
                IVotesERC20V1($.token).getUnlockTime() + $.expiration
            ) {
                revert WarrantNotExpired();
            }
        } else {
            if (block.timestamp < $.expiration) revert WarrantNotExpired();
        }

        // Transfer tokens to recipient
        IERC20($.token).safeTransfer(recipient_, $.tokenAmount);

        emit Clawback(recipient_, $.tokenAmount);
    }

    // ======================================================================
    // INTERNAL HELPERS
    // ======================================================================

    /**
     * @notice Implementation-specific warrant execution logic
     * @dev Must be overridden by implementations to create vesting plans
     * @param recipient_ Address that will receive the vested tokens
     */
    function _executeWarrant(address recipient_) internal virtual;
}
