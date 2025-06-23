// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IVersion} from "../../interfaces/decent/deployables/IVersion.sol";
import {IDeploymentBlockV1} from "../../interfaces/decent/IDeploymentBlockV1.sol";
import {DeploymentBlockV1} from "../../DeploymentBlockV1.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {IWarrantV1} from "../../interfaces/decent/deployables/IWarrantV1.sol";

contract WarrantV1 is
    IVersion,
    Ownable2StepUpgradeable,
    DeploymentBlockV1,
    ERC165,
    IWarrantV1
{
    using SafeERC20 for IERC20;

    // ======================================================================
    // STATE VARIABLES
    // ======================================================================

    /**
     * @notice Main storage struct for WarrantV1 following EIP-7201
     * @dev Contains all staking and rewards state
     * @custom:storage-location erc7201:Decent.Warrant.main
     */
    struct WarrantStorage {
        address investor;
        address token;
        uint256 tokenAmount;
        uint256 tokenPrice;
        address feeReceiver;
        uint256 expiration;
        uint256 hedgeyCliff;
        uint256 hedgeyRate;
        uint256 hedgeyPeriod;
    }

    /**
     * @dev Storage slot for WarrantStorage calculated using EIP-7201 formula:
     * keccak256(abi.encode(uint256(keccak256("Decent.Warrant.main")) - 1)) & ~bytes32(uint256(0xff))
     */
    bytes32 internal constant WARRANT_STORAGE_LOCATION =
        0x464bb69150a83c92251262175cc668545fa78843d317b30544f04077119c4600;

    /**
     * @dev Returns the storage struct for WarrantV1
     * Following the EIP-7201 namespaced storage pattern to avoid storage collisions
     */
    function _getWarrantStorage()
        internal
        pure
        returns (WarrantStorage storage $)
    {
        assembly {
            $.slot := WARRANT_STORAGE_LOCATION
        }
    }

    // ======================================================================
    // CONSTRUCTOR & INITIALIZERS
    // ======================================================================


    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address investor_,
        address token_,
        uint256 tokenAmount_,
        uint256 tokenPrice_,
        address feeReceiver_,
        uint256 expiration_,
        uint256 hedgeyCliff_,
        uint256 hedgeyRate_,
        uint256 hedgeyPeriod_
    ) public virtual override initializer {
        __Ownable_init(owner_);
        __DeploymentBlockV1_init();

        WarrantStorage storage $ = _getWarrantStorage();
        $.investor = investor_;
        $.token = token_;
        $.tokenAmount = tokenAmount_;
        $.tokenPrice = tokenPrice_;
        $.feeReceiver = feeReceiver_;
        $.expiration = expiration_;
        $.hedgeyCliff = hedgeyCliff_;
        $.hedgeyRate = hedgeyRate_;
        $.hedgeyPeriod = hedgeyPeriod_;
    }

    // ======================================================================
    // IWarrantV1
    // ======================================================================

    // --- Pure Functions ---

    // --- View Functions ---


    /**
     * @inheritdoc IWarrantV1
     */
    function investor()
        public
        view
        virtual
        override
        returns (address)
    {
        WarrantStorage storage $ = _getWarrantStorage();
        return $.investor;
    }

    /**
     * @inheritdoc IWarrantV1
     */
    function token() public view virtual override returns (address) {
        WarrantStorage storage $ = _getWarrantStorage();
        return $.token;
    }

    /**
     * @inheritdoc IWarrantV1
     */
    function tokenAmount()
        public
        view
        virtual
        override
        returns (uint256)
    {
        WarrantStorage storage $ = _getWarrantStorage();
        return $.tokenAmount;
    }

    /**
     * @inheritdoc IWarrantV1
     */
    function tokenPrice()
        public
        view
        virtual
        override
        returns (uint256)
    {
        WarrantStorage storage $ = _getWarrantStorage();
        return $.tokenPrice;
    }

    /**
     * @inheritdoc IWarrantV1
     */
    function feeReceiver() public view virtual override returns (address) {
        WarrantStorage storage $ = _getWarrantStorage();
        return $.feeReceiver;
    }

    /**
     * @inheritdoc IWarrantV1
     */
    function expiration()
        public
        view
        virtual
        override
        returns (uint256)
    {
        WarrantStorage storage $ = _getWarrantStorage();
        return $.expiration;
    }

    /**
     * @inheritdoc IWarrantV1
     */
    function hedgeyCliff() public view virtual override returns (uint256) {
        WarrantStorage storage $ = _getWarrantStorage();
        return $.hedgeyCliff;
    }

    /**
     * @inheritdoc IWarrantV1
     */
    function hedgeyRate() public view virtual override returns (uint256) {
        WarrantStorage storage $ = _getWarrantStorage();
        return $.hedgeyRate;
    }

    /**
     * @inheritdoc IWarrantV1
     */
    function hedgeyPeriod() public view virtual override returns (uint256) {
        WarrantStorage storage $ = _getWarrantStorage();
        return $.hedgeyPeriod;
    }

    // --- State-Changing Functions ---



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
     * @dev Supports IWarrantV1, IVersion, IDeploymentBlockV1, and IERC165
     */
    function supportsInterface(
        bytes4 interfaceId_
    ) public view virtual override returns (bool) {
        return
            interfaceId_ == type(IWarrantV1).interfaceId ||
            interfaceId_ == type(IVersion).interfaceId ||
            interfaceId_ == type(IDeploymentBlockV1).interfaceId ||
            super.supportsInterface(interfaceId_);
    }
}