// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {
    IPublicSaleV1
} from "../../interfaces/decent/deployables/IPublicSaleV1.sol";
import {IVersion} from "../../interfaces/decent/deployables/IVersion.sol";
import {
    DeploymentBlockInitializable
} from "../../DeploymentBlockInitializable.sol";
import {InitializerEventEmitter} from "../../InitializerEventEmitter.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {
    Ownable2StepUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

contract PublicSaleV1 is
    IPublicSaleV1,
    IVersion,
    DeploymentBlockInitializable,
    InitializerEventEmitter,
    ERC165,
    Ownable2StepUpgradeable
{
    // ======================================================================
    // STATE VARIABLES
    // ======================================================================

    /**
     * @notice Main storage struct for PublicSaleV1 following EIP-7201
     * @dev Contains all agreement configuration and signer state
     * @custom:storage-location erc7201:Decent.PublicSale.main
     */
    struct PublicSaleStorage {
        address feeToken;
        address saleToken;
        uint256 saleTokenMinimumAmount;
        uint256 saleTokenMaximumAmount;
        uint256 saleTokenPrice;
        uint48 saleStartTimestamp;
        uint48 saleCloseTimestamp;
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

    // ======================================================================
    // CONSTRUCTOR & INITIALIZERS
    // ======================================================================

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address feeToken_,
        address saleToken_,
        uint256 saleTokenMinimumAmount_,
        uint256 saleTokenMaximumAmount_,
        uint256 saleTokenPrice_,
        uint48 saleStartTimestamp_,
        uint48 saleCloseTimestamp_
    ) public virtual override initializer {
        if (saleCloseTimestamp_ < block.timestamp) {
            revert InvalidSaleCloseTimestamp();
        }

        if (saleTokenMinimumAmount_ > saleTokenMaximumAmount_) {
            revert InvalidSaleTokenAmounts();
        }

        __InitializerEventEmitter_init(
            abi.encode(
                owner_,
                feeToken_,
                saleToken_,
                saleTokenMinimumAmount_,
                saleTokenMaximumAmount_,
                saleTokenPrice_,
                saleCloseTimestamp_
            )
        );
        __Ownable_init(owner_);
        __DeploymentBlockInitializable_init();

        PublicSaleStorage storage $ = _getPublicSaleStorage();
        $.feeToken = feeToken_;
        $.saleToken = saleToken_;
        $.saleTokenMinimumAmount = saleTokenMinimumAmount_;
        $.saleTokenMaximumAmount = saleTokenMaximumAmount_;
        $.saleTokenPrice = saleTokenPrice_;
        $.saleStartTimestamp = saleStartTimestamp_;
        $.saleCloseTimestamp = saleCloseTimestamp_;
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
}
