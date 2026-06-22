// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

/// @notice The economics views the observatory reads from {AICoin}. Minimal by
/// design — only the halving-schedule + supply surface needed to make the
/// thinking chain's economic behavior visible on-chain.
interface IAICoin {
    function MAX_SUBSIDY() external view returns (uint256);

    function epoch() external view returns (uint256);

    function epochSubsidy() external view returns (uint256);

    function cumulativeAllowance() external view returns (uint256);

    function mintedSubsidy() external view returns (uint256);

    function remainingSubsidy() external view returns (uint256);

    function totalSupply() external view returns (uint256);
}
