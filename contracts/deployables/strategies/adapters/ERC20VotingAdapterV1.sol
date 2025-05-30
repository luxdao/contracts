// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IERC20VotingAdapterV1} from "../../../interfaces/decent/deployables/IERC20VotingAdapterV1.sol";
import {IStrategyBaseV1} from "../../../interfaces/decent/deployables/IStrategyBaseV1.sol";
import {IVotingAdapterV1} from "../../../interfaces/decent/deployables/IVotingAdapterV1.sol";
import {IVotingAdapterBaseV1} from "../../../interfaces/decent/deployables/IVotingAdapterBaseV1.sol";
import {ClockMode} from "../../../interfaces/decent/ClockMode.sol";
import {Version} from "../../Version.sol";
import {ClockModeLib} from "../../../libs/ClockModeLib.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract ERC20VotingAdapterV1 is
    IERC20VotingAdapterV1,
    Initializable,
    ERC165,
    Version
{
    uint16 public constant VERSION = 1;

    IVotes internal _token;
    IStrategyBaseV1 internal _strategy;
    uint256 internal _weightPerToken;
    ClockMode internal _tokenClockMode;
    mapping(uint32 => mapping(address => bool))
        internal _hasCastedVoteForProposal;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address token_,
        address strategy_,
        uint256 weightPerToken_
    ) external virtual override initializer {
        _token = IVotes(token_);
        _strategy = IStrategyBaseV1(strategy_);
        _weightPerToken = weightPerToken_;
        _tokenClockMode = ClockModeLib.getClockMode(token_);
    }

    function token() external view virtual override returns (address) {
        return address(_token);
    }

    function strategy() external view virtual override returns (address) {
        return address(_strategy);
    }

    function weightPerToken() external view virtual override returns (uint256) {
        return _weightPerToken;
    }

    function _getVoteWeightDetails(
        address _voter,
        uint32 _proposalId
    ) internal view virtual returns (uint256 weight) {
        uint256 rawVotes;
        if (_tokenClockMode == ClockMode.Timestamp) {
            (uint48 startTimestamp, ) = _strategy.getVotingTimestamps(
                _proposalId
            );
            if (startTimestamp == 0) revert ProposalNotReadyForSnapshot();
            rawVotes = _token.getPastVotes(_voter, startTimestamp);
        } else {
            uint32 startBlock = _strategy.getVotingStartBlock(_proposalId);
            if (startBlock == 0) revert ProposalNotReadyForSnapshot();
            rawVotes = _token.getPastVotes(_voter, startBlock);
        }
        weight = rawVotes * _weightPerToken;
    }

    function weightOf(
        address _voter,
        uint32 _proposalId,
        bytes calldata
    ) external view virtual override returns (uint256 weight) {
        if (_hasCastedVoteForProposal[_proposalId][_voter]) {
            return 0;
        }
        weight = _getVoteWeightDetails(_voter, _proposalId);
    }

    function recordVote(
        address _voter,
        uint32 _proposalId,
        bytes calldata
    ) external virtual override returns (uint256 weightCasted) {
        if (_hasCastedVoteForProposal[_proposalId][_voter]) {
            revert AlreadyVoted();
        }
        _hasCastedVoteForProposal[_proposalId][_voter] = true;

        weightCasted = _getVoteWeightDetails(_voter, _proposalId);

        emit VoteRecorded(_voter, _proposalId, weightCasted, bytes(""));
    }

    function version() public pure virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC165, Version) returns (bool) {
        return
            interfaceId == type(IERC20VotingAdapterV1).interfaceId ||
            interfaceId == type(IVotingAdapterV1).interfaceId ||
            interfaceId == type(IVotingAdapterBaseV1).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
