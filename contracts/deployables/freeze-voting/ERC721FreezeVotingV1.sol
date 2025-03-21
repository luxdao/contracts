// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.28;

import {IERC721VotingStrategyV1} from "../../interfaces/decent/deployables/IERC721VotingStrategyV1.sol";
import {BaseFreezeVotingV1} from "./BaseFreezeVotingV1.sol";
import {Version} from "../Version.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/**
 * A [BaseFreezeVoting](./BaseFreezeVoting.md) implementation which handles
 * freezes on ERC721 based token voting DAOs.
 */
contract ERC721FreezeVotingV1 is BaseFreezeVotingV1, Version {
    uint16 private constant VERSION = 1;

    /** A reference to the voting strategy of the parent DAO. */
    IERC721VotingStrategyV1 public strategy;

    /**
     * Mapping of block the freeze vote was started on, to the token address, to token id,
     * to whether that token has been used to vote already.
     */
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

    /**
     * Initialize function, will be triggered when a new instance is deployed.
     *
     * @param _owner The owner of the contract
     * @param _freezeVotesThreshold The number of votes required to activate a freeze
     * @param _freezeProposalPeriod The number of blocks a freeze proposal has to succeed
     * @param _freezePeriod The number of blocks a freeze lasts
     * @param _strategy The address of the voting strategy
     */
    function initialize(
        address _owner,
        uint256 _freezeVotesThreshold,
        uint32 _freezeProposalPeriod,
        uint32 _freezePeriod,
        address _strategy
    ) public initializer {
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
        _updateFreezeVotesThreshold(_freezeVotesThreshold);
        _updateFreezeProposalPeriod(_freezeProposalPeriod);
        _updateFreezePeriod(_freezePeriod);
        strategy = IERC721VotingStrategyV1(_strategy);

        emit ERC721FreezeVotingSetUp(_owner, _strategy);
    }

    /**
     * @dev Function that authorizes an upgrade. Only the owner can upgrade the implementation.
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal virtual override onlyOwner {}

    /** @inheritdoc BaseFreezeVotingV1*/
    function castFreezeVote() external pure override {
        revert NotSupported();
    }

    function castFreezeVote(
        address[] memory _tokenAddresses,
        uint256[] memory _tokenIds
    ) external {
        if (_tokenAddresses.length != _tokenIds.length) revert UnequalArrays();

        if (block.number > freezeProposalCreatedBlock + freezeProposalPeriod) {
            // create a new freeze proposal
            freezeProposalCreatedBlock = uint32(block.number);
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
    ) internal returns (uint256) {
        uint256 votes = 0;

        for (uint256 i = 0; i < _tokenAddresses.length; i++) {
            address tokenAddress = _tokenAddresses[i];
            uint256 tokenId = _tokenIds[i];

            if (_voter != IERC721(tokenAddress).ownerOf(tokenId)) continue;

            if (
                idHasFreezeVoted[freezeProposalCreatedBlock][tokenAddress][
                    tokenId
                ]
            ) continue;

            votes += strategy.getTokenWeight(tokenAddress);

            idHasFreezeVoted[freezeProposalCreatedBlock][tokenAddress][
                tokenId
            ] = true;
        }

        return votes;
    }

    /// Implementation for the version
    function getVersion() public view virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(BaseFreezeVotingV1, Version) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
