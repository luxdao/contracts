// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IBurnableV1 {
    function burn(address account, uint256 amount) external;
}
