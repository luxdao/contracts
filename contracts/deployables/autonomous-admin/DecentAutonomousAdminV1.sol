// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IHatsElectionsEligibility} from "../../interfaces/hats/modules/IHatsElectionsEligibility.sol";
import {IDecentAutonomousAdminV1} from "../../interfaces/decent/deployables/IDecentAutonomousAdminV1.sol";
import {Version} from "../Version.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

contract DecentAutonomousAdminV1 is IDecentAutonomousAdminV1, Version {
    uint16 private constant VERSION = 1;

    function triggerStartNextTerm(
        TriggerStartArgs calldata args
    ) public virtual override {
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

    function version() public view virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(IDecentAutonomousAdminV1).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
