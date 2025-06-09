// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IDecentSablierStreamManagementModule} from "../interfaces/decent/utilities/IDecentSablierStreamManagementModule.sol";
import {Lockup} from "../interfaces/sablier/types/DataTypes.sol";
import {ISablierV2Lockup} from "../interfaces/sablier/ISablierV2Lockup.sol";
import {Enum} from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";
import {IAvatar} from "@gnosis-guild/zodiac/contracts/interfaces/IAvatar.sol";

contract DecentSablierStreamManagementModule is
    IDecentSablierStreamManagementModule
{
    // ======================================================================
    // IDecentSablierStreamManagementModule
    // ======================================================================

    // --- State-Changing Functions ---

    function withdrawMaxFromStream(
        ISablierV2Lockup sablier_,
        address recipientHatAccount_,
        uint256 streamId_,
        address to_
    ) public virtual override {
        // Check if there are funds to withdraw
        if (sablier_.withdrawableAmountOf(streamId_) == 0) {
            return;
        }

        // Proxy the Sablier withdrawMax call through IAvatar (Safe)
        IAvatar(msg.sender).execTransactionFromModule(
            recipientHatAccount_,
            0,
            abi.encodeWithSignature(
                "execute(address,uint256,bytes,uint8)",
                address(sablier_),
                0,
                abi.encodeWithSignature(
                    "withdrawMax(uint256,address)",
                    streamId_,
                    to_
                ),
                0
            ),
            Enum.Operation.Call
        );
    }

    function cancelStream(
        ISablierV2Lockup sablier_,
        uint256 streamId_
    ) public virtual override {
        // Check if the stream can be cancelled
        Lockup.Status streamStatus = sablier_.statusOf(streamId_);
        if (
            streamStatus != Lockup.Status.PENDING &&
            streamStatus != Lockup.Status.STREAMING
        ) {
            return;
        }

        IAvatar(msg.sender).execTransactionFromModule(
            address(sablier_),
            0,
            abi.encodeWithSignature("cancel(uint256)", streamId_),
            Enum.Operation.Call
        );
    }
}
