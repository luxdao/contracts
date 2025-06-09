// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IVoterResolverV1} from "../../interfaces/decent/deployables/IVoterResolverV1.sol";
import {SmartAccountValidationV1} from "./SmartAccountValidationV1.sol";

abstract contract VoterResolverV1 is
    IVoterResolverV1,
    SmartAccountValidationV1
{
    constructor() {
        _disableInitializers();
    }

    function __VoterResolverV1_init(
        address _lightAccountFactory
    ) internal onlyInitializing {
        __SmartAccountValidationV1_init(_lightAccountFactory);
    }

    function voter(
        address _msgSender
    ) public view virtual override returns (address) {
        (bool isValid, address lightAccountOwner) = validateSmartAccount(
            _msgSender
        );
        if (!isValid) {
            return _msgSender;
        }

        return lightAccountOwner;
    }
}
