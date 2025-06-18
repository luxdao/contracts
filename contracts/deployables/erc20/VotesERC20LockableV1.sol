// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IVotesERC20LockableV1} from "../../interfaces/decent/deployables/IVotesERC20LockableV1.sol";
import {IVotesERC20V1} from "../../interfaces/decent/deployables/IVotesERC20V1.sol";
import {VotesERC20V1} from "./VotesERC20V1.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

contract VotesERC20LockableV1 is
    IVotesERC20LockableV1,
    ERC165,
    AccessControlUpgradeable,
    VotesERC20V1
{
    // ======================================================================
    // STATE VARIABLES
    // ======================================================================

    /// @custom:storage-location erc7201:Decent.VotesERC20Lockable.main
    struct VotesERC20LockableStorage {
        bool locked;
        uint256 maxTotalSupply;
        uint48 unlockTime;
    }

    // EIP-7201: keccak256(abi.encode(uint256(keccak256("Decent.VotesERC20Lockable.main")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant VOTES_ERC20_LOCKABLE_STORAGE_LOCATION =
        0x92ca3baf4d957868103ca789b850a5c1ad32aca3d4ea82a1a77d487427517900;

    function _getVotesERC20LockableStorage()
        internal
        pure
        returns (VotesERC20LockableStorage storage $)
    {
        assembly {
            $.slot := VOTES_ERC20_LOCKABLE_STORAGE_LOCATION
        }
    }

    bytes32 public constant TRANSFER_FROM_ROLE =
        keccak256("TRANSFER_FROM_ROLE");
    bytes32 public constant TRANSFER_TO_ROLE = keccak256("TRANSFER_TO_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    // ======================================================================
    // MODIFIERS
    // ======================================================================

    modifier isTransferable(address from_, address to_) {
        VotesERC20LockableStorage storage $ = _getVotesERC20LockableStorage();
        if (
            $.locked &&
            // overrides while locked
            !hasRole(TRANSFER_FROM_ROLE, from_) && // whitelisted addresses can always transfer
            !hasRole(TRANSFER_TO_ROLE, to_)
        ) {
            revert IsLocked();
        }
        _;
    }

    // ======================================================================
    // CONSTRUCTOR & INITIALIZERS
    // ======================================================================

    constructor() {
        _disableInitializers();
    }

    function initialize(
        Metadata calldata metadata_,
        Allocation[] calldata allocations_,
        address owner_,
        bool locked_,
        uint256 maxTotalSupply_
    ) public virtual override initializer {
        super.initialize(metadata_, allocations_, owner_);
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, owner_);
        _grantRole(MINTER_ROLE, owner_);

        // owner can always transfer
        _grantRole(TRANSFER_FROM_ROLE, owner_);

        // can always mint when locked
        _grantRole(TRANSFER_FROM_ROLE, address(0));

        // can always burn when locked
        _grantRole(TRANSFER_TO_ROLE, address(0));

        VotesERC20LockableStorage storage $ = _getVotesERC20LockableStorage();
        $.locked = locked_;
        $.maxTotalSupply = maxTotalSupply_;
    }

    // ======================================================================
    // IVotesERC20LockableV1
    // ======================================================================

    // --- View Functions ---

    function locked() public view virtual override returns (bool) {
        VotesERC20LockableStorage storage $ = _getVotesERC20LockableStorage();
        return $.locked;
    }

    function maxTotalSupply() public view virtual override returns (uint256) {
        VotesERC20LockableStorage storage $ = _getVotesERC20LockableStorage();
        return $.maxTotalSupply;
    }

    function getUnlockTime() public view virtual override returns (uint48) {
        VotesERC20LockableStorage storage $ = _getVotesERC20LockableStorage();
        return $.unlockTime;
    }

    // --- State-Changing Functions ---

    function lock(
        bool locked_
    ) public virtual override onlyRole(DEFAULT_ADMIN_ROLE) {
        VotesERC20LockableStorage storage $ = _getVotesERC20LockableStorage();
        if (!locked_) {
            $.unlockTime = uint48(block.timestamp);
        }
        $.locked = locked_;
        emit Locked(locked_);
    }

    function setMaxTotalSupply(
        uint256 newMaxTotalSupply_
    ) public virtual override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMaxTotalSupply_ < totalSupply()) {
            revert InvalidMaxTotalSupply();
        }

        VotesERC20LockableStorage storage $ = _getVotesERC20LockableStorage();
        $.maxTotalSupply = newMaxTotalSupply_;
        emit MaxTotalSupplyUpdated(newMaxTotalSupply_);
    }

    function mint(
        address to_,
        uint256 amount_
    ) public virtual override onlyRole(MINTER_ROLE) {
        uint256 newTotalSupply = totalSupply() + amount_;

        VotesERC20LockableStorage storage $ = _getVotesERC20LockableStorage();
        if (newTotalSupply > $.maxTotalSupply) {
            revert ExceedMaxTotalSupply();
        }

        _mint(to_, amount_);
    }

    function burn(uint256 amount_) public virtual override {
        _burn(msg.sender, amount_);
    }

    // ======================================================================
    // VotesERC20V1
    // ======================================================================

    // --- Pure Functions ---

    function CLOCK_MODE()
        public
        pure
        virtual
        override(VotesERC20V1, IVotesERC20V1)
        returns (string memory)
    {
        return "mode=timestamp";
    }

    // --- View Functions ---

    function clock()
        public
        view
        virtual
        override(VotesERC20V1, IVotesERC20V1)
        returns (uint48)
    {
        return uint48(block.timestamp);
    }

    // --- Internal Functions ---

    function _update(
        address from_,
        address to_,
        uint256 amount_
    ) internal virtual override isTransferable(from_, to_) {
        super._update(from_, to_, amount_);
    }

    // ======================================================================
    // IVersion
    // ======================================================================

    // --- Pure Functions ---

    function version() public pure virtual override returns (uint16) {
        return 1;
    }

    // ======================================================================
    // ERC165
    // ======================================================================

    // --- View Functions ---

    function supportsInterface(
        bytes4 interfaceId_
    )
        public
        view
        virtual
        override(ERC165, AccessControlUpgradeable, VotesERC20V1)
        returns (bool)
    {
        return
            interfaceId_ == type(IVotesERC20LockableV1).interfaceId ||
            interfaceId_ == type(IAccessControl).interfaceId ||
            super.supportsInterface(interfaceId_);
    }
}
