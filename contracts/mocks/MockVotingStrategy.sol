// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IStrategyV1} from "../interfaces/decent/deployables/IStrategyV1.sol";
import {IBaseVotingAdapterV1} from "../interfaces/decent/deployables/IBaseVotingAdapterV1.sol";

contract MockVotingStrategy is IStrategyV1 {
    struct TimestampPoints {
        uint48 startTimestamp;
        uint48 endTimestamp;
    }

    address public proposer;
    mapping(uint32 => bool) private _isPassed;
    mapping(uint32 => TimestampPoints) private _proposalTimestamps;
    mapping(uint32 => uint32) public mockVotingStartBlock;
    mapping(address => bool) private _isVotingAdapter;
    mapping(address => bool) private _isProposerAdapter;

    constructor(address _proposer) {
        proposer = _proposer;
    }

    function initializeProposal(
        uint32 _proposalId,
        bytes32[] memory _txHashes,
        bytes memory _data
    ) external override {}

    function isPassed(uint32 proposalId) external view override returns (bool) {
        return _isPassed[proposalId];
    }

    function isProposer(
        address _address,
        address,
        bytes memory
    ) external view override returns (bool) {
        return _address == proposer;
    }

    function getVotingTimestamps(
        uint32 proposalId
    ) external view override returns (uint48, uint48) {
        TimestampPoints memory timestamps = _proposalTimestamps[proposalId];
        return (timestamps.startTimestamp, timestamps.endTimestamp);
    }

    function getVotingStartBlock(
        uint32 _proposalId
    ) external view override returns (uint32 votingStartBlock) {
        return mockVotingStartBlock[_proposalId];
    }

    function isVotingAdapter(
        address votingAdapter_
    ) external view override returns (bool) {
        return _isVotingAdapter[votingAdapter_];
    }

    function isProposerAdapter(
        address proposerAdapter_
    ) external view override returns (bool) {
        return _isProposerAdapter[proposerAdapter_];
    }

    // mock setters

    function setIsPassed(uint32 proposalId, bool passed) external {
        _isPassed[proposalId] = passed;
    }

    function setVotingTimestamps(
        uint32 proposalId,
        uint48 startTimestamp,
        uint48 endTimestamp
    ) external {
        _proposalTimestamps[proposalId] = TimestampPoints(
            startTimestamp,
            endTimestamp
        );
    }

    function setVotingStartBlock(
        uint32 proposalId,
        uint32 startBlock
    ) external {
        mockVotingStartBlock[proposalId] = startBlock;
    }

    function setVotingAdapter(
        address votingAdapter_,
        bool isVotingAdapter_
    ) external {
        _isVotingAdapter[votingAdapter_] = isVotingAdapter_;
    }

    function setProposerAdapter(
        address proposerAdapter_,
        bool isProposerAdapter_
    ) external {
        _isProposerAdapter[proposerAdapter_] = isProposerAdapter_;
    }

    function initialize(
        address proposalInitializer_,
        uint32 votingPeriod_,
        uint256 quorumThreshold_,
        uint256 basisNumerator_,
        address[] memory votingAdapters_,
        address[] memory proposerAdapters_,
        address lightAccountFactory_
    ) external override {}

    function proposalInitializer() external view override returns (address) {}

    function votingPeriod() external view override returns (uint32) {}

    function quorumThreshold() external view override returns (uint256) {}

    function basisNumerator() external view override returns (uint256) {}

    function proposalVotingDetails(
        uint32 proposalId
    ) external view override returns (ProposalVotingDetails memory) {}

    function votingAdapters()
        external
        view
        override
        returns (address[] memory)
    {}

    function proposerAdapters()
        external
        view
        override
        returns (address[] memory)
    {}

    function isQuorumMet(
        uint32 _proposalId
    ) external view override returns (bool) {}

    function isBasisMet(
        uint32 _proposalId
    ) external view override returns (bool) {}

    function vote(
        uint32 _proposalId,
        uint8 /*_voteType*/,
        address[] calldata _votingAdaptersToUse,
        bytes[] calldata _votingAdapterVoteData
    ) external virtual override {
        for (uint256 i = 0; i < _votingAdaptersToUse.length; i++) {
            address adapterAddress = _votingAdaptersToUse[i];
            bytes calldata adapterData = _votingAdapterVoteData[i];

            IBaseVotingAdapterV1(adapterAddress).recordVote(
                msg.sender,
                _proposalId,
                adapterData
            );
        }
    }
}
