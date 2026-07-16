// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockFeeOnTransferERC20
 * @notice An ERC-20 that burns a fixed basis-point fee on every (non-mint/non-burn)
 * transfer, so the amount RECEIVED is strictly less than the amount sent. Used to prove
 * EscrowV1 REJECTS non-conforming (fee-on-transfer / deflationary) tokens at deposit
 * rather than silently crediting a short balance and later stranding reward/stake.
 */
contract MockFeeOnTransferERC20 is ERC20 {
    /// @notice Fee taken from each transfer, in basis points (1/100th of a percent).
    uint256 public immutable feeBps;

    constructor(string memory name_, string memory symbol_, uint256 feeBps_) ERC20(name_, symbol_) {
        require(feeBps_ > 0 && feeBps_ < 10_000, "fee out of range");
        feeBps = feeBps_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev Burns `feeBps` of every real transfer so the recipient receives less than sent.
    function _update(address from, address to, uint256 value) internal virtual override {
        if (from == address(0) || to == address(0)) {
            // Mint or burn: no fee.
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * feeBps) / 10_000;
        if (fee > 0) super._update(from, address(0), fee); // burn the fee from `from`
        super._update(from, to, value - fee); // deliver the remainder
    }
}
