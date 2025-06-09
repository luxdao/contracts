// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {ISablierV2Lockup} from "../../sablier/ISablierV2Lockup.sol";

interface IDecentSablierStreamManagementModule {
    // --- State-Changing Functions ---

    function withdrawMaxFromStream(
        ISablierV2Lockup sablier_,
        address recipientHatAccount_,
        uint256 streamId_,
        address to_
    ) external;

    function cancelStream(
        ISablierV2Lockup sablier_,
        uint256 streamId_
    ) external;
}
