// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IVersion {
    // --- Pure Functions ---

    function version() external pure returns (uint16 version);
}
