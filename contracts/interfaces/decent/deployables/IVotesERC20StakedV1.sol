// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IVotesERC20StakedV1 {
    event MinimumStakingPeriodUpdated(uint256 newMinimumStakingPeriod);

    error NonTransferable();

    function initialize(
        string memory name,
        string memory symbol,
        address owner,
        address _stakedToken,
        uint256 _minimumStakingPeriod
    ) external;

    function updateMinimumStakingPeriod(
        uint256 newMinimumStakingPeriod
    ) external;

    function clock() external view returns (uint48);

    function CLOCK_MODE() external pure returns (string memory);

    function stakedToken() external view returns (address);

    function minimumStakingPeriod() external view returns (uint256);
}
