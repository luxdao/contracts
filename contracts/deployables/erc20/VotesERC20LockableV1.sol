// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IVotesERC20LockableV1} from "../../interfaces/decent/deployables/IVotesERC20LockableV1.sol";
import {IVotesERC20V1} from "../../interfaces/decent/deployables/IVotesERC20V1.sol";
import {VotesERC20V1} from "./VotesERC20V1.sol";
import {Version} from "../Version.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

contract VotesERC20LockableV1 is
    IVotesERC20LockableV1,
    ERC165,
    AccessControlUpgradeable,
    VotesERC20V1
{
    uint16 private constant VERSION = 1;

    bool internal _locked;
    uint256 internal _maxTotalSupply;

    bytes32 public constant TRANSFER_ROLE = keccak256("TRANSFER_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    constructor() {
        _disableInitializers();
    }

    modifier isTransferable(address from, address to) {
        if (
            _locked &&
            // overrides while locked
            !hasRole(TRANSFER_ROLE, from) && // whitelisted addresses can always transfer
            to != address(0) // can always burn when locked
        ) {
            revert IsLocked();
        }
        _;
    }

    function initialize(
        address owner_,
        bool locked_,
        uint256 maxTotalSupply_,
        string memory name_,
        string memory symbol_,
        Allocation[] memory allocations_
    ) public virtual override initializer {
        super.initialize(name_, symbol_, allocations_, owner_);
        __ERC165_init();
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, owner_);
        _grantRole(MINTER_ROLE, owner_);
        // owner can always transfer
        _grantRole(TRANSFER_ROLE, owner_);
        // can always mint when locked
        _grantRole(TRANSFER_ROLE, address(0));
        _locked = locked_;
        _maxTotalSupply = maxTotalSupply_;
    }

    function locked() external view virtual override returns (bool) {
        return _locked;
    }

    function maxTotalSupply() external view override returns (uint256) {
        return _maxTotalSupply;
    }

    function lock(bool locked_) external virtual override onlyOwner {
        _locked = locked_;
        emit Locked(_locked);
    }

    function setMaxTotalSupply(
        uint256 newMaxTotalSupply
    ) external virtual override onlyOwner {
        if (newMaxTotalSupply < totalSupply()) {
            revert InvalidMaxTotalSupply();
        }
        _maxTotalSupply = newMaxTotalSupply;
        emit MaxTotalSupplyUpdated(newMaxTotalSupply);
    }

    function mint(
        address to,
        uint256 amount
    ) external virtual override onlyRole(MINTER_ROLE) {
        uint256 newTotalSupply = totalSupply() + amount;
        if (newTotalSupply > _maxTotalSupply) {
            revert ExceedMaxTotalSupply();
        }
        _mint(to, amount);
    }

    function burn(uint256 amount) external virtual override {
        _burn(msg.sender, amount);
    }

    function _update(
        address from,
        address to,
        uint256 amount
    ) internal virtual override isTransferable(from, to) {
        super._update(from, to, amount);
    }

    function version() public view virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId
    )
        public
        view
        virtual
        override(ERC165, AccessControlUpgradeable, VotesERC20V1)
        returns (bool)
    {
        return
            interfaceId == type(IVotesERC20LockableV1).interfaceId ||
            interfaceId == type(IAccessControl).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    function CLOCK_MODE()
        public
        pure
        virtual
        override(VotesERC20V1, IVotesERC20V1)
        returns (string memory)
    {
        return "mode=timestamp";
    }

    function clock()
        public
        view
        virtual
        override(VotesERC20V1, IVotesERC20V1)
        returns (uint48)
    {
        return uint48(block.timestamp);
    }
}
