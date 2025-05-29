// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {BaseFreezeGuardV1} from "./BaseFreezeGuardV1.sol";
import {Version} from "../Version.sol";
import {IBaseFreezeVotingV1} from "../../interfaces/decent/deployables/IBaseFreezeVotingV1.sol";
import {Enum} from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";

contract AzoriusFreezeGuardV1 is Version, BaseFreezeGuardV1 {
    uint16 private constant VERSION = 1;

    IBaseFreezeVotingV1 public freezeVoting;

    event AzoriusFreezeGuardSetUp(
        address indexed creator,
        address indexed owner,
        address indexed freezeVoting
    );

    error DAOFrozen();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _owner,
        address _freezeVoting
    ) public initializer {
        __BaseFreezeGuardV1_init(_owner);
        freezeVoting = IBaseFreezeVotingV1(_freezeVoting);

        emit AzoriusFreezeGuardSetUp(msg.sender, _owner, _freezeVoting);
    }

    function checkTransaction(
        address,
        uint256,
        bytes memory,
        Enum.Operation,
        uint256,
        uint256,
        uint256,
        address,
        address payable,
        bytes memory,
        address
    ) external view override(BaseFreezeGuardV1) {
        if (freezeVoting.isFrozen()) revert DAOFrozen();
    }

    function checkAfterExecution(
        bytes32,
        bool
    ) external view override(BaseFreezeGuardV1) {}

    function getVersion() public view virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(BaseFreezeGuardV1, Version) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
