// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.28;

import {HatsProposalCreationWhitelistV1} from "../../../../deployables/strategies/HatsProposalCreationWhitelistV1.sol";

/**
 * A concrete implementation of HatsProposalCreationWhitelistV1 for testing purposes.
 */
contract ConcreteHatsProposalCreationWhitelistV1 is
    HatsProposalCreationWhitelistV1
{
    /**
     * Initializes the concrete Hats whitelist contract.
     * @param _hatsContract Address of the Hats contract
     * @param _initialWhitelistedHats Array of initial whitelisted Hat IDs
     */
    function initialize(
        address _hatsContract,
        uint256[] memory _initialWhitelistedHats
    ) public override initializer {
        __Ownable_init(msg.sender);
        super.initialize(_hatsContract, _initialWhitelistedHats);
    }
}
