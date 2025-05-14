// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IHatsProposalCreationWhitelistV1} from "../../interfaces/decent/deployables/IHatsProposalCreationWhitelistV1.sol";
import {IHats} from "../../interfaces/hats/IHats.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

abstract contract HatsProposalCreationWhitelistV1 is
    IHatsProposalCreationWhitelistV1,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ERC165
{
    IHats public hatsContract;

    /** Array to store whitelisted Hat IDs. */
    uint256[] private whitelistedHatIds;

    constructor() {
        _disableInitializers();
    }

    /**
     * Initializes the contract with its initial parameters.
     *
     * @param _hatsContract Address of the Hats contract
     * @param _initialWhitelistedHats Array of initial whitelisted Hat IDs
     */
    function initialize(
        address _owner,
        address _hatsContract,
        uint256[] memory _initialWhitelistedHats
    ) public virtual initializer {
        __Ownable_init(_owner);

        if (_hatsContract == address(0)) revert MissingHatsContract();
        hatsContract = IHats(_hatsContract);

        if (_initialWhitelistedHats.length == 0) revert NoHatsWhitelisted();
        for (uint256 i = 0; i < _initialWhitelistedHats.length; i++) {
            whitelistHat(_initialWhitelistedHats[i]);
        }
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal virtual override onlyOwner {}

    /**
     * Internal function to add a Hat to the whitelist.
     * @param _hatId The ID of the Hat to whitelist
     */
    function whitelistHat(uint256 _hatId) public onlyOwner {
        for (uint256 i = 0; i < whitelistedHatIds.length; i++) {
            if (whitelistedHatIds[i] == _hatId) revert HatAlreadyWhitelisted();
        }
        whitelistedHatIds.push(_hatId);
        emit HatWhitelisted(_hatId);
    }

    /**
     * Removes a Hat from the whitelist for proposal creation.
     * @param _hatId The ID of the Hat to remove from the whitelist
     */
    function unwhitelistHat(uint256 _hatId) external onlyOwner {
        bool found = false;
        for (uint256 i = 0; i < whitelistedHatIds.length; i++) {
            if (whitelistedHatIds[i] == _hatId) {
                whitelistedHatIds[i] = whitelistedHatIds[
                    whitelistedHatIds.length - 1
                ];
                whitelistedHatIds.pop();
                found = true;
                break;
            }
        }
        if (!found) revert HatNotWhitelisted();

        emit HatUnwhitelisted(_hatId);
    }

    /**
     * @dev Checks if an address is wearing any of the whitelisted Hats.
     * @param _address The address to check for wearing whitelisted Hats.
     * @return bool Returns true if the address is wearing any of the whitelisted Hats, false otherwise.
     */
    function isWearingWhitelistedHat(
        address _address
    ) public view virtual returns (bool) {
        for (uint256 i = 0; i < whitelistedHatIds.length; i++) {
            if (hatsContract.isWearerOfHat(_address, whitelistedHatIds[i])) {
                return true;
            }
        }
        return false;
    }

    /**
     * @dev Returns the IDs of all whitelisted Hats.
     * @return uint256[] memory An array of whitelisted Hat IDs.
     */
    function getWhitelistedHatIds() public view returns (uint256[] memory) {
        return whitelistedHatIds;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(IHatsProposalCreationWhitelistV1).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
