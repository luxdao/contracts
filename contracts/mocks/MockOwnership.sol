// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IOwnershipV1} from "../interfaces/decent/deployables/IOwnershipV1.sol";

// Minimal interface for the voting strategy contract that MockOwnership will call
interface IVotingStrategy {
    function vote(uint32 proposalId, uint8 voteType) external;
}

/**
 * A mock contract implementing IOwnershipV1 for testing purposes.
 * Includes a method to call an external vote function.
 */
contract MockOwnership is IOwnershipV1 {
    address private _owner;

    constructor(address initialOwner) {
        _owner = initialOwner;
    }

    /**
     * Returns the owner of this contract.
     */
    function owner() external view override returns (address) {
        return _owner;
    }

    /**
     * Updates the owner address for testing.
     * Note: In a real Ownable contract, this would be restricted.
     */
    function setOwner(address newOwner) external {
        _owner = newOwner;
    }

    /**
     * Allows this contract to call the vote function on an external strategy contract.
     * The msg.sender to the strategy's vote() will be this MockOwnership contract.
     */
    function callExternalVote(
        address strategyAddress,
        uint32 proposalId,
        uint8 voteType
    ) external {
        IVotingStrategy(strategyAddress).vote(proposalId, voteType);
    }
}
