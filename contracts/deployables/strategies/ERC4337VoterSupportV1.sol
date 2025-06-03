// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IERC4337VoterSupportV1} from "../../interfaces/decent/deployables/IERC4337VoterSupportV1.sol";
import {SmartAccountValidationV1} from "../account-abstraction/SmartAccountValidationV1.sol";

abstract contract ERC4337VoterSupportV1 is
    IERC4337VoterSupportV1,
    SmartAccountValidationV1
{
    mapping(uint32 => bool) internal _votingPeriodEnded;

    constructor() {
        _disableInitializers();
    }

    function __ERC4337VoterSupportV1_init(
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

    function votingPeriodEnded(
        uint32 _proposalId
    ) external view virtual override returns (bool) {
        return _votingPeriodEnded[_proposalId];
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(IERC4337VoterSupportV1).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
