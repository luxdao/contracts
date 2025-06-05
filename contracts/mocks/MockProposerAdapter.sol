// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IProposerAdapterV1} from "../interfaces/decent/deployables/IProposerAdapterV1.sol";

contract MockProposerAdapter is IProposerAdapterV1 {
    mapping(address => bool) private _isProposer;

    function isProposer(
        address _proposer,
        bytes calldata
    ) external view override returns (bool) {
        return _isProposer[_proposer];
    }

    // Mock-specific functions for test setup
    function setProposerStatus(address _proposer, bool status) external {
        _isProposer[_proposer] = status;
    }
}
