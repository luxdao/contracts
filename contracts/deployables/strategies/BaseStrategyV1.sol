// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.28;

import {IBaseStrategyV1} from "../../interfaces/decent/deployables/IBaseStrategyV1.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

/**
 * Base voting and verification strategy for use in the [Azorius](./Azorius.md) contract.
 * Meant to be used as an Abstract class along with another implementation.
 *
 * This is a base class which offers hooks into the [Azorius](./Azorius.md) contract,
 * offering capability for custom voting rules.
 */
abstract contract BaseStrategyV1 is
    IBaseStrategyV1,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ERC165
{
    /** The Azorius contract address for this Strategy contract. */
    address public azoriusModule;

    event AzoriusSet(address indexed azorius);
    event StrategySetUp(address indexed azorius, address indexed owner);

    error AzoriusUnauthorizedAccount(address account);

    /** Modifier that ensures transactions are being called only by Azorius. */
    modifier onlyAzorius() {
        if (msg.sender != azoriusModule)
            revert AzoriusUnauthorizedAccount(msg.sender);
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Function that authorizes an upgrade to a new implementation.
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal virtual override onlyOwner {}

    /**
     * Sets the azorius address that this strategy will provide voting information to.
     * Must be called by the owner.
     *
     * @param _azoriusAddress The Azorius contract address
     */
    function setAzorius(address _azoriusAddress) external onlyOwner {
        _setAzorius(_azoriusAddress);
    }

    /** Internal implementation of `setAzorius`. */
    function _setAzorius(address _azoriusAddress) internal {
        if (_azoriusAddress == address(0))
            revert AzoriusUnauthorizedAccount(address(0));
        azoriusModule = _azoriusAddress;
        emit AzoriusSet(_azoriusAddress);
    }

    /** @inheritdoc IBaseStrategyV1*/
    function initializeProposal(bytes memory _data) external virtual;

    /** @inheritdoc IBaseStrategyV1*/
    function isPassed(uint32 _proposalId) external view virtual returns (bool);

    /** @inheritdoc IBaseStrategyV1*/
    function isProposer(address _address) external view virtual returns (bool);

    /** @inheritdoc IBaseStrategyV1*/
    function votingEndTimestamp(
        uint32 _proposalId
    ) external view virtual returns (uint48);

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(IBaseStrategyV1).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
