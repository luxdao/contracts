// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IHatsElectionsEligibility} from "../../interfaces/hats/modules/IHatsElectionsEligibility.sol";
import {IDecentAutonomousAdminV1} from "../../interfaces/decent/deployables/IDecentAutonomousAdminV1.sol";
import {IVersion} from "../../interfaces/decent/deployables/IVersion.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

contract DecentAutonomousAdminV1 is IDecentAutonomousAdminV1, IVersion, ERC165 {
    uint16 private constant VERSION = 1;

    function triggerStartNextTerm(
        TriggerStartArgs calldata args_
    ) public virtual override {
        IHatsElectionsEligibility hatsElectionModule = IHatsElectionsEligibility(
                args_.hatsProtocol.getHatEligibilityModule(args_.hatId)
            );

        hatsElectionModule.startNextTerm();

        // This will burn the hat if wearer is no longer eligible
        args_.hatsProtocol.checkHatWearerStatus(
            args_.hatId,
            args_.currentWearer
        );

        // This will mint the hat to the nominated wearer, if necessary
        if (args_.nominatedWearer != args_.currentWearer) {
            args_.hatsProtocol.mintHat(args_.hatId, args_.nominatedWearer);
        }
    }

    function version() external view virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId_
    ) public view virtual override returns (bool) {
        return
            interfaceId_ == type(IDecentAutonomousAdminV1).interfaceId ||
            interfaceId_ == type(IVersion).interfaceId ||
            super.supportsInterface(interfaceId_);
    }
}
