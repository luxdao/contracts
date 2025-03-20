// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.28;

import {Version} from "../Version.sol";
import {IFractalModuleV1} from "../../interfaces/decent/deployables/IFractalModuleV1.sol";
import {GuardableModule, Enum} from "@gnosis-guild/zodiac/contracts/core/GuardableModule.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * Implementation of [IFractalModule](./interfaces/IFractalModule.md).
 *
 * A Safe module contract that allows for a "parent-child" DAO relationship.
 *
 * Adding the module allows for a designated set of addresses to execute
 * transactions on the Safe, which in our implementation is the set of parent
 * DAOs.
 */
contract FractalModuleV1 is
    IFractalModuleV1,
    GuardableModule,
    Version,
    UUPSUpgradeable
{
    uint16 private constant VERSION = 1;

    /** Mapping of whether an address is a controller (typically a parentDAO). */
    mapping(address => bool) public controllers;

    event ControllersAdded(address[] controllers);
    event ControllersRemoved(address[] controllers);

    error Unauthorized();
    error TxFailed();

    /** Allows only authorized controllers to execute transactions on the Safe. */
    modifier onlyAuthorized() {
        if (owner() != msg.sender && !controllers[msg.sender])
            revert Unauthorized();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /**
     * Initialize function for the UUPS pattern.
     *
     * @param _owner Address that will own the contract
     * @param _avatar Address of the avatar (e.g., the Safe)
     * @param _target Address that avatar calls are directed to
     * @param _controllers Array of controller addresses to enable
     */
    function initialize(
        address _owner,
        address _avatar,
        address _target,
        address[] memory _controllers
    ) public initializer {
        // Initializer owner with the msg.sender first,
        // needed for setting the avatar and target, which are ownable functions
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();

        // Setup module parameters
        setAvatar(_avatar);
        setTarget(_target);
        addControllers(_controllers);

        // Transfer ownership to the provided owner
        transferOwnership(_owner);
    }

    /**
     * Initialize function, will be triggered when a new instance is deployed.
     *
     * @param initializeParams encoded initialization parameters: `address _owner`,
     * `address _avatar`, `address _target`, `address[] memory _controllers`
     */
    function setUp(bytes memory initializeParams) public override initializer {
        (
            address _owner, // controlling DAO
            address _avatar,
            address _target,
            address[] memory _controllers // authorized controllers
        ) = abi.decode(
                initializeParams,
                (address, address, address, address[])
            );
        initialize(_owner, _avatar, _target, _controllers);
    }

    /**
     * @dev Function that authorizes an upgrade to a new implementation.
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal virtual override onlyOwner {}

    /** @inheritdoc IFractalModuleV1*/
    function removeControllers(
        address[] memory _controllers
    ) external onlyOwner {
        uint256 controllersLength = _controllers.length;
        for (uint256 i; i < controllersLength; ) {
            controllers[_controllers[i]] = false;
            unchecked {
                ++i;
            }
        }
        emit ControllersRemoved(_controllers);
    }

    /** @inheritdoc IFractalModuleV1*/
    function execTx(bytes memory execTxData) public onlyAuthorized {
        (
            address _target,
            uint256 _value,
            bytes memory _data,
            Enum.Operation _operation
        ) = abi.decode(execTxData, (address, uint256, bytes, Enum.Operation));
        if (!exec(_target, _value, _data, _operation)) revert TxFailed();
    }

    /** @inheritdoc IFractalModuleV1*/
    function addControllers(address[] memory _controllers) public onlyOwner {
        uint256 controllersLength = _controllers.length;
        for (uint256 i; i < controllersLength; ) {
            controllers[_controllers[i]] = true;
            unchecked {
                ++i;
            }
        }
        emit ControllersAdded(_controllers);
    }

    /// Implementation for the version
    function getVersion() public view virtual override returns (uint16) {
        return VERSION;
    }

    /**
     * Implementation of ERC165 for this contract.
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(IFractalModuleV1).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
