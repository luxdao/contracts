// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.28;

import {BaseQuorumPercentV1} from "../../../../deployables/strategies/BaseQuorumPercentV1.sol";

/**
 * A concrete implementation of BaseQuorumPercentV1 for testing purposes.
 */
contract ConcreteBaseQuorumPercentV1 is BaseQuorumPercentV1 {
    constructor() {
        _disableInitializers();
    }

    /**
     * Sets up the concrete quorum contract.
     * @param initializeParams ABI encoded parameters (address _owner, uint256 _quorumNumerator)
     */
    function setUp(bytes memory initializeParams) public initializer {
        (address _owner, uint256 _quorumNumerator) = abi.decode(
            initializeParams,
            (address, uint256)
        );

        __Ownable_init(_owner);
        _updateQuorumNumerator(_quorumNumerator);
    }

    /**
     * Concrete implementation of the abstract quorumVotes function.
     * Returns fixed total supply * quorumNumerator / QUORUM_DENOMINATOR.
     */
    function quorumVotes(uint32) public view override returns (uint256) {
        uint256 totalSupply = 1000000; // Concrete fixed total supply
        return (totalSupply * quorumNumerator) / QUORUM_DENOMINATOR;
    }

    /**
     * Concrete implementation of the abstract getVersion function.
     */
    function getVersion() external pure override returns (uint16) {
        return 1;
    }
}
