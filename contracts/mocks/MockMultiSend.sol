// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IMultisend} from "../interfaces/safe/IMultiSend.sol";

contract MockMultisend is IMultisend {
    bool revertCall;

    function setRevertCall(bool revertCall_) external {
        revertCall = revertCall_;
    }

    function multiSend(bytes memory) external payable {
        if (revertCall) {
            revert();
        }
    }
}