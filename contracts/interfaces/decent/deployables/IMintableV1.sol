// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.28;

interface IMintableV1 {
    function mint(address to, uint256 amount) external;
}
