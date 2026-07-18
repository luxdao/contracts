// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

/// @dev Minimal ERC-1155 for work-market v2 escrow/bounty tests.
contract MockERC1155 is ERC1155 {
    constructor() ERC1155("https://mock.uri/{id}.json") {}

    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }
}
