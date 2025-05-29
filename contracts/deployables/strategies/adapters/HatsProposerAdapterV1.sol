// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IProposerAdapterV1} from "../../../interfaces/decent/deployables/IProposerAdapterV1.sol";
import {IProposerAdapterBaseV1} from "../../../interfaces/decent/deployables/IProposerAdapterBaseV1.sol";
import {IHats} from "../../../interfaces/hats/IHats.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {Version} from "../../Version.sol";

contract HatsProposerAdapterV1 is
    IProposerAdapterV1,
    Initializable,
    ERC165,
    Version
{
    IHats public hatsContract;
    uint256[] private whitelistedHatIds;

    uint16 public constant VERSION = 1;

    error MissingHatsContract();
    error NoHatsWhitelisted();
    error HatAlreadyWhitelisted();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _hatsContractAddress,
        uint256[] memory _whitelistedHats
    ) public virtual initializer {
        if (_hatsContractAddress == address(0)) revert MissingHatsContract();
        hatsContract = IHats(_hatsContractAddress);

        if (_whitelistedHats.length == 0) revert NoHatsWhitelisted();
        for (uint256 i = 0; i < _whitelistedHats.length; i++) {
            uint256 _hatId = _whitelistedHats[i];
            for (uint256 j = 0; j < whitelistedHatIds.length; j++) {
                if (whitelistedHatIds[j] == _hatId)
                    revert HatAlreadyWhitelisted();
            }
            whitelistedHatIds.push(_hatId);
        }
    }

    function getWhitelistedHatIds()
        public
        view
        virtual
        returns (uint256[] memory)
    {
        return whitelistedHatIds;
    }

    function isProposer(
        address _proposer
    ) public view virtual override returns (bool) {
        for (uint256 i = 0; i < whitelistedHatIds.length; i++) {
            if (hatsContract.isWearerOfHat(_proposer, whitelistedHatIds[i])) {
                return true;
            }
        }
        return false;
    }

    function getVersion() public pure virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC165, Version) returns (bool) {
        return
            interfaceId == type(IProposerAdapterV1).interfaceId ||
            interfaceId == type(IProposerAdapterBaseV1).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
