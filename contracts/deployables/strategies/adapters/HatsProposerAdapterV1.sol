// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IHatsProposerAdapterV1} from "../../../interfaces/decent/deployables/IHatsProposerAdapterV1.sol";
import {IProposerAdapterV1} from "../../../interfaces/decent/deployables/IProposerAdapterV1.sol";
import {IProposerAdapterBaseV1} from "../../../interfaces/decent/deployables/IProposerAdapterBaseV1.sol";
import {IHats} from "../../../interfaces/hats/IHats.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {Version} from "../../Version.sol";

contract HatsProposerAdapterV1 is
    IHatsProposerAdapterV1,
    Initializable,
    ERC165,
    Version
{
    IHats internal _hatsContract;
    uint256[] internal _whitelistedHatIds;

    uint16 public constant VERSION = 1;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address hatsContract_,
        uint256[] memory whitelistedHatIds_
    ) public virtual override initializer {
        _hatsContract = IHats(hatsContract_);
        _whitelistedHatIds = whitelistedHatIds_;
    }

    function hatsContract() external view virtual override returns (address) {
        return address(_hatsContract);
    }

    function whitelistedHatIds()
        public
        view
        virtual
        override
        returns (uint256[] memory)
    {
        return _whitelistedHatIds;
    }

    function isProposer(
        address _proposer
    ) public view virtual override returns (bool) {
        for (uint256 i = 0; i < _whitelistedHatIds.length; i++) {
            if (_hatsContract.isWearerOfHat(_proposer, _whitelistedHatIds[i])) {
                return true;
            }
        }
        return false;
    }

    function version() public pure virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC165, Version) returns (bool) {
        return
            interfaceId == type(IHatsProposerAdapterV1).interfaceId ||
            interfaceId == type(IProposerAdapterV1).interfaceId ||
            interfaceId == type(IProposerAdapterBaseV1).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
