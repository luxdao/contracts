// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IMintableV1 {
    event MaxTotalSupplyUpdated(uint256 newMaxTotalSupply);

    error ExceedMaxTotalSupply();
    error InvalidMaxTotalSupply();

    function maxTotalSupply() external view returns (uint256);

    function mint(address to, uint256 amount) external;
}
