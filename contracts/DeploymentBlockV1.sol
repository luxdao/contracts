// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IDeploymentBlockV1} from "./interfaces/decent/IDeploymentBlockV1.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

abstract contract DeploymentBlockV1 is Initializable, IDeploymentBlockV1 {
    // ======================================================================
    // STATE VARIABLES
    // ======================================================================

    uint256 internal _deploymentBlock;

    // ======================================================================
    // CONSTRUCTOR & INITIALIZERS
    // ======================================================================

    function __DeploymentBlockV1_init() internal onlyInitializing {
        _deploymentBlock = block.number;
    }

    // ======================================================================
    // IDeploymentBlockV1
    // ======================================================================

    // --- View Functions ---

    function deploymentBlock() public view virtual override returns (uint256) {
        return _deploymentBlock;
    }
}
