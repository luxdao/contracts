// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IBaseVotingAdapterV1} from "../../../interfaces/decent/deployables/IBaseVotingAdapterV1.sol";
import {IStrategyV1} from "../../../interfaces/decent/deployables/IStrategyV1.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

abstract contract BaseVotingAdapterV1 is IBaseVotingAdapterV1, Initializable {
    IStrategyV1 internal _strategy;

    modifier onlyStrategy() {
        if (msg.sender != address(_strategy)) revert NotStrategy();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function __BaseVotingAdapterV1_init(
        address strategy_
    ) internal onlyInitializing {
        _strategy = IStrategyV1(strategy_);
    }

    function strategy() external view virtual override returns (address) {
        return address(_strategy);
    }

    function recordVote(
        address _voter,
        uint32 _proposalId,
        bytes calldata _votingAdapterVoteData
    ) external virtual override returns (uint256 weightCasted);

    function weightOf(
        address _voter,
        uint32 _proposalId,
        bytes calldata _votingAdapterVoteData
    ) external view virtual override returns (uint256 weight);
}
