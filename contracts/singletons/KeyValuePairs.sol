// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IKeyValuePairs} from "../interfaces/decent/singletons/IKeyValuePairs.sol";

contract KeyValuePairs is IKeyValuePairs {
    // ======================================================================
    // IKeyValuePairs
    // ======================================================================

    // --- State-Changing Functions ---

    function updateValues(KeyValuePair[] memory keyValuePairs_) external {
        for (uint256 i; i < keyValuePairs_.length; ) {
            KeyValuePair memory keyValuePair = keyValuePairs_[i];

            emit ValueUpdated(msg.sender, keyValuePair.key, keyValuePair.value);

            unchecked {
                ++i;
            }
        }
    }
}
