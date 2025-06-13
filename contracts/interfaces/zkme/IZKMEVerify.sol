// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IZKMEVerify {
    function hasApproved(
        address cooperator,
        address user
    ) external view returns (bool);
}
