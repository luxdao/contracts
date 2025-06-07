// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IERC20VotingAdapterV1} from "../../../interfaces/decent/deployables/IERC20VotingAdapterV1.sol";
import {IBaseVotingAdapterV1} from "../../../interfaces/decent/deployables/IBaseVotingAdapterV1.sol";
import {ClockMode} from "../../../interfaces/decent/ClockMode.sol";
import {IVersion} from "../../../interfaces/decent/deployables/IVersion.sol";
import {BaseVotingAdapterV1} from "./BaseVotingAdapterV1.sol";
import {Version} from "../../Version.sol";
import {ClockModeLib} from "../../../libs/ClockModeLib.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

contract ERC20VotingAdapterV1 is
    IERC20VotingAdapterV1,
    BaseVotingAdapterV1,
    ERC165,
    Version
{
    uint16 public constant VERSION = 1;

    IVotes internal _token;
    uint256 internal _weightPerToken;
    ClockMode internal _tokenClockMode;
    mapping(uint32 => mapping(address => bool))
        internal _hasCastedVoteForProposal;
    mapping(address => mapping(uint48 => mapping(address => bool)))
        internal _hasCastedVotePerFreezeVoteProposalPerFreezeVoteContract;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address token_,
        address strategy_,
        uint256 weightPerToken_
    ) external virtual override initializer {
        __BaseVotingAdapterV1_init(strategy_);
        _token = IVotes(token_);
        _weightPerToken = weightPerToken_;
        _tokenClockMode = ClockModeLib.getClockMode(token_);
    }

    function token() external view virtual override returns (address) {
        return address(_token);
    }

    function weightPerToken() external view virtual override returns (uint256) {
        return _weightPerToken;
    }

    function hasCastedVoteForProposal(
        uint32 proposalId,
        address voter
    ) external view virtual override returns (bool) {
        return _hasCastedVoteForProposal[proposalId][voter];
    }

    function hasCastedVotePerFreezeVoteProposalPerFreezeVoteContract(
        address freezeVoteContract,
        uint48 freezeProposalSnapshotAndId,
        address voter
    ) external view virtual override returns (bool) {
        return
            _hasCastedVotePerFreezeVoteProposalPerFreezeVoteContract[
                freezeVoteContract
            ][freezeProposalSnapshotAndId][voter];
    }

    function _calculateWeightAtSnapshot(
        address _voter,
        uint48 _snapshotTimepoint
    ) internal view virtual returns (uint256 weight) {
        return
            _token.getPastVotes(_voter, _snapshotTimepoint) * _weightPerToken;
    }

    function getFreezeVoteWeight(
        address voter,
        uint48 freezeProposalSnapshotAndId
    ) external view virtual override returns (uint256 weight) {
        weight = _calculateWeightAtSnapshot(voter, freezeProposalSnapshotAndId);
    }

    function recordFreezeVote(
        address voter,
        uint48 freezeProposalSnapshotAndId,
        bytes calldata
    )
        external
        virtual
        override
        onlyAuthorizedFreezeVoter
        returns (uint256 weightCasted)
    {
        if (
            _hasCastedVotePerFreezeVoteProposalPerFreezeVoteContract[
                msg.sender
            ][freezeProposalSnapshotAndId][voter]
        ) {
            revert AlreadyVoted();
        }

        weightCasted = _calculateWeightAtSnapshot(
            voter,
            freezeProposalSnapshotAndId
        );

        if (weightCasted == 0) {
            revert NoFreezeVotingWeight();
        }

        _hasCastedVotePerFreezeVoteProposalPerFreezeVoteContract[msg.sender][
            freezeProposalSnapshotAndId
        ][voter] = true;

        emit FreezeVoteRecorded(
            voter,
            freezeProposalSnapshotAndId,
            weightCasted,
            bytes("")
        );
    }

    function _getVoteWeightDetails(
        address _voter,
        uint32 _proposalId,
        bytes calldata
    ) internal view virtual returns (uint256 weight) {
        uint48 startTimepoint;
        if (_tokenClockMode == ClockMode.Timestamp) {
            (startTimepoint, ) = _strategy.getVotingTimestamps(_proposalId);
        } else {
            startTimepoint = _strategy.getVotingStartBlock(_proposalId);
        }

        if (startTimepoint == 0) revert ProposalNotReadyForSnapshot();
        weight = _calculateWeightAtSnapshot(_voter, startTimepoint);
    }

    function weightOf(
        address _voter,
        uint32 _proposalId,
        bytes calldata _voteData
    ) external view virtual override returns (uint256 weight) {
        if (_hasCastedVoteForProposal[_proposalId][_voter]) {
            return 0;
        }
        weight = _getVoteWeightDetails(_voter, _proposalId, _voteData);
    }

    function recordVote(
        address _voter,
        uint32 _proposalId,
        bytes calldata _voteData
    ) external virtual override onlyStrategy returns (uint256 weightCasted) {
        if (_hasCastedVoteForProposal[_proposalId][_voter]) {
            revert AlreadyVoted();
        }
        _hasCastedVoteForProposal[_proposalId][_voter] = true;

        weightCasted = _getVoteWeightDetails(_voter, _proposalId, _voteData);

        emit VoteRecorded(_voter, _proposalId, weightCasted, bytes(""));
    }

    function version() public pure virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(IERC20VotingAdapterV1).interfaceId ||
            interfaceId == type(IBaseVotingAdapterV1).interfaceId ||
            interfaceId == type(IVersion).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
