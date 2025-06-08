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

    address internal _strategyAdmin;
    uint32 internal _votingPeriod;
    uint256 internal _quorumThreshold;
    uint256 internal _basisNumerator;
    mapping(uint32 => ProposalVotingDetails) internal _proposalVotingDetails;

    address[] internal _votingAdapters;
    address[] internal _proposerAdapters;
    mapping(address => bool) internal _isVotingAdapter;
    mapping(address => bool) internal _isProposerAdapter;

    mapping(address => bool) internal _authorizedFreezeVotersMapping;
    address[] internal _authorizedFreezeVotersArray;

    mapping(uint32 => bool) internal _votingPeriodEnded;

    modifier onlyStrategyAdmin() {
        if (msg.sender != _strategyAdmin) revert InvalidStrategyAdmin();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address strategyAdmin_,
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
        _strategyAdmin = strategyAdmin_;
        _votingPeriod = votingPeriod_;
        _quorumThreshold = quorumThreshold_;
        _basisNumerator = basisNumerator_;
        _votingAdapters = votingAdapters_;
        _proposerAdapters = proposerAdapters_;

        for (uint256 i = 0; i < votingAdapters_.length; ) {
            _isVotingAdapter[votingAdapters_[i]] = true;
            unchecked {
                ++i;
            }
        }
        for (uint256 i = 0; i < proposerAdapters_.length; ) {
            _isProposerAdapter[proposerAdapters_[i]] = true;
            unchecked {
                ++i;
            }
        }
    }

    function strategyAdmin() external view virtual override returns (address) {
        return _strategyAdmin;
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

    function votingPeriodEnded(
        uint32 _proposalId
    ) external view virtual override returns (bool) {
        return _votingPeriodEnded[_proposalId];
    }

    function initializeProposal(
        uint32 proposalId,
        bytes32[] calldata,
        bytes calldata
    ) external virtual override onlyStrategyAdmin {
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
        VotingAdapterVoteData[] calldata votingAdaptersData
    ) external virtual override {
        address resolvedVoter = voter(msg.sender);
        ProposalVotingDetails storage proposal = _proposalVotingDetails[
            _proposalId
        ];

        if (proposal.votingEndTimestamp == 0) {
            revert ProposalNotInitialized();
        }

        if (block.timestamp > proposal.votingEndTimestamp) {
            if (!_votingPeriodEnded[_proposalId]) {
                _votingPeriodEnded[_proposalId] = true;
                emit VotingPeriodEnded(
                    _proposalId,
                    proposal.votingEndTimestamp,
                    uint48(block.timestamp)
                );
                return;
            }
            revert ProposalNotActive();
        }

        uint256 totalWeightForThisVoteTransaction = 0;

        for (uint256 i = 0; i < votingAdaptersData.length; ) {
            VotingAdapterVoteData
                memory votingAdapterVoteData = votingAdaptersData[i];
            address votingAdapter = votingAdapterVoteData.votingAdapter;

            if (!_isVotingAdapter[votingAdapter]) {
                revert InvalidVotingAdapter();
            }

            totalWeightForThisVoteTransaction += IBaseVotingAdapterV1(
                votingAdapter
            ).recordVote(
                    resolvedVoter,
                    _proposalId,
                    votingAdapterVoteData.adapterVoteData
                );

            unchecked {
                ++i;
            }
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

    function addAuthorizedFreezeVoter(
        address freezeVoterContract
    ) external virtual override onlyStrategyAdmin {
        if (freezeVoterContract == address(0)) revert InvalidAddress();
        if (!_authorizedFreezeVotersMapping[freezeVoterContract]) {
            _authorizedFreezeVotersArray.push(freezeVoterContract);
        }
        _authorizedFreezeVotersMapping[freezeVoterContract] = true;
        emit FreezeVoterAuthorizationChanged(freezeVoterContract, true);
    }

    function removeAuthorizedFreezeVoter(
        address freezeVoterContract
    ) external virtual override onlyStrategyAdmin {
        if (freezeVoterContract == address(0)) revert InvalidAddress();
        if (_authorizedFreezeVotersMapping[freezeVoterContract]) {
            for (uint256 i = 0; i < _authorizedFreezeVotersArray.length; ) {
                if (_authorizedFreezeVotersArray[i] == freezeVoterContract) {
                    _authorizedFreezeVotersArray[
                        i
                    ] = _authorizedFreezeVotersArray[
                        _authorizedFreezeVotersArray.length - 1
                    ];
                    _authorizedFreezeVotersArray.pop();
                    break;
                }
                unchecked {
                    ++i;
                }
            }
        }
        _authorizedFreezeVotersMapping[freezeVoterContract] = false;
        emit FreezeVoterAuthorizationChanged(freezeVoterContract, false);
    }

    function isAuthorizedFreezeVoter(
        address freezeVoterContract
    ) external view virtual override returns (bool) {
        return _authorizedFreezeVotersMapping[freezeVoterContract];
    }

    function authorizedFreezeVoters()
        external
        view
        virtual
        override
        returns (address[] memory)
    {
        return _authorizedFreezeVotersArray;
    }

    function validStrategyVote(
        address voter_,
        uint32 proposalId_,
        uint8 voteType_,
        VotingAdapterVoteData[] calldata votingAdaptersData_
    ) external view virtual override returns (bool) {
        // get the proposal start and end timestamps to determine if the proposal exists
        ProposalVotingDetails storage details = _proposalVotingDetails[
            proposalId_
        ];

        // Check if proposal exists (will have non-zero endTimestamp if it exists)
        if (details.votingEndTimestamp == 0) {
            return false;
        }

        // Check if voting period has ended
        if (_votingPeriodEnded[proposalId_]) {
            return false;
        }

        // Check if vote type is valid (NO=0, YES=1, ABSTAIN=2)
        if (voteType_ > 2) {
            return false;
        }

        uint256 totalVotingWeight = 0;

        // loop through the voting adapters and check if the vote is valid
        for (uint256 i = 0; i < votingAdaptersData_.length; ) {
            VotingAdapterVoteData
                memory votingAdapterVoteData = votingAdaptersData_[i];
            address votingAdapter = votingAdapterVoteData.votingAdapter;

            // check if the voting adapter is attached to this strategy
            if (!_isVotingAdapter[votingAdapter]) {
                return false;
            }

            (bool isValid, uint256 votingWeight) = IBaseVotingAdapterV1(
                votingAdapter
            ).validVotingAdapterVote(
                    voter_,
                    proposalId_,
                    votingAdapterVoteData.adapterVoteData
                );

            if (!isValid) {
                return false;
            }

            totalVotingWeight += votingWeight;

            unchecked {
                ++i;
            }
        }

        if (totalVotingWeight == 0) {
            return false;
        }

        return true;
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
