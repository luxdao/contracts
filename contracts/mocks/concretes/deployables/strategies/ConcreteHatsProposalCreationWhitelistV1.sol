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
     * Sets up the concrete Hats whitelist contract.
     * @param initializeParams ABI encoded parameters (address _hatsContract, uint256[] _initialWhitelistedHats)
     */
    function setUp(bytes memory initializeParams) public override initializer {
        __Ownable_init(msg.sender);
        super.setUp(initializeParams);
    }
}
