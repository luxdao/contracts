// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Version} from "../Version.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20VotesUpgradeable, VotesUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {IVotesERC20StakedV1} from "../../interfaces/decent/deployables/IVotesERC20StakedV1.sol";

contract VotesERC20StakedV1 is
    IVotesERC20StakedV1,
    Version,
    ERC20VotesUpgradeable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable
{
    using SafeERC20 for IERC20;

    uint16 private constant VERSION = 1;
    IERC20 internal _stakedToken;
    uint256 internal _minimumStakingPeriod;
    uint256 internal _totalStaked;

    mapping(address staker => StakerData data) internal _stakerData;

    address[] internal _rewardsTokens;
    mapping(address token => RewardsTokenData data) internal _rewardsTokenDatas;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name,
        string memory symbol,
        address owner,
        address stakedToken_,
        uint256 minimumStakingPeriod_,
        address[] memory rewardsTokens_
    ) public virtual override initializer {
        __ERC20_init(name, symbol);
        __ERC20Votes_init();
        __UUPSUpgradeable_init();
        __Ownable_init(owner);
        _stakedToken = IERC20(stakedToken_);
        _updateMinimumStakingPeriod(minimumStakingPeriod_);
        _addRewardsTokens(rewardsTokens_);
    }

    function addRewardsTokens(
        address[] memory rewardsTokens_
    ) external virtual override onlyOwner {
        _addRewardsTokens(rewardsTokens_);
    }

    function updateMinimumStakingPeriod(
        uint256 newMinimumStakingPeriod
    ) external virtual override onlyOwner {
        _updateMinimumStakingPeriod(newMinimumStakingPeriod);
    }

    function stake(uint256 amount) external virtual override {
        if (amount == 0) revert ZeroStake();

        _accumulateRewards(msg.sender);

        _stakerData[msg.sender].stakedAmount += amount;
        _stakerData[msg.sender].lastStakeTimestamp = block.timestamp;
        _totalStaked += amount;

        _mint(msg.sender, amount);

        _stakedToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount);
    }

    function _addRewardsTokens(address[] memory rewardsTokens_) internal {
        for (uint256 i = 0; i < rewardsTokens_.length; ) {
            _rewardsTokens.push(rewardsTokens_[i]);

            RewardsTokenData storage tokenData = _rewardsTokenDatas[
                rewardsTokens_[i]
            ];
            tokenData.enabled = true;

            emit RewardsTokenAdded(rewardsTokens_[i]);

            unchecked {
                i++;
            }
        }
    }

    function _accumulateRewards(address _staker) internal {
        for (uint256 i = 0; i < _rewardsTokens.length; ) {
            RewardsTokenData storage token = _rewardsTokenDatas[
                _rewardsTokens[i]
            ];

            token.stakerAccumulatedRewards[_staker] +=
                (_stakerData[_staker].stakedAmount *
                    (token.rewardsRate - token.stakerRewardsRates[_staker])) /
                (10 ** 18);

            token.stakerRewardsRates[_staker] = token.rewardsRate;

            unchecked {
                i++;
            }
        }
    }

    function transfer(address, uint256) public virtual override returns (bool) {
        revert NonTransferable();
    }

    function transferFrom(
        address,
        address,
        uint256
    ) public virtual override returns (bool) {
        revert NonTransferable();
    }

    function approve(address, uint256) public virtual override returns (bool) {
        revert NonTransferable();
    }

    function clock()
        public
        view
        virtual
        override(IVotesERC20StakedV1, VotesUpgradeable)
        returns (uint48)
    {
        return uint48(block.timestamp);
    }

    function CLOCK_MODE()
        public
        pure
        override(IVotesERC20StakedV1, VotesUpgradeable)
        returns (string memory)
    {
        return "mode=timestamp";
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal virtual override onlyOwner {
        // Authorization is handled by the onlyOwner modifier
    }

    function _updateMinimumStakingPeriod(
        uint256 newMinimumStakingPeriod
    ) internal {
        _minimumStakingPeriod = newMinimumStakingPeriod;
        emit MinimumStakingPeriodUpdated(newMinimumStakingPeriod);
    }

    function getVersion() public view virtual override returns (uint16) {
        return VERSION;
    }

    function stakedToken() external view virtual override returns (address) {
        return address(_stakedToken);
    }

    function minimumStakingPeriod()
        external
        view
        virtual
        override
        returns (uint256)
    {
        return _minimumStakingPeriod;
    }

    function totalStaked() external view virtual override returns (uint256) {
        return _totalStaked;
    }

    function rewardsTokens()
        external
        view
        virtual
        override
        returns (address[] memory)
    {
        return _rewardsTokens;
    }

    function rewardsTokenData(
        address token
    )
        external
        view
        virtual
        override
        returns (
            uint256 rewardsRate,
            uint256 rewardsDistributed,
            uint256 rewardsClaimed
        )
    {
        if (!_rewardsTokenDatas[token].enabled) revert InvalidRewardsToken();

        return (
            _rewardsTokenDatas[token].rewardsRate,
            _rewardsTokenDatas[token].rewardsDistributed,
            _rewardsTokenDatas[token].rewardsClaimed
        );
    }

    function stakerData(
        address staker
    )
        external
        view
        virtual
        override
        returns (uint256 stakedAmount, uint256 lastStakeTimestamp)
    {
        return (
            _stakerData[staker].stakedAmount,
            _stakerData[staker].lastStakeTimestamp
        );
    }

    function stakerRewardsData(
        address token,
        address staker
    )
        external
        view
        virtual
        override
        returns (uint256 rewardRate, uint256 accumulatedRewards)
    {
        if (!_rewardsTokenDatas[token].enabled) revert InvalidRewardsToken();

        return (
            _rewardsTokenDatas[token].stakerRewardsRates[staker],
            _rewardsTokenDatas[token].stakerAccumulatedRewards[staker]
        );
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(IVotesERC20StakedV1).interfaceId ||
            interfaceId == type(IERC20).interfaceId ||
            interfaceId == type(IVotes).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
