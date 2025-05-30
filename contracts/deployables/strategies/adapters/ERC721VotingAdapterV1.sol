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

    function _decodeTokenIds(
        bytes calldata _adapterVoteData
    ) internal view virtual returns (uint256[] memory tokenIds) {
        tokenIds = abi.decode(_adapterVoteData, (uint256[]));
    }

    function _getUniqueTokenIds(
        uint256[] memory tokenIds
    ) internal view virtual returns (uint256[] memory uniqueTokenIds) {
        uniqueTokenIds = new uint256[](tokenIds.length);
        uint256 uniqueCount = 0;

        for (uint256 i = 0; i < tokenIds.length; i++) {
            bool isDuplicate = false;
            for (uint256 j = 0; j < uniqueCount; j++) {
                if (uniqueTokenIds[j] == tokenIds[i]) {
                    isDuplicate = true;
                    break;
                }
            }
            if (!isDuplicate) {
                uniqueTokenIds[uniqueCount] = tokenIds[i];
                uniqueCount++;
            }
        }

        assembly {
            mstore(uniqueTokenIds, uniqueCount)
        }
    }

    function _getOwnedTokenIds(
        address voter,
        uint256[] memory tokenIds
    ) internal view virtual returns (uint256[] memory ownedTokenIds) {
        ownedTokenIds = new uint256[](tokenIds.length);
        uint256 ownedTokenCount = 0;

        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (_token.ownerOf(tokenIds[i]) == voter) {
                ownedTokenIds[ownedTokenCount] = tokenIds[i];
                ownedTokenCount++;
            }
        }

        assembly {
            mstore(ownedTokenIds, ownedTokenCount)
        }
    }

    function _getUnusedTokenIds(
        uint32 proposalId,
        uint256[] memory tokenIds
    ) internal view virtual returns (uint256[] memory unusedTokenIds) {
        unusedTokenIds = new uint256[](tokenIds.length);
        uint256 unusedTokenCount = 0;

        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (!_tokenIdUsedForVote[proposalId][tokenIds[i]]) {
                unusedTokenIds[unusedTokenCount] = tokenIds[i];
                unusedTokenCount++;
            }
        }

        assembly {
            mstore(unusedTokenIds, unusedTokenCount)
        }
    }

    function _getValidTokenIds(
        address voter,
        uint32 proposalId,
        bytes calldata adapterVoteData
    )
        internal
        view
        virtual
        returns (uint256 weight, uint256[] memory unusedTokenIds)
    {
        uint256[] memory allTokenIds = _decodeTokenIds(adapterVoteData);
        if (allTokenIds.length == 0) {
            return (0, new uint256[](0));
        }

        uint256[] memory uniqueTokenIds = _getUniqueTokenIds(allTokenIds);
        if (uniqueTokenIds.length == 0) {
            return (0, new uint256[](0));
        }

        uint256[] memory ownedTokenIds = _getOwnedTokenIds(
            voter,
            uniqueTokenIds
        );
        if (ownedTokenIds.length == 0) {
            return (0, new uint256[](0));
        }

        unusedTokenIds = _getUnusedTokenIds(proposalId, ownedTokenIds);
        if (unusedTokenIds.length == 0) {
            return (0, new uint256[](0));
        }

        weight = unusedTokenIds.length * _weightPerToken;
    }

    function weightOf(
        address _voter,
        uint32 _proposalId,
        bytes calldata _adapterVoteData
    ) external view virtual override returns (uint256 weight) {
        (weight, ) = _getValidTokenIds(_voter, _proposalId, _adapterVoteData);
    }

    function weightOfWithValidTokenIds(
        address _voter,
        uint32 _proposalId,
        bytes calldata _adapterVoteData
    )
        external
        view
        virtual
        override
        returns (uint256 weight, uint256[] memory unusedTokenIds)
    {
        (weight, unusedTokenIds) = _getValidTokenIds(
            _voter,
            _proposalId,
            _adapterVoteData
        );
    }

    function recordVote(
        address _voter,
        uint32 _proposalId,
        bytes calldata _adapterVoteData
    ) external virtual override returns (uint256 weightCasted) {
        uint256[] memory tokenIds = _decodeTokenIds(_adapterVoteData);
        if (tokenIds.length == 0) {
            revert NoTokenIdsPassed();
        }

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            if (_token.ownerOf(tokenId) != _voter) {
                revert TokenIdNotOwnedByVoter(tokenId);
            }
            if (_tokenIdUsedForVote[_proposalId][tokenId]) {
                revert TokenIdAlreadyUsedForVote(tokenId);
            }
            _tokenIdUsedForVote[_proposalId][tokenId] = true;
        }

        weightCasted = tokenIds.length * _weightPerToken;

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
