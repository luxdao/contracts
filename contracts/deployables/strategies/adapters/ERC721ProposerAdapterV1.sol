// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IERC721ProposerAdapterV1} from "../../../interfaces/decent/deployables/IERC721ProposerAdapterV1.sol";
import {IProposerAdapterV1} from "../../../interfaces/decent/deployables/IProposerAdapterV1.sol";
import {IVersion} from "../../../interfaces/decent/deployables/IVersion.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

contract ERC721ProposerAdapterV1 is
    IERC721ProposerAdapterV1,
    Initializable,
    IVersion,
    ERC165
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
        address proposer_,
        bytes calldata
    ) external view virtual override returns (bool) {
        return _token.balanceOf(proposer_) >= _proposerThreshold;
    }

    function version() external pure virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId_
    ) public view virtual override returns (bool) {
        return
            interfaceId_ == type(IERC721ProposerAdapterV1).interfaceId ||
            interfaceId_ == type(IProposerAdapterV1).interfaceId ||
            interfaceId_ == type(IVersion).interfaceId ||
            super.supportsInterface(interfaceId_);
    }
}
