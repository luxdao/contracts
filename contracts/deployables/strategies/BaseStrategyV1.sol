// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.28;

import {IAzoriusV1} from "../../interfaces/decent/deployables/IAzoriusV1.sol";
import {IBaseStrategyV1} from "../../interfaces/decent/deployables/IBaseStrategyV1.sol";
import {FactoryFriendly} from "@gnosis-guild/zodiac/contracts/factory/FactoryFriendly.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

/**
 * The base abstract contract for all voting strategies in Azorius.
 */
abstract contract BaseStrategyV1 is
    IBaseStrategyV1,
    OwnableUpgradeable,
    FactoryFriendly,
    ERC165
{
    event AzoriusSet(address indexed azoriusModule);
    event StrategySetUp(address indexed azoriusModule, address indexed owner);

    error OnlyAzorius();

    IAzoriusV1 public azoriusModule;

    /**
     * Ensures that only the [Azorius](./Azorius.md) contract that pertains to this
     * [BaseStrategy](./BaseStrategy.md) can call functions on it.
     */
    modifier onlyAzorius() {
        if (msg.sender != address(azoriusModule)) revert OnlyAzorius();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /** @inheritdoc IBaseStrategyV1*/
    function setAzorius(address _azoriusModule) external onlyOwner {
        azoriusModule = IAzoriusV1(_azoriusModule);
        emit AzoriusSet(_azoriusModule);
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

    /**
     * Sets the address of the [Azorius](Azorius.md) module contract.
     *
     * @param _azoriusModule address of the Azorius module
     */
    function _setAzorius(address _azoriusModule) internal {
        azoriusModule = IAzoriusV1(_azoriusModule);
        emit AzoriusSet(_azoriusModule);
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(IBaseStrategyV1).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
