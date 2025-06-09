// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Version} from "../Version.sol";
import {IVersion} from "../../interfaces/decent/deployables/IVersion.sol";
import {IAzoriusFreezeGuardV1} from "../../interfaces/decent/deployables/IAzoriusFreezeGuardV1.sol";
import {IBaseFreezeVotingV1} from "../../interfaces/decent/deployables/IBaseFreezeVotingV1.sol";
import {IBaseFreezeGuardV1} from "../../interfaces/decent/deployables/IBaseFreezeGuardV1.sol";
import {Enum} from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";
import {IGuard} from "@gnosis-guild/zodiac/contracts/interfaces/IGuard.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

contract AzoriusFreezeGuardV1 is
    IAzoriusFreezeGuardV1,
    ERC165,
    Version,
    Ownable2StepUpgradeable,
    UUPSUpgradeable
{
    uint16 private constant VERSION = 1;

    IBaseFreezeVotingV1 internal _freezeVoting;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address freezeVoting_
    ) public virtual override initializer {
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        _freezeVoting = IBaseFreezeVotingV1(freezeVoting_);
    }

    function _authorizeUpgrade(
        address newImplementation_
    ) internal virtual override onlyOwner {}

    function freezeVoting() external view virtual override returns (address) {
        return address(_freezeVoting);
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
    ) external view virtual override {
        if (_freezeVoting.isFrozen()) revert DAOFrozen();
    }

    function checkAfterExecution(
        bytes32,
        bool
    ) external view virtual override {}

    function version() public view virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId_
    ) public view virtual override returns (bool) {
        return
            interfaceId_ == type(IAzoriusFreezeGuardV1).interfaceId ||
            interfaceId_ == type(IBaseFreezeGuardV1).interfaceId ||
            interfaceId_ == type(IGuard).interfaceId ||
            interfaceId_ == type(IVersion).interfaceId ||
            super.supportsInterface(interfaceId_);
    }
}
