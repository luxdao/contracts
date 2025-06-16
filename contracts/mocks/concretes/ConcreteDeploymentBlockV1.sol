// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {DeploymentBlockV1} from "../../DeploymentBlockV1.sol";

contract ConcreteDeploymentBlockV1 is DeploymentBlockV1 {
    constructor() {
        _disableInitializers();
    }

    function initialize() external initializer {
        __DeploymentBlockV1_init();
    }
}
