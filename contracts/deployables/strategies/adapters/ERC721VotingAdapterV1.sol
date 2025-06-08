// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IERC721VotingAdapterV1} from "../../../interfaces/decent/deployables/IERC721VotingAdapterV1.sol";
import {IBaseVotingAdapterV1} from "../../../interfaces/decent/deployables/IBaseVotingAdapterV1.sol";
import {IVersion} from "../../../interfaces/decent/deployables/IVersion.sol";
import {BaseVotingAdapterV1} from "./BaseVotingAdapterV1.sol";
import {Version} from "../../Version.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

contract ERC721VotingAdapterV1 is
    IERC721VotingAdapterV1,
    BaseVotingAdapterV1,
    ERC165,
    Version
{
    uint16 public constant VERSION = 1;

    IERC721 internal _token;
    uint256 internal _weightPerToken;
    mapping(uint32 => mapping(uint256 => bool)) internal _tokenIdUsedForVote;
    mapping(address => mapping(uint48 => mapping(uint256 => bool)))
        internal _tokenIdUsedPerFreezeVoteProposalPerFreezeVoteContract;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address token_,
        address strategy_,
        uint256 weightPerToken_
    ) external virtual override initializer {
        __BaseVotingAdapterV1_init(strategy_);
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

    function _getUnusedFreezeTokenIds(
        address freezeVoteContract,
        uint48 freezeProposalSnapshotAndId,
        uint256[] memory tokenIds
    ) internal view returns (uint256[] memory unusedFreezeTokenIds) {
        unusedFreezeTokenIds = new uint256[](tokenIds.length);
        uint256 unusedTokenCount = 0;

        for (uint256 i = 0; i < tokenIds.length; ) {
            if (
                !_tokenIdUsedPerFreezeVoteProposalPerFreezeVoteContract[
                    freezeVoteContract
                ][freezeProposalSnapshotAndId][tokenIds[i]]
            ) {
                unusedFreezeTokenIds[unusedTokenCount] = tokenIds[i];
                unusedTokenCount++;
            }
            unchecked {
                ++i;
            }
        }
        assembly {
            mstore(unusedFreezeTokenIds, unusedTokenCount)
        }
    }

    function _getValidFreezeTokenIds(
        address voter,
        address freezeVoteContract,
        uint48 freezeProposalSnapshotAndId,
        bytes calldata adapterVoteData
    ) internal view returns (uint256 weight, uint256[] memory validTokenIds) {
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

        validTokenIds = _getUnusedFreezeTokenIds(
            freezeVoteContract,
            freezeProposalSnapshotAndId,
            ownedTokenIds
        );
        if (validTokenIds.length == 0) {
            return (0, new uint256[](0));
        }

        weight = validTokenIds.length * _weightPerToken;
    }

    function getFreezeVoteWeight(
        address voter,
        address freezeVoteContract,
        uint48 freezeProposalSnapshotAndId,
        bytes calldata adapterVoteData
    ) external view virtual override returns (uint256 weight) {
        (weight, ) = _getValidFreezeTokenIds(
            voter,
            freezeVoteContract,
            freezeProposalSnapshotAndId,
            adapterVoteData
        );
    }

    function tokenIdUsedPerFreezeVoteProposalPerFreezeVoteContract(
        address freezeVoteContract,
        uint48 freezeProposalSnapshotAndId,
        uint256 tokenId
    ) external view virtual override returns (bool) {
        return
            _tokenIdUsedPerFreezeVoteProposalPerFreezeVoteContract[
                freezeVoteContract
            ][freezeProposalSnapshotAndId][tokenId];
    }

    function recordFreezeVote(
        address voter,
        uint48 freezeProposalSnapshotAndId,
        bytes calldata adapterVoteData
    )
        external
        virtual
        override
        onlyAuthorizedFreezeVoter
        returns (uint256 weightCasted)
    {
        uint256[] memory tokenIds = _decodeTokenIds(adapterVoteData);
        if (tokenIds.length == 0) {
            revert NoTokenIdsPassed();
        }

        uint256 currentWeightCasted = 0;
        for (uint256 i = 0; i < tokenIds.length; ) {
            uint256 tokenId = tokenIds[i];
            if (_token.ownerOf(tokenId) != voter) {
                revert TokenIdNotOwnedByVoter(tokenId);
            }
            if (
                _tokenIdUsedPerFreezeVoteProposalPerFreezeVoteContract[
                    msg.sender
                ][freezeProposalSnapshotAndId][tokenId]
            ) {
                revert TokenIdAlreadyUsedForVote(tokenId);
            }
            _tokenIdUsedPerFreezeVoteProposalPerFreezeVoteContract[msg.sender][
                freezeProposalSnapshotAndId
            ][tokenId] = true;
            currentWeightCasted += _weightPerToken;
            unchecked {
                ++i;
            }
        }

        if (currentWeightCasted == 0) {
            revert NoFreezeVotingWeight();
        }
        weightCasted = currentWeightCasted;
        emit FreezeVoteRecorded(
            voter,
            freezeProposalSnapshotAndId,
            weightCasted,
            adapterVoteData
        );
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

        for (uint256 i = 0; i < tokenIds.length; ) {
            bool isDuplicate = false;
            for (uint256 j = 0; j < uniqueCount; ) {
                if (uniqueTokenIds[j] == tokenIds[i]) {
                    isDuplicate = true;
                    break;
                }

                unchecked {
                    ++j;
                }
            }
            if (!isDuplicate) {
                uniqueTokenIds[uniqueCount] = tokenIds[i];
                uniqueCount++;
            }

            unchecked {
                ++i;
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

        for (uint256 i = 0; i < tokenIds.length; ) {
            if (_token.ownerOf(tokenIds[i]) == voter) {
                ownedTokenIds[ownedTokenCount] = tokenIds[i];
                ownedTokenCount++;
            }

            unchecked {
                ++i;
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

        for (uint256 i = 0; i < tokenIds.length; ) {
            if (!_tokenIdUsedForVote[proposalId][tokenIds[i]]) {
                unusedTokenIds[unusedTokenCount] = tokenIds[i];
                unusedTokenCount++;
            }

            unchecked {
                ++i;
            }
        }

        assembly {
            mstore(unusedTokenIds, unusedTokenCount)
        }
    }

    function _getValidTokenIds(
        address voter,
        uint32 proposalId,
        uint256[] memory allTokenIds
    )
        internal
        view
        virtual
        returns (uint256 weight, uint256[] memory unusedTokenIds)
    {
        uint256[] memory uniqueTokenIds = _getUniqueTokenIds(allTokenIds);
        uint256[] memory ownedTokenIds = _getOwnedTokenIds(
            voter,
            uniqueTokenIds
        );
        unusedTokenIds = _getUnusedTokenIds(proposalId, ownedTokenIds);
        weight = unusedTokenIds.length * _weightPerToken;
    }

    function weightOf(
        address _voter,
        uint32 _proposalId,
        bytes calldata _adapterVoteData
    ) external view virtual override returns (uint256 weight) {
        uint256[] memory allTokenIds = _decodeTokenIds(_adapterVoteData);
        (weight, ) = _getValidTokenIds(_voter, _proposalId, allTokenIds);
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
        returns (uint256 weight, uint256[] memory validTokenIds)
    {
        uint256[] memory allTokenIds = _decodeTokenIds(_adapterVoteData);
        (weight, validTokenIds) = _getValidTokenIds(
            _voter,
            _proposalId,
            allTokenIds
        );
    }

    function recordVote(
        address _voter,
        uint32 _proposalId,
        bytes calldata _adapterVoteData
    ) external virtual override onlyStrategy returns (uint256 weightCasted) {
        uint256[] memory tokenIds = _decodeTokenIds(_adapterVoteData);
        if (tokenIds.length == 0) {
            revert NoTokenIdsPassed();
        }

        for (uint256 i = 0; i < tokenIds.length; ) {
            uint256 tokenId = tokenIds[i];
            if (_token.ownerOf(tokenId) != _voter) {
                revert TokenIdNotOwnedByVoter(tokenId);
            }
            if (_tokenIdUsedForVote[_proposalId][tokenId]) {
                revert TokenIdAlreadyUsedForVote(tokenId);
            }
            _tokenIdUsedForVote[_proposalId][tokenId] = true;

            unchecked {
                ++i;
            }
        }

        weightCasted = tokenIds.length * _weightPerToken;

        emit VoteRecorded(_voter, _proposalId, weightCasted, _adapterVoteData);
    }

    function version() public pure virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(IERC721VotingAdapterV1).interfaceId ||
            interfaceId == type(IBaseVotingAdapterV1).interfaceId ||
            interfaceId == type(IVersion).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    function validVotingAdapterVote(
        address voter,
        uint32 proposalId,
        bytes calldata adapterVoteData
    ) external view virtual override returns (bool, uint256) {
        uint256[] memory allTokenIds = abi.decode(adapterVoteData, (uint256[]));
        (
            uint256 votingWeight,
            uint256[] memory validTokenIds
        ) = _getValidTokenIds(voter, proposalId, allTokenIds);

        if (validTokenIds.length != allTokenIds.length || votingWeight == 0) {
            return (false, 0);
        }

        return (true, votingWeight);
    }
}
