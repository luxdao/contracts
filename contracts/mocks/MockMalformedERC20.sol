// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev ERC-20 whose `transfer` MOVES the tokens but returns a malformed 32-byte word (value 2,
/// not 0/1) — the exact shape a strict `abi.decode(ret, (bool))` reverts on. Used to prove the
/// escrow's balance-delta success check neither bricks the settlement (M-1) nor double-pays (the
/// tokens actually moved, so it is recorded delivered, not credited).
contract MockMalformedERC20 is ERC20 {
    constructor() ERC20("Malformed", "MAL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        _transfer(_msgSender(), to, value); // actually move the tokens
        // Return a non-standard truthy word (2) — a strict abi.decode(bool) would revert here.
        assembly {
            mstore(0x00, 2)
            return(0x00, 0x20)
        }
    }
}
