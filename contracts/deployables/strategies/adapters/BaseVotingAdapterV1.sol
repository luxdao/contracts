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

    modifier onlyAuthorizedFreezeVoter() {
        if (!IStrategyV1(_strategy).isAuthorizedFreezeVoter(msg.sender)) {
            revert UnauthorizedFreezeVoter(msg.sender);
        }
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
}
