// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.28;

import {ERC4337VoterSupportV1} from "../../../../deployables/strategies/ERC4337VoterSupportV1.sol";

/**
 * A concrete implementation of ERC4337VoterSupportV1 for testing purposes.
 */
contract ConcreteERC4337VoterSupportV1 is ERC4337VoterSupportV1 {
    /**
     * A public function that exposes the _voter function for testing.
     */
    function voter(address msgSender) public view returns (address) {
        return _voter(msgSender);
    }

    /**
     * Implementation of the getVersion function.
     */
    function getVersion() external pure override returns (uint16) {
        return 1;
    }
}
