// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev ERC-20 whose `balanceOf` (and `transfer`) REVERT once `broken` is set — models a reward
/// token that becomes hostile/paused AFTER a conformant deposit. Used to prove the escrow's
/// settlement path reads balanceOf via staticcall (R3-M1): a reverting balanceOf must not bubble
/// through release()/accept()/finalize() and lock a delivered worker's stake — it must credit.
/// (`transferFrom`/`balanceOf` work while healthy so the deposit itself succeeds.)
contract MockRevertBalanceOfERC20 is ERC20 {
    bool public broken;

    constructor() ERC20("RevertBalance", "RVB") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBroken(bool value) external {
        broken = value;
    }

    function balanceOf(address account) public view override returns (uint256) {
        require(!broken, "REVERT_BALANCEOF");
        return super.balanceOf(account);
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        require(!broken, "REVERT_TRANSFER");
        return super.transfer(to, value);
    }
}
