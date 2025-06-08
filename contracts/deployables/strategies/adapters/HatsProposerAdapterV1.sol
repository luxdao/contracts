// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IHatsProposerAdapterV1} from "../../../interfaces/decent/deployables/IHatsProposerAdapterV1.sol";
import {IProposerAdapterV1} from "../../../interfaces/decent/deployables/IProposerAdapterV1.sol";
import {IHats} from "../../../interfaces/hats/IHats.sol";
import {IVersion} from "../../../interfaces/decent/deployables/IVersion.sol";
import {Version} from "../../Version.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

contract HatsProposerAdapterV1 is
    IHatsProposerAdapterV1,
    Initializable,
    ERC165,
    Version
{
    IHats internal _hatsContract;
    uint256[] internal _whitelistedHatIds;
    mapping(uint256 hatId => bool isWhitelisted) internal _hatIdToIsWhitelisted;

    uint16 public constant VERSION = 1;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address hatsContract_,
        uint256[] calldata whitelistedHatIds_
    ) public virtual override initializer {
        _hatsContract = IHats(hatsContract_);
        _whitelistedHatIds = whitelistedHatIds_;
        for (uint256 i = 0; i < whitelistedHatIds_.length; ) {
            _hatIdToIsWhitelisted[whitelistedHatIds_[i]] = true;

            unchecked {
                ++i;
            }
        }
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
        address proposer_,
        bytes calldata data_
    ) public view virtual override returns (bool) {
        uint256 hatId = abi.decode(data_, (uint256));
        return
            _hatIdToIsWhitelisted[hatId] &&
            _hatsContract.isWearerOfHat(proposer_, hatId);
    }

    function version() public pure virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId_
    ) public view virtual override returns (bool) {
        return
            interfaceId_ == type(IHatsProposerAdapterV1).interfaceId ||
            interfaceId_ == type(IProposerAdapterV1).interfaceId ||
            interfaceId_ == type(IVersion).interfaceId ||
            super.supportsInterface(interfaceId_);
    }
}
