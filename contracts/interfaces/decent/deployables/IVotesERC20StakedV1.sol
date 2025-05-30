// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IVotesERC20StakedV1 {
    struct StakerData {
        uint256 stakedAmount;
        uint256 lastStakeTimestamp;
    }

    struct RewardsTokenData {
        bool enabled;
        uint256 rewardsRate;
        uint256 rewardsDistributed;
        uint256 rewardsClaimed;
        mapping(address staker => uint256 rewardRate) stakerRewardsRates;
        mapping(address staker => uint256 accumulatedRewards) stakerAccumulatedRewards;
    }

    event MinimumStakingPeriodUpdated(uint256 newMinimumStakingPeriod);
    event Staked(address indexed staker, uint256 amount);
    event Unstaked(address indexed staker, uint256 amount);
    event RewardsTokenAdded(address indexed token);

    error NonTransferable();
    error ZeroStake();
    error ZeroUnstake();
    error InvalidRewardsToken();
    error DuplicateRewardsToken();
    error MinimumStakingPeriod();

    function initialize(
        string memory name,
        string memory symbol,
        address owner,
        address _stakedToken,
        uint256 _minimumStakingPeriod,
        address[] memory _rewardsTokens
    ) external;

    function addRewardsTokens(address[] memory rewardsTokens_) external;

    function updateMinimumStakingPeriod(
        uint256 newMinimumStakingPeriod
    ) external;

    function stake(uint256 amount) external;

    function unstake(uint256 amount) external;

    function clock() external view returns (uint48);

    function CLOCK_MODE() external pure returns (string memory);

    function stakedToken() external view returns (address);

    function minimumStakingPeriod() external view returns (uint256);

    function totalStaked() external view returns (uint256);

    function rewardsTokens() external view returns (address[] memory);

    function rewardsTokenData(
        address token
    )
        external
        view
        returns (
            uint256 rewardsRate,
            uint256 rewardsDistributed,
            uint256 rewardsClaimed
        );

    function stakerData(
        address staker
    ) external view returns (uint256 stakedAmount, uint256 lastStakeTimestamp);

    function stakerRewardsData(
        address token,
        address staker
    ) external view returns (uint256 rewardRate, uint256 accumulatedRewards);
}
