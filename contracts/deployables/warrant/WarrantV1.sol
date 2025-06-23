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
import {IVotingTokenLockupPlans} from "../../interfaces/hedgey/IVotingTokenLockupPlans.sol";
import {IVotesERC20V1} from "../../interfaces/decent/deployables/IVotesERC20V1.sol";

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
        bool relativeTime;
        address recipient;
        address token;
        bytes tokenInitData;
        address feeToken;
        uint256 tokenAmount;
        uint256 tokenPrice;
        address feeReceiver;
        uint256 expiration;
        address hedgeyTokenLockupPlans;
        uint256 hedgeyStart;
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

    /** @notice Precision for token price calculations (18 decimals) */
    uint256 internal constant PRECISION = 10 ** 18;

    // ======================================================================
    // CONSTRUCTOR & INITIALIZERS
    // ======================================================================


    constructor() {
        _disableInitializers();
    }

    function initialize(
        bool relativeTime_,
        address owner_,
        address recipient_,
        address token_,
        bytes memory tokenInitData_,
        address feeToken_,
        uint256 tokenAmount_,
        uint256 tokenPrice_,
        address feeReceiver_,
        uint256 expiration_,
        address hedgeyTokenLockupPlans_,
        uint256 hedgeyStart_,
        uint256 hedgeyCliff_,
        uint256 hedgeyRate_,
        uint256 hedgeyPeriod_
    ) public virtual override initializer {
        __Ownable_init(owner_);
        __DeploymentBlockV1_init();

        if (relativeTime_) {
            // TODO: verify token is a valid instance of our VotesERC20V1
        }

        // TODO: any validation on hedgeyStart_ if time is absolute?

        WarrantStorage storage $ = _getWarrantStorage();
        $.relativeTime = relativeTime_;
        $.recipient = recipient_;
        $.token = token_;
        $.tokenInitData = tokenInitData_;
        $.feeToken = feeToken_;
        $.tokenAmount = tokenAmount_;
        $.tokenPrice = tokenPrice_;
        $.feeReceiver = feeReceiver_;
        $.expiration = expiration_;
        $.hedgeyTokenLockupPlans = hedgeyTokenLockupPlans_;
        $.hedgeyStart = hedgeyStart_;
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
    function relativeTime() public view virtual override returns (bool) {
        WarrantStorage storage $ = _getWarrantStorage();
        return $.relativeTime;
    }

    /**
     * @inheritdoc IWarrantV1
     */
    function recipient()
        public
        view
        virtual
        override
        returns (address)
    {
        WarrantStorage storage $ = _getWarrantStorage();
        return $.recipient;
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
    function tokenInitData() public view virtual override returns (bytes memory) {
        WarrantStorage storage $ = _getWarrantStorage();
        return $.tokenInitData;
    }

    /**
     * @inheritdoc IWarrantV1
     */
    function feeToken() public view virtual override returns (address) {
        WarrantStorage storage $ = _getWarrantStorage();
        return $.feeToken;
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
    function hedgeyTokenLockupPlans() public view virtual override returns (address) {
        WarrantStorage storage $ = _getWarrantStorage();
        return $.hedgeyTokenLockupPlans;
    }

    /**
     * @inheritdoc IWarrantV1
     */
    function hedgeyStart() public view virtual override returns (uint256) {
        WarrantStorage storage $ = _getWarrantStorage();
        return $.hedgeyStart;
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

    function execute(address recipient_) public virtual override {
        WarrantStorage storage $ = _getWarrantStorage();
        if (msg.sender != $.recipient) revert InvalidInvestor();
        if (recipient_ == address(0)) revert AddressZero();
        if (block.timestamp > $.expiration) revert Expired();

        uint256 startTime;
        if ($.relativeTime) {
            if (IVotesERC20V1($.token).locked()) revert TokenLocked();
            startTime = IVotesERC20V1($.token).getUnlockTime();
        } else {
            if (block.timestamp < $.hedgeyStart) revert HedgeyStartNotElapsed();
            startTime = $.hedgeyStart;
        }

        uint256 feeAmount = $.tokenAmount * $.tokenPrice / PRECISION;

        // transfer fee amount from caller to fee receiver
        IERC20($.feeToken).safeTransferFrom(
            msg.sender,
            $.feeReceiver,
            feeAmount
        );

        IERC20($.token).approve(
            $.hedgeyTokenLockupPlans,
            $.tokenAmount
        );

        // TODO: handle this as absolute or relative timestamp
        uint256 hedgeyStartTime = IVotesERC20V1($.token).getUnlockTime();

        // TODO: update this
        uint256 hedgeyLockupCliff = hedgeyStartTime; 

        // function createPlan(
        //     address recipient,
        //     address token,
        //     uint256 amount,
        //     uint256 start,
        //     uint256 cliff,
        //     uint256 rate,
        //     uint256 period

        IVotingTokenLockupPlans($.hedgeyTokenLockupPlans).createPlan(
            recipient_,
            $.token,
            $.tokenAmount,
            hedgeyStartTime,
            hedgeyLockupCliff,
            $.hedgeyRate,
            $.hedgeyPeriod
        );
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