// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IStrategyV1} from "../../interfaces/decent/deployables/IStrategyV1.sol";
import {IBaseVotingAdapterV1} from "../../interfaces/decent/deployables/IBaseVotingAdapterV1.sol";
import {IProposerAdapterV1} from "../../interfaces/decent/deployables/IProposerAdapterV1.sol";
import {IERC4337VoterSupportV1} from "../../interfaces/decent/deployables/IERC4337VoterSupportV1.sol";
import {ISmartAccountValidationV1} from "../../interfaces/decent/deployables/ISmartAccountValidationV1.sol";
import {IVersion} from "../../interfaces/decent/deployables/IVersion.sol";
import {Version} from "../Version.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {ERC4337VoterSupportV1} from "./ERC4337VoterSupportV1.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract StrategyV1 is
    IStrategyV1,
    Initializable,
    ERC4337VoterSupportV1,
    Version,
    ERC165
{
    uint16 public constant VERSION = 1;

    uint256 public constant BASIS_DENOMINATOR = 1_000_000;

    address internal _proposalInitializer;
    uint32 internal _votingPeriod;
    uint256 internal _quorumThreshold;
    uint256 internal _basisNumerator;
    mapping(uint32 => ProposalVotingDetails) internal _proposalVotingDetails;

    address[] internal _votingAdapters;
    address[] internal _proposerAdapters;
    mapping(address => bool) internal _isVotingAdapter;
    mapping(address => bool) internal _isProposerAdapter;

    modifier onlyProposalInitializer() {
        if (msg.sender != _proposalInitializer)
            revert InvalidProposalInitializer();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address proposalInitializer_,
        uint32 votingPeriod_,
        uint256 quorumThreshold_,
        uint256 basisNumerator_,
        address[] calldata votingAdapters_,
        address[] calldata proposerAdapters_,
        address lightAccountFactory_
    ) public virtual override initializer {
        if (votingAdapters_.length == 0) {
            revert NoVotingAdapters();
        }

        if (proposerAdapters_.length == 0) {
            revert NoProposerAdapters();
        }

        if (
            basisNumerator_ >= BASIS_DENOMINATOR ||
            basisNumerator_ < BASIS_DENOMINATOR / 2
        ) revert InvalidBasisNumerator();

        __ERC4337VoterSupportV1_init(lightAccountFactory_);
        _proposalInitializer = proposalInitializer_;
        _votingPeriod = votingPeriod_;
        _quorumThreshold = quorumThreshold_;
        _basisNumerator = basisNumerator_;
        _votingAdapters = votingAdapters_;
        _proposerAdapters = proposerAdapters_;

        for (uint256 i = 0; i < votingAdapters_.length; i++) {
            _isVotingAdapter[votingAdapters_[i]] = true;
        }
        for (uint256 i = 0; i < proposerAdapters_.length; i++) {
            _isProposerAdapter[proposerAdapters_[i]] = true;
        }
    }

    function proposalInitializer()
        external
        view
        virtual
        override
        returns (address)
    {
        return _proposalInitializer;
    }

    function votingPeriod() external view virtual override returns (uint32) {
        return _votingPeriod;
    }

    function quorumThreshold()
        external
        view
        virtual
        override
        returns (uint256)
    {
        return _quorumThreshold;
    }

    function basisNumerator() external view virtual override returns (uint256) {
        return _basisNumerator;
    }

    function proposalVotingDetails(
        uint32 proposalId
    ) external view virtual override returns (ProposalVotingDetails memory) {
        return _proposalVotingDetails[proposalId];
    }

    function votingAdapters()
        external
        view
        virtual
        override
        returns (address[] memory)
    {
        return _votingAdapters;
    }

    function isVotingAdapter(
        address votingAdapter_
    ) external view virtual override returns (bool) {
        return _isVotingAdapter[votingAdapter_];
    }

    function isProposerAdapter(
        address proposerAdapter_
    ) external view virtual override returns (bool) {
        return _isProposerAdapter[proposerAdapter_];
    }

    function proposerAdapters()
        external
        view
        virtual
        override
        returns (address[] memory)
    {
        return _proposerAdapters;
    }

    function initializeProposal(
        uint32 proposalId,
        bytes32[] calldata,
        bytes calldata
    ) external virtual override onlyProposalInitializer {
        ProposalVotingDetails storage proposal = _proposalVotingDetails[
            proposalId
        ];
        proposal.votingStartTimestamp = uint48(block.timestamp);
        proposal.votingEndTimestamp = uint48(block.timestamp + _votingPeriod);
        proposal.votingStartBlock = uint32(block.number);
        proposal.yesVotes = 0;
        proposal.noVotes = 0;
        proposal.abstainVotes = 0;

        emit ProposalInitialized(
            proposalId,
            proposal.votingStartTimestamp,
            proposal.votingEndTimestamp,
            proposal.votingStartBlock
        );
    }

    function vote(
        uint32 _proposalId,
        uint8 _voteType,
        address[] calldata _votingAdaptersToUse,
        bytes[] calldata _votingAdapterVoteData
    ) external virtual override {
        if (_votingAdaptersToUse.length != _votingAdapterVoteData.length)
            revert MismatchedInputs();

        address resolvedVoter = voter(msg.sender);
        ProposalVotingDetails storage proposal = _proposalVotingDetails[
            _proposalId
        ];

        if (
            proposal.votingEndTimestamp == 0 ||
            block.timestamp > proposal.votingEndTimestamp
        ) {
            revert ProposalNotFoundOrNotActive();
        }

        uint256 totalWeightForThisVoteTransaction = 0;

        for (uint256 i = 0; i < _votingAdaptersToUse.length; i++) {
            address votingAdapter = _votingAdaptersToUse[i];

            if (!_isVotingAdapter[votingAdapter]) {
                revert InvalidVotingAdapter();
            }

            totalWeightForThisVoteTransaction += IBaseVotingAdapterV1(
                votingAdapter
            ).recordVote(resolvedVoter, _proposalId, _votingAdapterVoteData[i]);
        }

        if (totalWeightForThisVoteTransaction == 0) revert NoVotingWeight();

        if (_voteType == uint8(VoteType.YES)) {
            proposal.yesVotes += totalWeightForThisVoteTransaction;
        } else if (_voteType == uint8(VoteType.NO)) {
            proposal.noVotes += totalWeightForThisVoteTransaction;
        } else if (_voteType == uint8(VoteType.ABSTAIN)) {
            proposal.abstainVotes += totalWeightForThisVoteTransaction;
        } else {
            revert InvalidVoteType();
        }

        emit Voted(
            resolvedVoter,
            _proposalId,
            VoteType(_voteType),
            totalWeightForThisVoteTransaction
        );
    }

    function isQuorumMet(
        uint32 _proposalId
    ) public view virtual override returns (bool) {
        ProposalVotingDetails storage proposal = _proposalVotingDetails[
            _proposalId
        ];

        if (proposal.votingEndTimestamp == 0) {
            revert ProposalNotInitialized();
        }

        uint256 totalVotesForQuorum = proposal.yesVotes + proposal.abstainVotes;
        return totalVotesForQuorum >= _quorumThreshold;
    }

    function isBasisMet(
        uint32 _proposalId
    ) public view virtual override returns (bool) {
        ProposalVotingDetails storage proposal = _proposalVotingDetails[
            _proposalId
        ];

        if (proposal.votingEndTimestamp == 0) {
            revert ProposalNotInitialized();
        }

        return
            (proposal.yesVotes * BASIS_DENOMINATOR) >
            ((proposal.yesVotes + proposal.noVotes) * _basisNumerator);
    }

    function isPassed(
        uint32 _proposalId
    ) external view virtual override returns (bool) {
        ProposalVotingDetails storage proposal = _proposalVotingDetails[
            _proposalId
        ];

        if (proposal.votingEndTimestamp == 0) {
            revert ProposalNotInitialized();
        }

        if (block.timestamp <= proposal.votingEndTimestamp) {
            return false;
        }

        return isQuorumMet(_proposalId) && isBasisMet(_proposalId);
    }

    function isProposer(
        address address_,
        address proposerAdapter_,
        bytes calldata proposerAdapterData_
    ) external view virtual override returns (bool) {
        if (!_isProposerAdapter[proposerAdapter_]) {
            revert InvalidProposerAdapter(proposerAdapter_);
        }

        return
            IProposerAdapterV1(proposerAdapter_).isProposer(
                address_,
                proposerAdapterData_
            );
    }

    function getVotingTimestamps(
        uint32 _proposalId
    )
        external
        view
        virtual
        override
        returns (uint48 startTime, uint48 endTime)
    {
        ProposalVotingDetails storage details = _proposalVotingDetails[
            _proposalId
        ];
        if (details.votingEndTimestamp == 0) revert ProposalNotInitialized();
        return (details.votingStartTimestamp, details.votingEndTimestamp);
    }

    function getVotingStartBlock(
        uint32 _proposalId
    ) external view virtual override returns (uint32 votingStartBlock) {
        ProposalVotingDetails storage details = _proposalVotingDetails[
            _proposalId
        ];
        if (details.votingEndTimestamp == 0) revert ProposalNotInitialized();
        return details.votingStartBlock;
    }

    function version() public view virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(IStrategyV1).interfaceId ||
            interfaceId == type(IERC4337VoterSupportV1).interfaceId ||
            interfaceId == type(ISmartAccountValidationV1).interfaceId ||
            interfaceId == type(IVersion).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
