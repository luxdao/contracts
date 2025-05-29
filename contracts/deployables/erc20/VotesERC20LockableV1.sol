// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IVotesERC20LockableV1} from "../../interfaces/decent/deployables/IVotesERC20LockableV1.sol";
import {VotesERC20V1} from "./VotesERC20V1.sol";
import {Version} from "../Version.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

contract VotesERC20LockableV1 is IVotesERC20LockableV1, VotesERC20V1 {
    uint16 private constant VERSION = 1;

    bool internal _locked;
    mapping(address => bool) internal _whitelisted;

    constructor() {
        _disableInitializers();
    }

    modifier isTransferable(address from) {
        if (
            _locked &&
            // overrides while locked
            !(from == owner() || // owner can always transfer
                _whitelisted[from] || // whitelisted addresses can always transfer
                from == address(0)) // can always mint when locked
        ) {
            revert IsLocked();
        }
        _;
    }

    function initialize(
        address owner_,
        bool locked_,
        string memory name_,
        string memory symbol_,
        address[] memory allocationAddresses_,
        uint256[] memory allocationAmounts_
    ) public virtual override initializer {
        super.initialize(
            name_,
            symbol_,
            allocationAddresses_,
            allocationAmounts_,
            owner_
        );
        _locked = locked_;
    }

    function locked() external view virtual override returns (bool) {
        return _locked;
    }

    function whitelisted(
        address account
    ) external view virtual override returns (bool) {
        return _whitelisted[account];
    }

    function lock(bool locked_) external virtual override onlyOwner {
        if (locked_ == _locked) {
            revert CannotSwitchLockState(locked_);
        }
        _locked = locked_;
        emit Locked(_locked);
    }

    function whitelist(
        address account,
        bool isWhitelisted
    ) external virtual override onlyOwner {
        bool currentlyWhitelisted = _whitelisted[account];
        _whitelisted[account] = isWhitelisted;
        if (currentlyWhitelisted != isWhitelisted) {
            emit Whitelisted(account, isWhitelisted);
        }
    }

    function mint(
        address to,
        uint256 amount
    ) external virtual override onlyOwner {
        _mint(to, amount);
    }

    function _update(
        address from,
        address to,
        uint256 amount
    ) internal virtual override isTransferable(from) {
        super._update(from, to, amount);
    }

    function getVersion() public view virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(IVotesERC20LockableV1).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
