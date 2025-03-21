// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.28;

import {IHatsElectionsEligibility} from "../../interfaces/hats/modules/IHatsElectionsEligibility.sol";
import {IDecentAutonomousAdminV1} from "../../interfaces/decent/deployables/IDecentAutonomousAdminV1.sol";
import {Version} from "../Version.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract DecentAutonomousAdminV1 is
    IDecentAutonomousAdminV1,
    Version,
    UUPSUpgradeable,
    OwnableUpgradeable
{
    uint16 private constant VERSION = 1;

    constructor() {
        _disableInitializers();
    }

    /**
     * Initialize function for the proxy deployment. This standardizes the initialization
     * to better work with ProxyFactory.
     *
     * @param _owner Address that will own the proxy and be able to upgrade it
     */
    function initialize(address _owner) public initializer {
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
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

    // //////////////////////////////////////////////////////////////
    //                         Public Functions
    // //////////////////////////////////////////////////////////////
    function triggerStartNextTerm(TriggerStartArgs calldata args) public {
        IHatsElectionsEligibility hatsElectionModule = IHatsElectionsEligibility(
                args.hatsProtocol.getHatEligibilityModule(args.hatId)
            );

        hatsElectionModule.startNextTerm();

        // This will burn the hat if wearer is no longer eligible
        args.hatsProtocol.checkHatWearerStatus(args.hatId, args.currentWearer);

        // This will mint the hat to the nominated wearer, if necessary
        if (args.nominatedWearer != args.currentWearer) {
            args.hatsProtocol.mintHat(args.hatId, args.nominatedWearer);
        }
    }

    /// @inheritdoc Version
    function getVersion() public view virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override returns (bool) {
        return
            interfaceId == type(IDecentAutonomousAdminV1).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
