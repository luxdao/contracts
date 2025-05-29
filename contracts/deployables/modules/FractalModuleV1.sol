// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Version} from "../Version.sol";
import {IFractalModuleV1} from "../../interfaces/decent/deployables/IFractalModuleV1.sol";
import {GuardableModule, Enum} from "@gnosis-guild/zodiac/contracts/core/GuardableModule.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract FractalModuleV1 is
    IFractalModuleV1,
    GuardableModule,
    Version,
    UUPSUpgradeable
{
    uint16 private constant VERSION = 1;

    error TxFailed();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _owner,
        address _avatar,
        address _target
    ) public initializer {
        // Initializer owner with the msg.sender first,
        // needed for setting the avatar and target, which are ownable functions
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();

        setAvatar(_avatar);
        setTarget(_target);

        // Transfer ownership to the provided owner
        transferOwnership(_owner);
    }

    function setUp(bytes memory initializeParams) public override initializer {
        (address _owner, address _avatar, address _target) = abi.decode(
            initializeParams,
            (address, address, address)
        );
        initialize(_owner, _avatar, _target);
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal virtual override onlyOwner {}

    function execTx(bytes memory execTxData) public onlyOwner {
        (
            address _target,
            uint256 _value,
            bytes memory _data,
            Enum.Operation _operation
        ) = abi.decode(execTxData, (address, uint256, bytes, Enum.Operation));
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
}
