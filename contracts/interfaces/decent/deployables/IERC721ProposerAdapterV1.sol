// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IProposerAdapterV1} from "./IProposerAdapterV1.sol";

interface IERC721ProposerAdapterV1 is IProposerAdapterV1 {
    function initialize(address token_, uint256 proposerThreshold_) external;

    function token() external view returns (address token);

    function proposerThreshold()
        external
        view
        returns (uint256 proposerThreshold);
}
