// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IDeploymentBlockV1 {
    // --- View Functions ---

    function deploymentBlock() external view returns (uint256 blockNumber);
}
