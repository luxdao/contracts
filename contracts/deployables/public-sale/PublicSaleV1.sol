// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {
    IPublicSaleV1
} from "../../interfaces/decent/deployables/IPublicSaleV1.sol";
import {IVersion} from "../../interfaces/decent/deployables/IVersion.sol";
import {IDeploymentBlock} from "../../interfaces/decent/IDeploymentBlock.sol";
import {
    DeploymentBlockInitializable
} from "../../DeploymentBlockInitializable.sol";
import {InitializerEventEmitter} from "../../InitializerEventEmitter.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {
    Ownable2StepUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract PublicSaleV1 is
    IPublicSaleV1,
    IVersion,
    DeploymentBlockInitializable,
    InitializerEventEmitter,
    ERC165,
    Ownable2StepUpgradeable
{
    using SafeERC20 for IERC20;

    // ======================================================================
    // STATE VARIABLES
    // ======================================================================

    /**
     * @notice Main storage struct for PublicSaleV1 following EIP-7201
     * @dev Contains all agreement configuration and signer state
     * @custom:storage-location erc7201:Decent.PublicSale.main
     */
    struct PublicSaleStorage {
        address commitmentToken;
        address saleToken;
        uint256 minimumCommitment;
        uint256 maximumCommitment;
        uint256 minimumTotalCommitment;
        uint256 maximumTotalCommitment;
        uint256 saleTokenPrice;
        uint48 saleStartTimestamp;
        uint48 saleCloseTimestamp;
        uint256 totalCommitments;
        mapping(address account => uint256 commitmentAmount) commitments;
    }

    /**
     * @dev Storage slot for PublicSaleStorage calculated using EIP-7201 formula:
     * keccak256(abi.encode(uint256(keccak256("Decent.PublicSale.main")) - 1)) & ~bytes32(uint256(0xff))
     */
    bytes32 internal constant PUBLIC_SALE_STORAGE_LOCATION =
        0x2954b43716f55c3a12eeb02cbe9a8c7ed7e82022cc9255428b4df142a8f4fa00;

    /**
     * @dev Returns the storage struct for PublicSaleV1
     * Following the EIP-7201 namespaced storage pattern to avoid storage collisions
     * @return $ The storage struct for PublicSaleV1
     */
    function _getPublicSaleStorage()
        internal
        pure
        returns (PublicSaleStorage storage $)
    {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := PUBLIC_SALE_STORAGE_LOCATION
        }
    }

    /** @notice Address used to represent native ETH */
    address internal constant NATIVE_ASSET =
        0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /** @notice Precision for sale token price calculations (18 decimals) */
    uint256 internal constant PRECISION = 10 ** 18;

    // ======================================================================
    // CONSTRUCTOR & INITIALIZERS
    // ======================================================================

    constructor() {
        _disableInitializers();
    }

    function initialize(
        InitializerParams memory params_
    ) public virtual override initializer {
        if (params_.saleStartTimestamp_ > params_.saleCloseTimestamp_) {
            revert InvalidSaleTimestamps();
        }

        if (params_.saleCloseTimestamp_ < block.timestamp) {
            revert InvalidSaleEndTimestamp();
        }

        if (params_.minimumCommitment_ > params_.maximumCommitment_) {
            revert InvalidCommitmentAmounts();
        }

        __InitializerEventEmitter_init(
            abi.encode(
                params_
            )
        );
        __Ownable_init(params_.owner_);
        __DeploymentBlockInitializable_init();

        PublicSaleStorage storage $ = _getPublicSaleStorage();
        $.commitmentToken = params_.commitmentToken_;
        $.saleToken = params_.saleToken_;
        $.minimumCommitment = params_.minimumCommitment_;
        $.maximumCommitment = params_.maximumCommitment_;
        $.minimumTotalCommitment = params_.minimumTotalCommitment_;
        $.maximumTotalCommitment = params_.maximumTotalCommitment_;
        $.saleTokenPrice = params_.saleTokenPrice_;
        $.saleStartTimestamp = params_.saleStartTimestamp_;
        $.saleCloseTimestamp = params_.saleCloseTimestamp_;

        uint256 saleTokenEscrowAmount = (params_.maximumTotalCommitment_ * PRECISION) /
            params_.saleTokenPrice_;

        // transfer sale token from holder to this contract
        IERC20(params_.saleToken_).safeTransferFrom(
            params_.saleTokenHolder_,
            address(this),
            saleTokenEscrowAmount
        );
    }

    // ======================================================================
    // IPublicSaleV1
    // ======================================================================

    // --- View Functions ---

    // --- State-Changing Functions ---

    function commit(uint256 amount_) public payable virtual override {
        // TODO: check that sale is active
        PublicSaleStorage storage $ = _getPublicSaleStorage();

        if (block.timestamp < $.saleStartTimestamp) {
            revert SaleNotStarted();
        }

        if (block.timestamp > $.saleCloseTimestamp) {
            revert SaleClosed();
        }

        // cannot commit less than minimum commitment, 
        // unless it reaches the maximumTotalCommitment
        if (
            amount_ < $.minimumCommitment &&
            amount_ + $.totalCommitments != $.maximumTotalCommitment
        ) {
            revert MinimumCommitment();
        }

        if (amount_ + $.totalCommitments > $.maximumTotalCommitment) {
            revert MaximumTotalCommitment();
        }

        if (amount_ > $.maximumCommitment) {
            revert MaximumCommitment();
        }

        address commitmentToken = $.commitmentToken;

        if (commitmentToken == NATIVE_ASSET) {
            if (msg.value != amount_) {
                revert InvalidBidAmount();
            }
        } else {
            IERC20(commitmentToken).safeTransferFrom(
                msg.sender,
                address(this),
                amount_
            );
        }

        $.commitments[msg.sender] += amount_;
        $.totalCommitments += amount_;

        emit BidPlaced(msg.sender, amount_);
    }

    function close() public virtual override {
        PublicSaleStorage storage $ = _getPublicSaleStorage();
        if (block.timestamp < $.saleCloseTimestamp) {
            revert SaleCloseTimestampNotElapsed();
        }

        // TODO: transfer sale token to sale token holder
        // TODO: transfer fee token to fee token holder
        // TODO: emit SaleClosed event
    }

    // ======================================================================
    // IVersion
    // ======================================================================

    // --- Pure Functions ---

    /**
     * @inheritdoc IVersion
     */
    function version() public pure virtual override returns (uint16) {
        return 1;
    }

    // ======================================================================
    // ERC165
    // ======================================================================

    // --- View Functions ---

    /**
     * @inheritdoc ERC165
     * @dev Supports IPublicSaleV1, IVersion, IDeploymentBlock, and IERC165
     */
    function supportsInterface(
        bytes4 interfaceId_
    ) public view virtual override returns (bool) {
        return
            interfaceId_ == type(IPublicSaleV1).interfaceId ||
            interfaceId_ == type(IVersion).interfaceId ||
            interfaceId_ == type(IDeploymentBlock).interfaceId ||
            super.supportsInterface(interfaceId_);
    }

    // ======================================================================
    // INTERNAL HELPERS
    // ======================================================================

    // function _transferFeeToken(address to_, uint256 amount_) internal {
    //     PublicSaleStorage storage $ = _getPublicSaleStorage();
    //     address feeToken = $.feeToken;
    //     if (feeToken == NATIVE_ASSET) {
    //         (bool success, ) = to_.call{value: amount_}("");
    //         if (!success) {
    //             revert TransferFailed();
    //         }
    //     } else {
    //         IERC20(feeToken).safeTransfer(to_, amount_);
    //     }
    // }
}
