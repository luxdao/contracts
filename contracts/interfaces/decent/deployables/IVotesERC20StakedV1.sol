// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IVotesERC20StakedV1 {
    // --- Errors ---

    error NonTransferable();
    error ZeroStake();
    error ZeroUnstake();
    error ZeroStaked();
    error InvalidRewardsToken(address token);
    error DuplicateRewardsToken();
    error MinimumStakingPeriod();
    error TransferFailed();

    // --- Structs ---

    struct Metadata {
        string name;
        string symbol;
    }

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

    // --- Events ---

    event MinimumStakingPeriodUpdated(uint256 newMinimumStakingPeriod);
    event Staked(address indexed staker, uint256 amount);
    event Unstaked(address indexed staker, uint256 amount);
    event RewardsTokenAdded(address indexed token);
    event RewardsDistributed(
        address indexed token,
        uint256 amount,
        uint256 newRate
    );
    event RewardsClaimed(
        address indexed staker,
        address indexed token,
        address indexed recipient,
        uint256 amount
    );

    // --- Initializer Functions ---

    function initialize(
        Metadata calldata metadata_,
        address owner_,
        address stakedToken_,
        uint256 minimumStakingPeriod_,
        address[] calldata rewardsTokens_
    ) external;

    // --- Pure Functions ---

    function CLOCK_MODE() external pure returns (string memory clockMode);

    // --- View Functions ---

    function clock() external view returns (uint48 clock);

    function stakedToken() external view returns (address stakedToken);

    function minimumStakingPeriod()
        external
        view
        returns (uint256 minimumStakingPeriod);

    function totalStaked() external view returns (uint256 totalStaked);

    function rewardsTokens()
        external
        view
        returns (address[] memory rewardsTokens);

    function rewardsTokenData(
        address token_
    )
        external
        view
        returns (
            uint256 rewardsRate,
            uint256 rewardsDistributed,
            uint256 rewardsClaimed
        );

    function distributableRewards()
        external
        view
        returns (uint256[] memory distributableRewards);

    function distributableRewards(
        address[] calldata rewardsTokens_
    ) external view returns (uint256[] memory distributableRewards);

    function stakerData(
        address staker_
    ) external view returns (uint256 stakedAmount, uint256 lastStakeTimestamp);

    function stakerRewardsData(
        address token_,
        address staker_
    ) external view returns (uint256 rewardRate, uint256 accumulatedRewards);

    function claimableRewards(
        address staker_
    ) external view returns (uint256[] memory claimableRewards);

    function claimableRewards(
        address staker_,
        address[] calldata tokens_
    ) external view returns (uint256[] memory claimableRewards);

    // --- State-Changing Functions ---

    function addRewardsTokens(address[] calldata rewardsTokens_) external;

    function updateMinimumStakingPeriod(
        uint256 newMinimumStakingPeriod_
    ) external;

    function stake(uint256 amount_) external;

    function unstake(uint256 amount_) external;

    function distributeRewards() external;

    function distributeRewards(address[] calldata tokens_) external;

    function claimRewards(address recipient_) external;

    function claimRewards(
        address recipient_,
        address[] calldata tokens_
    ) external;
}
