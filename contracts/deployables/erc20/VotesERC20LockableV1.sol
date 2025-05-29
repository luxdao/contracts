// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {ILockableV1} from "../../interfaces/decent/deployables/ILockableV1.sol";
import {IMintableV1} from "../../interfaces/decent/deployables/IMintableV1.sol";
import {VotesERC20V1} from "./VotesERC20V1.sol";
import {Version} from "../Version.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

contract VotesERC20LockableV1 is ILockableV1, IMintableV1, VotesERC20V1 {
    uint16 private constant VERSION = 1;

    bool public locked;
    mapping(address => bool) public whitelisted;

    constructor() {
        _disableInitializers();
    }

    modifier isTransferable(address from) {
        if (
            locked &&
            // overrides while locked
            !(from == owner() || // owner can always transfer
                whitelisted[from] || // whitelisted addresses can always transfer
                from == address(0)) // can always mint when locked
        ) {
            revert IsLocked();
        }
        _;
    }

    function initialize(
        address _owner,
        bool _locked,
        string memory _name,
        string memory _symbol,
        address[] memory _allocationAddresses,
        uint256[] memory _allocationAmounts
    ) public virtual initializer {
        super.initialize(
            _name,
            _symbol,
            _allocationAddresses,
            _allocationAmounts,
            _owner
        );
        locked = _locked;
    }

    function lock(bool _locked) external virtual onlyOwner {
        if (_locked == locked) {
            revert CannotSwitchLockState(_locked);
        }
        locked = _locked;
        emit Locked(_locked);
    }

    function whitelist(
        address account,
        bool isWhitelisted
    ) external virtual onlyOwner {
        bool currentlyWhitelisted = whitelisted[account];
        whitelisted[account] = isWhitelisted;
        if (currentlyWhitelisted != isWhitelisted) {
            emit Whitelisted(account, isWhitelisted);
        }
    }

    function mint(address to, uint256 amount) external virtual onlyOwner {
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
            interfaceId == type(ILockableV1).interfaceId ||
            interfaceId == type(IMintableV1).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
