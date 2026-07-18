// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev ERC-20 that reverts any transfer touching a blocked address — models USDC/USDT-style
/// blocklists/pausability that pass the inbound deposit check yet REVERT on transfer-OUT to a
/// blocked recipient. Used to prove the escrow credits (never bricks) on a failed outward transfer.
contract MockBlocklistERC20 is ERC20 {
    mapping(address account => bool blocked) public blocked;

    constructor() ERC20("Blocklist", "BLK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address account, bool value) external {
        blocked[account] = value;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[from] && !blocked[to], "MockBlocklistERC20: blocked");
        super._update(from, to, value);
    }
}
