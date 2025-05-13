// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {BaseStrategyV1} from "../../../../deployables/strategies/BaseStrategyV1.sol";

/**
 * A concrete implementation of BaseStrategyV1 for testing purposes.
 */
contract ConcreteBaseStrategyV1 is BaseStrategyV1 {
    event ConcreteFunctionCalled();

    /**
     * Sets up the concrete strategy contract.
     * @param _owner The owner of the contract
     * @param _proposalInitializer Address that is allowed to initialize Proposals
     */
    function initialize(
        address _owner,
        address _proposalInitializer
    ) public override initializer {
        BaseStrategyV1.initialize(_owner, _proposalInitializer);

        emit StrategySetUp(_proposalInitializer, _owner);
    }

    /**
     * A concrete function that uses the onlyAzorius modifier for testing.
     */
    function concreteOnlyProposalInitializerFunction()
        external
        onlyProposalInitializer
    {
        emit ConcreteFunctionCalled();
    }

    /**
     * Concrete implementation of the abstract initializeProposal function.
     */
    function initializeProposal(
        bytes memory
    ) external override onlyProposalInitializer {
        emit ConcreteFunctionCalled();
    }

    /**
     * Concrete implementation of the abstract isPassed function.
     */
    function isPassed(uint32) external pure override returns (bool) {
        return true;
    }

    /**
     * Concrete implementation of the abstract isProposer function.
     */
    function isProposer(address) external pure override returns (bool) {
        return true;
    }

    /**
     * Concrete implementation of the abstract votingEndTimestamp function.
     */
    function votingEndTimestamp(
        uint32
    ) external view override returns (uint48) {
        return uint48(block.timestamp) + 100;
    }
}
