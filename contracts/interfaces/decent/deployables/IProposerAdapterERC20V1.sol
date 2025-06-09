// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IProposerAdapterBaseV1} from "./IProposerAdapterBaseV1.sol";

interface IProposerAdapterERC20V1 is IProposerAdapterBaseV1 {
    function initialize(address token_, uint256 proposerThreshold_) external;

    function token() external view returns (address token);

    function proposerThreshold()
        external
        view
        returns (uint256 proposerThreshold);
}
