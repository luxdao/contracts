// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IERC721ProposerAdapterV1} from "../../../interfaces/decent/deployables/IERC721ProposerAdapterV1.sol";
import {IProposerAdapterV1} from "../../../interfaces/decent/deployables/IProposerAdapterV1.sol";
import {IProposerAdapterBaseV1} from "../../../interfaces/decent/deployables/IProposerAdapterBaseV1.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {Version} from "../../Version.sol";

contract ERC721ProposerAdapterV1 is
    IERC721ProposerAdapterV1,
    Initializable,
    ERC165,
    Version
{
    IERC721 internal _token;
    uint256 internal _proposerThreshold;

    uint16 public constant VERSION = 1;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address token_,
        uint256 proposerThreshold_
    ) external virtual override initializer {
        _token = IERC721(token_);
        _proposerThreshold = proposerThreshold_;
    }

    function token() external view virtual override returns (address) {
        return address(_token);
    }

    function proposerThreshold()
        external
        view
        virtual
        override
        returns (uint256)
    {
        return _proposerThreshold;
    }

    function isProposer(
        address _proposer,
        bytes memory
    ) external view virtual override returns (bool) {
        return _token.balanceOf(_proposer) >= _proposerThreshold;
    }

    function version() public pure virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC165, Version) returns (bool) {
        return
            interfaceId == type(IERC721ProposerAdapterV1).interfaceId ||
            interfaceId == type(IProposerAdapterV1).interfaceId ||
            interfaceId == type(IProposerAdapterBaseV1).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
