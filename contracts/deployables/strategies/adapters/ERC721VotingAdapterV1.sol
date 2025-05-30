// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IERC721VotingAdapterV1} from "../../../interfaces/decent/deployables/IERC721VotingAdapterV1.sol";
import {IVotingAdapterV1} from "../../../interfaces/decent/deployables/IVotingAdapterV1.sol";
import {IVotingAdapterBaseV1} from "../../../interfaces/decent/deployables/IVotingAdapterBaseV1.sol";
import {Version} from "../../Version.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

contract ERC721VotingAdapterV1 is
    IERC721VotingAdapterV1,
    Initializable,
    ERC165,
    Version
{
    uint16 public constant VERSION = 1;

    IERC721 internal _token;
    uint256 internal _weightPerToken;
    mapping(uint32 => mapping(uint256 => bool)) internal _tokenIdUsedForVote;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address token_,
        uint256 weightPerToken_
    ) external virtual override initializer {
        if (token_ == address(0)) revert InvalidTokenAddress();
        if (weightPerToken_ == 0) revert InvalidWeightPerToken();

        _token = IERC721(token_);
        _weightPerToken = weightPerToken_;
    }

    function token() external view virtual override returns (address) {
        return address(_token);
    }

    function weightPerToken() external view virtual override returns (uint256) {
        return _weightPerToken;
    }

    function tokenIdUsedForVote(
        uint32 proposalId,
        uint256 tokenId
    ) external view virtual override returns (bool) {
        return _tokenIdUsedForVote[proposalId][tokenId];
    }

    function _getValidUnvotedTokenIdsAndWeight(
        address _voter,
        uint32 _proposalId,
        bytes calldata _adapterVoteData
    )
        internal
        view
        virtual
        returns (
            uint256[] memory validTokenIdsForThisCall,
            uint256 totalCalculatedWeight
        )
    {
        uint256[] memory tokenIds = abi.decode(_adapterVoteData, (uint256[]));

        if (tokenIds.length == 0) {
            return (new uint256[](0), 0);
        }

        uint256[] memory tempValidTokenIds = new uint256[](tokenIds.length);
        uint256 validCount = 0;

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            if (_token.ownerOf(tokenId) != _voter) {
                continue;
            }

            if (_tokenIdUsedForVote[_proposalId][tokenId]) {
                continue;
            }

            bool alreadyProcessedInThisCall = false;
            for (uint256 j = 0; j < validCount; j++) {
                if (tempValidTokenIds[j] == tokenId) {
                    alreadyProcessedInThisCall = true;
                    break;
                }
            }

            if (!alreadyProcessedInThisCall) {
                tempValidTokenIds[validCount] = tokenId;
                validCount++;
                totalCalculatedWeight += _weightPerToken;
            }
        }

        validTokenIdsForThisCall = new uint256[](validCount);
        for (uint256 i = 0; i < validCount; i++) {
            validTokenIdsForThisCall[i] = tempValidTokenIds[i];
        }
    }

    function weightOf(
        address _voter,
        uint32 _proposalId,
        bytes calldata _adapterVoteData
    ) external view virtual override returns (uint256 weight) {
        (, uint256 totalCalculatedWeight) = _getValidUnvotedTokenIdsAndWeight(
            _voter,
            _proposalId,
            _adapterVoteData
        );
        weight = totalCalculatedWeight;
    }

    function recordVote(
        address _voter,
        uint32 _proposalId,
        bytes calldata _adapterVoteData
    ) external virtual override returns (uint256 weightCasted) {
        (
            uint256[] memory validTokenIdsToRecord,
            uint256 totalCalculatedWeight
        ) = _getValidUnvotedTokenIdsAndWeight(
                _voter,
                _proposalId,
                _adapterVoteData
            );

        for (uint256 i = 0; i < validTokenIdsToRecord.length; i++) {
            _tokenIdUsedForVote[_proposalId][validTokenIdsToRecord[i]] = true;
        }
        weightCasted = totalCalculatedWeight;

        emit VoteRecorded(_voter, _proposalId, weightCasted, _adapterVoteData);
    }

    function version() public pure virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC165, Version) returns (bool) {
        return
            interfaceId == type(IERC721VotingAdapterV1).interfaceId ||
            interfaceId == type(IVotingAdapterV1).interfaceId ||
            interfaceId == type(IVotingAdapterBaseV1).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
