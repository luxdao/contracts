// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IERC721VotingStrategyV1} from "../../interfaces/decent/deployables/IERC721VotingStrategyV1.sol";
import {IERC721FreezeVotingV1} from "../../interfaces/decent/deployables/IERC721FreezeVotingV1.sol";
import {IBaseFreezeVotingV1} from "../../interfaces/decent/deployables/IBaseFreezeVotingV1.sol";
import {IVersion} from "../../interfaces/decent/deployables/IVersion.sol";
import {BaseFreezeVotingV1} from "./BaseFreezeVotingV1.sol";
import {Version} from "../Version.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

contract ERC721FreezeVotingV1 is
    IERC721FreezeVotingV1,
    BaseFreezeVotingV1,
    Version,
    ERC165
{
    uint16 private constant VERSION = 1;

    IERC721VotingStrategyV1 internal _strategy;
    mapping(uint48 => mapping(address => mapping(uint256 => bool)))
        internal _idHasFreezeVoted;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        uint256 freezeVotesThreshold_,
        uint32 freezeProposalPeriod_,
        uint32 freezePeriod_,
        address strategy_
    ) public virtual override initializer {
        __BaseFreezeVotingV1_init(
            owner_,
            freezeProposalPeriod_,
            freezePeriod_,
            freezeVotesThreshold_
        );
        _strategy = IERC721VotingStrategyV1(strategy_);
    }

    function strategy() external view virtual override returns (address) {
        return address(_strategy);
    }

    function idHasFreezeVoted(
        uint48 freezeProposalCreated_,
        address tokenAddress_,
        uint256 tokenId_
    ) external view virtual override returns (bool) {
        return
            _idHasFreezeVoted[freezeProposalCreated_][tokenAddress_][tokenId_];
    }

    function castFreezeVote(
        address[] calldata _tokenAddresses,
        uint256[] calldata _tokenIds
    ) external virtual override {
        if (_tokenAddresses.length != _tokenIds.length) revert UnequalArrays();

        if (block.timestamp > _freezeProposalCreated + _freezeProposalPeriod) {
            _freezeProposalCreated = uint48(block.timestamp);
            _freezeProposalVoteCount = 0;
            emit FreezeProposalCreated(msg.sender);
        }

        uint256 userVotes = _getVotesAndUpdateHasVoted(
            _tokenAddresses,
            _tokenIds,
            msg.sender
        );
        if (userVotes == 0) revert NoVotes();

        _freezeProposalVoteCount += userVotes;

        emit FreezeVoteCast(msg.sender, userVotes);
    }

    function _getVotesAndUpdateHasVoted(
        address[] calldata _tokenAddresses,
        uint256[] calldata _tokenIds,
        address _voter
    ) internal virtual returns (uint256) {
        uint256 votes = 0;

        for (uint256 i = 0; i < _tokenAddresses.length; i++) {
            address tokenAddress = _tokenAddresses[i];
            uint256 tokenId = _tokenIds[i];

            if (_voter != IERC721(tokenAddress).ownerOf(tokenId)) {
                continue;
            }

            if (
                _idHasFreezeVoted[_freezeProposalCreated][tokenAddress][tokenId]
            ) {
                continue;
            }

            votes += _strategy.getTokenWeight(tokenAddress);

            _idHasFreezeVoted[_freezeProposalCreated][tokenAddress][
                tokenId
            ] = true;
        }

        return votes;
    }

    function version() public view virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(IERC721FreezeVotingV1).interfaceId ||
            interfaceId == type(IBaseFreezeVotingV1).interfaceId ||
            interfaceId == type(IVersion).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
