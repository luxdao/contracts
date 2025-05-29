// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IProposerAdapterV1} from "../../../interfaces/decent/deployables/IProposerAdapterV1.sol";
import {IProposerAdapterBaseV1} from "../../../interfaces/decent/deployables/IProposerAdapterBaseV1.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {Version} from "../../Version.sol";

contract ERC721ProposerAdapterV1 is
    IProposerAdapterV1,
    Initializable,
    ERC165,
    Version
{
    IERC721 public token;
    uint256 public proposerThreshold;
    uint256 public weightPerNft;

    uint16 public constant VERSION = 1;

    error InvalidTokenAddress();
    error InvalidWeightPerNft();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _token,
        uint256 _proposerThreshold,
        uint256 _weightPerNft
    ) external virtual initializer {
        if (_token == address(0)) revert InvalidTokenAddress();
        if (_weightPerNft == 0) revert InvalidWeightPerNft();

        token = IERC721(_token);
        proposerThreshold = _proposerThreshold;
        weightPerNft = _weightPerNft;
    }

    function isProposer(
        address _proposer
    ) external view virtual override returns (bool) {
        return (token.balanceOf(_proposer) * weightPerNft) >= proposerThreshold;
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
