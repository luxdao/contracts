// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.28;

import {BaseVotingBasisPercentV1} from "../../../../deployables/strategies/BaseVotingBasisPercentV1.sol";

/**
 * A concrete implementation of BaseVotingBasisPercentV1 for testing purposes.
 */
contract ConcreteBaseVotingBasisPercentV1 is BaseVotingBasisPercentV1 {
    constructor() {
        _disableInitializers();
    }

    /**
     * Sets up the concrete voting basis contract.
     * @param initializeParams ABI encoded parameters (address _owner, uint256 _basisNumerator)
     */
    function setUp(bytes memory initializeParams) public initializer {
        (address _owner, uint256 _basisNumerator) = abi.decode(
            initializeParams,
            (address, uint256)
        );

        __Ownable_init(_owner);
        _updateBasisNumerator(_basisNumerator);
    }
}
