// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.28;

import {BaseGuardV1} from "./BaseGuardV1.sol";
import {IVersion} from "../../interfaces/decent/deployables/IVersion.sol";
import {IBaseFreezeVotingV1} from "../../interfaces/decent/deployables/IBaseFreezeVotingV1.sol";
import {FactoryFriendly} from "@gnosis-guild/zodiac/contracts/factory/FactoryFriendly.sol";
import {Enum} from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";

/**
 * A Safe Transaction Guard contract that prevents an [Azorius](./azorius/Azorius.md)
 * subDAO from executing transactions if it has been frozen by its parentDAO.
 *
 * See https://docs.safe.global/learn/safe-core/safe-core-protocol/guards.
 */
contract AzoriusFreezeGuardV1 is IVersion, BaseGuardV1, FactoryFriendly {
    /**
     * A reference to the freeze voting contract, which manages the freeze
     * voting process and maintains the frozen / unfrozen state of the DAO.
     */
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

    /**
     * Initialize function, will be triggered when a new instance is deployed.
     *
     * @param initializeParams encoded initialization parameters: `address _owner`,
     * `address _freezeVoting`
     */
    function setUp(bytes memory initializeParams) public override initializer {
        (address _owner, address _freezeVoting) = abi.decode(
            initializeParams,
            (address, address)
        );
        __Ownable_init(_owner);
        freezeVoting = IBaseFreezeVotingV1(_freezeVoting);

        emit AzoriusFreezeGuardSetUp(msg.sender, _owner, _freezeVoting);
    }

    /**
     * This function is called by the Safe to check if the transaction
     * is able to be executed and reverts if the guard conditions are
     * not met.
     *
     * In our implementation, this reverts if the DAO is frozen.
     */
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
    ) external view override(BaseGuardV1) {
        // if the DAO is currently frozen, revert
        // see BaseFreezeVoting for freeze voting details
        if (freezeVoting.isFrozen()) revert DAOFrozen();
    }

    /**
     * A callback performed after a transaction is executed on the Safe. This is a required
     * function of the `BaseGuard` and `IGuard` interfaces that we do not make use of.
     */
    function checkAfterExecution(
        bytes32,
        bool
    ) external view override(BaseGuardV1) {
        // not implementated
    }

    /// @inheritdoc IVersion
    function getVersion() external pure virtual override returns (uint16) {
        return 1;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(IVersion).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
