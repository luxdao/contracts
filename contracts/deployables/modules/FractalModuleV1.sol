// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Version} from "../Version.sol";
import {IFractalModuleV1} from "../../interfaces/decent/deployables/IFractalModuleV1.sol";
import {GuardableModule, Enum} from "@gnosis-guild/zodiac/contracts/core/GuardableModule.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

contract FractalModuleV1 is
    IFractalModuleV1,
    GuardableModule,
    Ownable2StepUpgradeable,
    Version,
    UUPSUpgradeable
{
    uint16 private constant VERSION = 1;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address avatar_,
        address target_
    ) public virtual override initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();

        setAvatar(avatar_);
        setTarget(target_);

        OwnableUpgradeable.transferOwnership(owner_);
    }

    function setUp(
        bytes memory initializeParams
    ) public virtual override initializer {
        (address _owner, address _avatar, address _target) = abi.decode(
            initializeParams,
            (address, address, address)
        );
        initialize(_owner, _avatar, _target);
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal virtual override onlyOwner {}

    function execTx(
        address _target,
        uint256 _value,
        bytes memory _data,
        Enum.Operation _operation
    ) public virtual override onlyOwner {
        if (!exec(_target, _value, _data, _operation)) revert TxFailed();
    }

    function getVersion() public view virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(IFractalModuleV1).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    function _transferOwnership(
        address newOwner
    ) internal virtual override(Ownable2StepUpgradeable, OwnableUpgradeable) {
        Ownable2StepUpgradeable._transferOwnership(newOwner);
    }

    function transferOwnership(
        address newOwner
    )
        public
        virtual
        override(Ownable2StepUpgradeable, OwnableUpgradeable)
        onlyOwner
    {
        Ownable2StepUpgradeable.transferOwnership(newOwner);
    }
}
