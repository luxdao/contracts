// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Version} from "../Version.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20VotesUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/**
 * Staking contract that immediately distributes rewards in full
 * to all stakers upon each distribution.
 */
contract VotesStakedERC20V1 is
    Version,
    ERC20VotesUpgradeable,
    UUPSUpgradeable,
    OwnableUpgradeable
{
    using SafeERC20 for IERC20;

    uint16 private constant VERSION = 1;
    IERC20 public stakedToken;
    uint256 public minimumStakingPeriod;
    uint256 public totalStaked;

    mapping(address staker => uint256 amount) public stakedAmount;
    mapping(address staker => uint256 timestamp) public lastStakeTimestamp;

    address[] private rewardsTokens;

    struct RewardsTokenData {
        bool enabled;
        uint256 totalRewardsRate;
        uint256 totalRewardsDistributed;
        uint256 totalRewardsClaimed;
        mapping(address staker => uint256 rewardRate) stakerRewardsRates;
        mapping(address staker => uint256 accumulatedRewards) stakerAccumulatedRewards;
    }

    mapping(address token => RewardsTokenData data) public rewardsTokenDatas;
    
    event MinimumStakingPeriodUpdated(uint256 newMinimumStakingPeriod);
    event Staked(address indexed staker, uint256 amount);
    event RewardsTokenAdded(address indexed token);

    error NonTransferable();
    error ZeroStake();

    constructor() {
        _disableInitializers();
    }

    /**
     * Initialize function, will be triggered when a new proxy instance is deployed.
     *
     * @param name Token name
     * @param symbol Token symbol
     * @param owner Address that will own the proxy and be able to upgrade it
     * @param _stakedToken Address of the token to be staked
     * @param _minimumStakingPeriod Minimum staking period in seconds
     * @param _rewardsTokens Addresses of the rewards tokens
     */
    function initialize(
        string memory name,
        string memory symbol,
        address owner,
        address _stakedToken,
        uint256 _minimumStakingPeriod,
        address[] memory _rewardsTokens
    ) public initializer {
        __ERC20_init(name, symbol);
        __ERC20Votes_init();
        __UUPSUpgradeable_init();
        __Ownable_init(owner);
        stakedToken = IERC20(_stakedToken);
        _setMinimumStakingPeriod(_minimumStakingPeriod);
        _addRewardsTokens(_rewardsTokens);
    }

    /**
     * @notice Adds new rewards tokens to the contract.
     * @param _rewardsTokens The addresses of the new rewards tokens.
     */
    function addRewardsTokens(address[] memory _rewardsTokens) external onlyOwner {
        _addRewardsTokens(_rewardsTokens);
    }

    /**
     * @notice Sets the minimum staking period, only callable by the owner.
     * @param newMinimumStakingPeriod The new minimum staking period in seconds.
     */
    function setMinimumStakingPeriod(
        uint256 newMinimumStakingPeriod
    ) external onlyOwner {
        _setMinimumStakingPeriod(newMinimumStakingPeriod);
    }

    /**
     * @notice Stakes a given amount of tokens.
     * @param amount The amount of tokens to stake.
     */
    function stake(uint256 amount) external {
        if (amount == 0) revert ZeroStake();

        _accumulateRewards(msg.sender);

        stakedAmount[msg.sender] += amount;
        lastStakeTimestamp[msg.sender] = block.timestamp;
        totalStaked += amount;

        _mint(msg.sender, amount);

        stakedToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount);
    }

    /**
     * @notice Adds new rewards tokens to the contract.
     * @param _rewardsTokens The addresses of the new rewards tokens.
     */
    function _addRewardsTokens(address[] memory _rewardsTokens) internal {
        for (uint256 i = 0; i < _rewardsTokens.length; ) {
            rewardsTokens.push(_rewardsTokens[i]);

            RewardsTokenData storage tokenData = rewardsTokenDatas[_rewardsTokens[i]];
            tokenData.enabled = true;

            emit RewardsTokenAdded(_rewardsTokens[i]);

            unchecked {
                i++;
            }
        }
    }

    /**
     * @notice Accumulates rewards for a given staker and updates their rewards rates.
     * @param _staker The address of the staker.
     */
    function _accumulateRewards(address _staker) internal {
        for (uint256 i = 0; i < rewardsTokens.length; ) {
            RewardsTokenData storage token = rewardsTokenDatas[rewardsTokens[i]];

            token.stakerAccumulatedRewards[_staker] +=
                (stakedAmount[_staker] *
                    (token.totalRewardsRate -
                        token.stakerRewardsRates[_staker])) /
                (10 ** 18);

            token.stakerRewardsRates[_staker] = token.totalRewardsRate;

            unchecked {
                i++;
            }
        }
    }

    /**
     * @notice This ERC20 function is overridden to prevent transfers
     */
    function transfer(address, uint256) public virtual override returns (bool) {
        revert NonTransferable();
    }

    /**
     * @notice This ERC20 function is overridden to prevent transferFroms
     */
    function transferFrom(
        address,
        address,
        uint256
    ) public virtual override returns (bool) {
        revert NonTransferable();
    }

    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    /**
     * @dev Function that should revert when `msg.sender` is not authorized to upgrade the contract.
     * Called by {upgradeTo} and {upgradeToAndCall}.
     *
     * Reverts if the sender is not the owner of the contract.
     * Authorization is handled by the onlyOwner modifier
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal virtual override onlyOwner { }

    /**
     * @notice Sets the minimum staking period.
     * @param newMinimumStakingPeriod The new minimum staking period in seconds.
     */
    function _setMinimumStakingPeriod(
        uint256 newMinimumStakingPeriod
    ) internal {
        minimumStakingPeriod = newMinimumStakingPeriod;
        emit MinimumStakingPeriodUpdated(newMinimumStakingPeriod);
    }

    function getRewardsTokens() public view returns (address[] memory) {
        return rewardsTokens;
    }

    /// @inheritdoc Version
    function getVersion() public view virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(IERC20).interfaceId ||
            interfaceId == type(IVotes).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
