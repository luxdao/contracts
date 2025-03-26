// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.28;

import {IBaseStrategyV1} from "../interfaces/decent/deployables/IBaseStrategyV1.sol";

contract MockVotingStrategy is IBaseStrategyV1 {
    address public proposer;
    mapping(uint32 => bool) private _isPassed;
    mapping(uint32 => uint48) private _votingEndTimestamp;

    constructor(address _proposer) {
        proposer = _proposer;
    }

    // required by IBaseStrategyV1

    function initializeProposal(bytes memory _data) external override {}

    function isPassed(uint32 proposalId) external view override returns (bool) {
        return _isPassed[proposalId];
    }

    function isProposer(
        address _proposer
    ) external view override returns (bool) {
        return _proposer == proposer;
    }

    function votingEndTimestamp(
        uint32 proposalId
    ) external view override returns (uint48) {
        return _votingEndTimestamp[proposalId];
    }

    // setters, for testing

    function setVotingEndTimestamp(
        uint32 proposalId,
        uint48 endTimestamp
    ) external {
        _votingEndTimestamp[proposalId] = endTimestamp;
    }

    function setIsPassed(uint32 proposalId, bool passed) external {
        _isPassed[proposalId] = passed;
    }
}
