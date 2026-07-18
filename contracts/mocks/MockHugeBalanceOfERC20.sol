// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev ERC-20 whose `balanceOf` returns a full, valid 32-byte `type(uint256).max` word (NO revert,
/// NOT short) once `huge` is set, while `transfer` reports success but moves nothing — models a
/// reward token that turns adversarial AFTER a conformant deposit. Because balanceOf neither reverts
/// nor short-returns, it PASSES the escrow's staticcall verifiability guard (okBefore/okAfter both
/// true); returning uint256.max is exactly what makes a naive `balAfter + amount <= balBefore`
/// delivered-check overflow (Panic 0x11) and brick accept()/finalize(), locking a delivered worker's
/// stake (R4-HIGH). Used to prove the subtraction-only, overflow-safe delivered-check CREDITS the
/// undeliverable reward and settles instead of bricking. (`transferFrom`/`balanceOf` are conformant
/// while healthy so the deposit itself succeeds.)
contract MockHugeBalanceOfERC20 is ERC20 {
    bool public huge;

    constructor() ERC20("HugeBalance", "HUGE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setHuge(bool value) external {
        huge = value;
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (huge) return type(uint256).max; // valid 32-byte word, never reverts
        return super.balanceOf(account);
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (huge) return true; // claims success, moves nothing
        return super.transfer(to, value);
    }
}
