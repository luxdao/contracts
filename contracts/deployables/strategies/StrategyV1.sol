// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IStrategyV1} from "../../interfaces/decent/deployables/IStrategyV1.sol";
import {IStrategyBaseV1} from "../../interfaces/decent/deployables/IStrategyBaseV1.sol";
import {IVotingAdapterBaseV1} from "../../interfaces/decent/deployables/IVotingAdapterBaseV1.sol";
import {IProposerAdapterBaseV1} from "../../interfaces/decent/deployables/IProposerAdapterBaseV1.sol";
import {Version} from "../Version.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {ERC4337VoterSupportV1} from "./ERC4337VoterSupportV1.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract StrategyV1 is
    Initializable,
    IStrategyV1,
    ERC165,
    ERC4337VoterSupportV1,
    Version
{
    uint16 public constant VERSION = 1;

    address public azorius;
    uint32 public votingPeriod;
    uint256 public quorumThreshold;
    uint256 public basisNumerator;

    uint256 public constant BASIS_DENOMINATOR = 1_000_000;

    struct ProposalVotingDetails {
        uint48 votingStartTimestamp;
        uint48 votingEndTimestamp;
        uint32 votingStartBlock;
        uint256 yesVotes;
        uint256 noVotes;
        uint256 abstainVotes;
    }
    mapping(uint32 => ProposalVotingDetails) public proposalVotingDetails;

    IVotingAdapterBaseV1[] public votingAdapters;
    IProposerAdapterBaseV1[] public proposerAdapters;

    enum VoteType {
        NO,
        YES,
        ABSTAIN
    }

    event Voted(
        address indexed voter,
        uint32 indexed proposalId,
        VoteType voteType,
        uint256 totalWeightCastedInTx
    );
    event ProposalInitialized(
        uint32 indexed proposalId,
        uint48 votingStartTimestamp,
        uint48 votingEndTimestamp,
        uint32 votingStartBlock
    );

    error InvalidAzoriusAddress();
    error InvalidVotingPeriod();
    error InvalidBasisNumerator();
    error VotingAdapterIsZeroAddress();
    error VotingAdapterAlreadyExists();
    error NoVotingAdapters();
    error ProposerAdapterIsZeroAddress();
    error ProposerAdapterAlreadyExists();
    error ProposalNotFoundOrNotActive();
    error NoVotingWeight();
    error InvalidVoteType();
    error ProposalNotInitialized();
    error MismatchedInputs();
    error InvalidVotingAdapter();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _azorius,
        uint32 _votingPeriod,
        uint256 _quorumThreshold,
        uint256 _basisNumerator,
        address[] memory _votingAdapters,
        address[] memory _proposerAdapters,
        address _lightAccountFactory
    ) public virtual initializer {
        if (_azorius == address(0)) revert InvalidAzoriusAddress();

        __ERC4337VoterSupportV1_init(_lightAccountFactory);

        azorius = _azorius;

        if (_votingPeriod == 0) revert InvalidVotingPeriod();
        votingPeriod = _votingPeriod;

        quorumThreshold = _quorumThreshold;

        if (
            _basisNumerator >= BASIS_DENOMINATOR ||
            _basisNumerator < BASIS_DENOMINATOR / 2
        ) revert InvalidBasisNumerator();
        basisNumerator = _basisNumerator;

        for (uint256 i = 0; i < _votingAdapters.length; i++) {
            address _adapter = _votingAdapters[i];
            if (_adapter == address(0)) revert VotingAdapterIsZeroAddress();
            for (uint256 j = 0; j < votingAdapters.length; j++) {
                if (address(votingAdapters[j]) == _adapter)
                    revert VotingAdapterAlreadyExists();
            }
            votingAdapters.push(IVotingAdapterBaseV1(_adapter));
        }

        for (uint256 i = 0; i < _proposerAdapters.length; i++) {
            address _adapter = _proposerAdapters[i];
            if (_adapter == address(0)) revert ProposerAdapterIsZeroAddress();
            for (uint256 j = 0; j < proposerAdapters.length; j++) {
                if (address(proposerAdapters[j]) == _adapter)
                    revert ProposerAdapterAlreadyExists();
            }
            proposerAdapters.push(IProposerAdapterBaseV1(_adapter));
        }
    }

    function getVotingAdapterCount()
        external
        view
        virtual
        override
        returns (uint256)
    {
        return votingAdapters.length;
    }

    function getProposerAdapterCount()
        external
        view
        virtual
        override
        returns (uint256)
    {
        return proposerAdapters.length;
    }

    function initializeProposal(
        uint32 proposalId,
        bytes32[] memory,
        bytes memory
    ) external virtual override {
        if (msg.sender != azorius) revert InvalidAzoriusAddress();
        if (votingAdapters.length == 0) revert NoVotingAdapters();

        ProposalVotingDetails storage proposal = proposalVotingDetails[
            proposalId
        ];
        proposal.votingStartTimestamp = uint48(block.timestamp);
        proposal.votingEndTimestamp = uint48(block.timestamp + votingPeriod);
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
        ProposalVotingDetails storage proposal = proposalVotingDetails[
            _proposalId
        ];

        if (
            proposal.votingEndTimestamp == 0 ||
            block.timestamp > proposal.votingEndTimestamp
        ) {
            revert ProposalNotFoundOrNotActive();
        }

        uint256 totalWeightForThisVoteTransaction = 0;
        uint256 numConfiguredAdapters = votingAdapters.length;

        for (uint256 i = 0; i < _votingAdaptersToUse.length; i++) {
            bool isValidAndConfiguredAdapter = false;
            uint256 configuredAdapterIndex = 0;

            for (uint256 j = 0; j < numConfiguredAdapters; j++) {
                if (
                    votingAdapters[j] ==
                    IVotingAdapterBaseV1(_votingAdaptersToUse[i])
                ) {
                    isValidAndConfiguredAdapter = true;
                    configuredAdapterIndex = j;
                    break;
                }
            }

            if (!isValidAndConfiguredAdapter) {
                revert InvalidVotingAdapter();
            }

            totalWeightForThisVoteTransaction += votingAdapters[
                configuredAdapterIndex
            ].recordVote(resolvedVoter, _proposalId, _votingAdapterVoteData[i]);
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
        ProposalVotingDetails storage proposal = proposalVotingDetails[
            _proposalId
        ];

        if (proposal.votingEndTimestamp == 0) {
            revert ProposalNotInitialized();
        }

        uint256 totalVotesForQuorum = proposal.yesVotes + proposal.abstainVotes;
        return totalVotesForQuorum >= quorumThreshold;
    }

    function isBasisMet(
        uint32 _proposalId
    ) public view virtual override returns (bool) {
        ProposalVotingDetails storage proposal = proposalVotingDetails[
            _proposalId
        ];

        if (proposal.votingEndTimestamp == 0) {
            revert ProposalNotInitialized();
        }

        return
            (proposal.yesVotes * BASIS_DENOMINATOR) >
            ((proposal.yesVotes + proposal.noVotes) * basisNumerator);
    }

    function isPassed(
        uint32 _proposalId
    ) external view virtual override returns (bool) {
        ProposalVotingDetails storage proposal = proposalVotingDetails[
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
        address _address
    ) external view virtual override returns (bool) {
        if (proposerAdapters.length == 0) return false;
        for (uint256 i = 0; i < proposerAdapters.length; i++) {
            if (proposerAdapters[i].isProposer(_address)) {
                return true;
            }
        }
        return false;
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
        ProposalVotingDetails storage details = proposalVotingDetails[
            _proposalId
        ];
        if (details.votingEndTimestamp == 0) revert ProposalNotInitialized();
        return (details.votingStartTimestamp, details.votingEndTimestamp);
    }

    function getVotingStartBlock(
        uint32 _proposalId
    ) external view virtual override returns (uint32 votingStartBlock) {
        ProposalVotingDetails storage details = proposalVotingDetails[
            _proposalId
        ];
        if (details.votingEndTimestamp == 0) revert ProposalNotInitialized();
        return details.votingStartBlock;
    }

    function getVersion() public view virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC165, Version) returns (bool) {
        return
            interfaceId == type(IStrategyV1).interfaceId ||
            interfaceId == type(IStrategyBaseV1).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
