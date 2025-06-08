// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IFractalModuleV1} from "../../interfaces/decent/deployables/IFractalModuleV1.sol";
import {IVersion} from "../../interfaces/decent/deployables/IVersion.sol";
import {Transaction} from "../../interfaces/decent/Module.sol";
import {GuardableModule, Enum} from "@gnosis-guild/zodiac/contracts/core/GuardableModule.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

contract FractalModuleV1 is
    IFractalModuleV1,
    IVersion,
    GuardableModule,
    Ownable2StepUpgradeable,
    UUPSUpgradeable,
    ERC165
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

        _transferOwnership(owner_);
    }

    function setUp(
        bytes memory initializeParams_
    ) public virtual override initializer {
        (address owner_, address avatar_, address target_) = abi.decode(
            initializeParams_,
            (address, address, address)
        );
        initialize(owner_, avatar_, target_);
    }

    function _authorizeUpgrade(
        address newImplementation_
    ) internal virtual override onlyOwner {}

    function execTx(
        Transaction calldata transaction_
    ) public virtual override onlyOwner {
        if (
            !exec(
                transaction_.to,
                transaction_.value,
                transaction_.data,
                transaction_.operation
            )
        ) revert TxFailed();
    }

    function version() external view virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId_
    ) public view virtual override returns (bool) {
        return
            interfaceId_ == type(IFractalModuleV1).interfaceId ||
            interfaceId_ == type(IVersion).interfaceId ||
            super.supportsInterface(interfaceId_);
    }

    function _transferOwnership(
        address newOwner_
    ) internal virtual override(Ownable2StepUpgradeable, OwnableUpgradeable) {
        Ownable2StepUpgradeable._transferOwnership(newOwner_);
    }

    function transferOwnership(
        address newOwner_
    )
        public
        virtual
        override(Ownable2StepUpgradeable, OwnableUpgradeable)
        onlyOwner
    {
        Ownable2StepUpgradeable.transferOwnership(newOwner_);
    }
}
