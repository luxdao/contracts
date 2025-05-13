// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {BaseFreezeGuardV1} from "./BaseFreezeGuardV1.sol";
import {Version} from "../Version.sol";
import {IBaseFreezeVotingV1} from "../../interfaces/decent/deployables/IBaseFreezeVotingV1.sol";
import {Enum} from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";

/**
 * A Safe Transaction Guard contract that prevents an [Azorius](./azorius/Azorius.md)
 * subDAO from executing transactions if it has been frozen by its parentDAO.
 *
 * See https://docs.safe.global/learn/safe-core/safe-core-protocol/guards.
 */
contract AzoriusFreezeGuardV1 is Version, BaseFreezeGuardV1 {
    uint16 private constant VERSION = 1;

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
     * Initialize function for the proxy deployment. This standardizes the initialization
     * to better work with ProxyFactory.
     *
     * @param _owner Address that will own the proxy and be able to upgrade it
     * @param _freezeVoting Address of the freeze voting contract
     */
    function initialize(
        address _owner,
        address _freezeVoting
    ) public initializer {
        super.initialize(_owner);
        freezeVoting = IBaseFreezeVotingV1(_freezeVoting);

        emit AzoriusFreezeGuardSetUp(msg.sender, _owner, _freezeVoting);
    }

    /**
     * @dev Function that should revert when `msg.sender` is not authorized to upgrade the contract.
     * Called by {upgradeTo} and {upgradeToAndCall}.
     *
     * Reverts if the sender is not the owner of the contract.
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal virtual override onlyOwner {
        // Authorization is handled by the onlyOwner modifier
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
    ) external view override(BaseFreezeGuardV1) {
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
    ) external view override(BaseFreezeGuardV1) {
        // not implementated
    }

    /// @inheritdoc Version
    function getVersion() public view virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(BaseFreezeGuardV1, Version) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
