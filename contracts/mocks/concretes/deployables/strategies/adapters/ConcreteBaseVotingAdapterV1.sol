// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {BaseVotingAdapterV1} from "../../../../../deployables/strategies/adapters/BaseVotingAdapterV1.sol";
import {IStrategyV1} from "../../../../../interfaces/decent/deployables/IStrategyV1.sol";

contract ConcreteBaseVotingAdapterV1 is BaseVotingAdapterV1 {
    constructor() {
        _disableInitializers();
    }

    function initialize(address strategy_) external initializer {
        __BaseVotingAdapterV1_init(strategy_);
    }

    // Implement IBaseVotingAdapterV1 functions
    function recordVote(
        address /*_voter*/,
        uint32 /*_proposalId*/,
        bytes calldata /*_votingAdapterVoteData*/
    ) external virtual override onlyStrategy returns (uint256 weightCasted) {
        return 123; // Dummy weight
    }

    function weightOf(
        address /*_voter*/,
        uint32 /*_proposalId*/,
        bytes calldata /*_votingAdapterVoteData*/
    ) external view virtual override returns (uint256 weight) {}
}
