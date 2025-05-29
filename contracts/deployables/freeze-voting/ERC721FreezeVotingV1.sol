// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IERC721VotingStrategyV1} from "../../interfaces/decent/deployables/IERC721VotingStrategyV1.sol";
import {BaseFreezeVotingV1} from "./BaseFreezeVotingV1.sol";
import {Version} from "../Version.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract ERC721FreezeVotingV1 is BaseFreezeVotingV1, Version {
    uint16 private constant VERSION = 1;

    IERC721VotingStrategyV1 public strategy;

    mapping(uint256 => mapping(address => mapping(uint256 => bool)))
        public idHasFreezeVoted;

    event ERC721FreezeVotingSetUp(
        address indexed owner,
        address indexed strategy
    );

    error NoVotes();
    error NotSupported();
    error UnequalArrays();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _owner,
        uint256 _freezeVotesThreshold,
        uint32 _freezeProposalPeriod,
        uint32 _freezePeriod,
        address _strategy
    ) public virtual initializer {
        __BaseFreezeVotingV1_init(
            _owner,
            _freezeProposalPeriod,
            _freezePeriod,
            _freezeVotesThreshold
        );
        strategy = IERC721VotingStrategyV1(_strategy);

        emit ERC721FreezeVotingSetUp(_owner, _strategy);
    }

    function castFreezeVote() external pure virtual override {
        revert NotSupported();
    }

    function castFreezeVote(
        address[] memory _tokenAddresses,
        uint256[] memory _tokenIds
    ) external virtual {
        if (_tokenAddresses.length != _tokenIds.length) revert UnequalArrays();

        if (block.timestamp > freezeProposalCreated + freezeProposalPeriod) {
            freezeProposalCreated = uint48(block.timestamp);
            freezeProposalVoteCount = 0;
            emit FreezeProposalCreated(msg.sender);
        }

        uint256 userVotes = _getVotesAndUpdateHasVoted(
            _tokenAddresses,
            _tokenIds,
            msg.sender
        );
        if (userVotes == 0) revert NoVotes();

        freezeProposalVoteCount += userVotes;

        emit FreezeVoteCast(msg.sender, userVotes);
    }

    function _getVotesAndUpdateHasVoted(
        address[] memory _tokenAddresses,
        uint256[] memory _tokenIds,
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
                idHasFreezeVoted[freezeProposalCreated][tokenAddress][tokenId]
            ) {
                continue;
            }

            votes += strategy.getTokenWeight(tokenAddress);

            idHasFreezeVoted[freezeProposalCreated][tokenAddress][
                tokenId
            ] = true;
        }

        return votes;
    }

    function getVersion() public view virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(BaseFreezeVotingV1, Version) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
