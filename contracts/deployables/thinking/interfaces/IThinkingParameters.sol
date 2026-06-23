// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

/// @notice The value-deciding-governance views the observatory reads from
/// {ThinkingParameters}. Round/status mirror the contract's ABI exactly so
/// getRound decodes. Minimal by design — just enough to make the parameter
/// decisions visible from the single on-chain visibility surface.
interface IThinkingParameters {
    enum Status { None, Open, Settled, Failed }

    struct Round {
        bytes32 modelSpecHash;
        bytes32 promptHash;
        string knobKey;
        uint256 lo;
        uint256 hi;
        uint8 n;
        uint8 threshold;
        uint64 openedAt;
        uint64 deadline;
        address opener;
        Status status;
        uint8 submissionCount;
        uint256 canonicalValue;
    }

    function roundCount() external view returns (uint256);

    function getRound(uint256 roundId) external view returns (Round memory);

    function valueOf(bytes32 modelSpecHash, string calldata knobKey) external view returns (uint256 value, bool decided);
}
