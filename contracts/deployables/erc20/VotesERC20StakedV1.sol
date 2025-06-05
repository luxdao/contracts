// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IVersion} from "../../interfaces/decent/deployables/IVersion.sol";
import {Version} from "../Version.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20VotesUpgradeable, VotesUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {IVotesERC20StakedV1} from "../../interfaces/decent/deployables/IVotesERC20StakedV1.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

contract VotesERC20StakedV1 is
    IVotesERC20StakedV1,
    Version,
    ERC20VotesUpgradeable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    ERC165
{
    using SafeERC20 for IERC20;

    uint16 private constant VERSION = 1;
    IERC20 internal _stakedToken;
    address internal constant NATIVE_ASSET =
        0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint256 internal constant PRECISION = 10 ** 18;
    uint256 internal _minimumStakingPeriod;
    uint256 internal _totalStaked;

    mapping(address => StakerData) internal _stakerData;

    address[] internal _rewardsTokens;
    mapping(address => RewardsTokenData) internal _rewardsTokenDatas;

    constructor() {
        _disableInitializers();
    }

    receive() external payable {}

    function initialize(
        Metadata calldata metadata_,
        address owner_,
        address stakedToken_,
        uint256 minimumStakingPeriod_,
        address[] calldata rewardsTokens_
    ) public virtual override initializer {
        __ERC20_init(metadata_.name, metadata_.symbol);
        __ERC20Votes_init();
        __UUPSUpgradeable_init();
        __Ownable_init(owner_);
        _stakedToken = IERC20(stakedToken_);
        _updateMinimumStakingPeriod(minimumStakingPeriod_);
        _addRewardsTokens(rewardsTokens_);
    }

    function addRewardsTokens(
        address[] calldata rewardsTokens_
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

    function unstake(uint256 amount) external virtual override {
        if (amount == 0) revert ZeroUnstake();
        if (
            block.timestamp <
            _stakerData[msg.sender].lastStakeTimestamp + _minimumStakingPeriod
        ) revert MinimumStakingPeriod();

        _accumulateRewards(msg.sender);

        _stakerData[msg.sender].stakedAmount -= amount;
        _totalStaked -= amount;

        _burn(msg.sender, amount);

        _stakedToken.safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount);
    }

    function distributeRewards() external virtual override {
        if (_totalStaked == 0) revert ZeroStaked();

        for (uint256 i = 0; i < _rewardsTokens.length; ) {
            _distributeRewards(_rewardsTokens[i]);

            unchecked {
                ++i;
            }
        }
    }

    function distributeRewards(
        address[] calldata _tokens
    ) external virtual override {
        if (_totalStaked == 0) revert ZeroStaked();

        for (uint256 i = 0; i < _tokens.length; ) {
            if (!_rewardsTokenDatas[_tokens[i]].enabled)
                revert InvalidRewardsToken(_tokens[i]);

            _distributeRewards(_tokens[i]);

            unchecked {
                ++i;
            }
        }
    }

    function claimRewards(address _recipient) external virtual override {
        for (uint256 i = 0; i < _rewardsTokens.length; ) {
            _claimRewards(msg.sender, _recipient, _rewardsTokens[i]);

            unchecked {
                ++i;
            }
        }
    }

    function claimRewards(
        address _recipient,
        address[] memory _tokens
    ) external virtual override {
        for (uint256 i = 0; i < _tokens.length; ) {
            if (!_rewardsTokenDatas[_tokens[i]].enabled)
                revert InvalidRewardsToken(_tokens[i]);

            _claimRewards(msg.sender, _recipient, _tokens[i]);

            unchecked {
                ++i;
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

    function _claimRewards(
        address _claimer,
        address _recipient,
        address _token
    ) internal {
        uint256 amountToClaim = _claimableRewards(_claimer, _token);

        RewardsTokenData storage token = _rewardsTokenDatas[_token];

        token.stakerAccumulatedRewards[_claimer] = 0;
        token.stakerRewardsRates[_claimer] = token.rewardsRate;

        if (amountToClaim == 0) return;

        token.rewardsClaimed += amountToClaim;
        if (_token == NATIVE_ASSET) {
            (bool success, ) = _recipient.call{value: amountToClaim}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(_token).safeTransfer(_recipient, amountToClaim);
        }

        emit RewardsClaimed(_claimer, _token, _recipient, amountToClaim);
    }

    function _distributeRewards(address _token) internal {
        RewardsTokenData storage token = _rewardsTokenDatas[_token];

        uint256 amountToDistribute = _distributableRewards(_token);

        if (amountToDistribute == 0) return;

        uint256 newRewardsRate = token.rewardsRate +
            (amountToDistribute * PRECISION) /
            _totalStaked;

        token.rewardsDistributed += amountToDistribute;
        token.rewardsRate = newRewardsRate;

        emit RewardsDistributed(_token, amountToDistribute, newRewardsRate);
    }

    function _addRewardsTokens(address[] calldata rewardsTokens_) internal {
        for (uint256 i = 0; i < rewardsTokens_.length; ) {
            if (_rewardsTokenDatas[rewardsTokens_[i]].enabled)
                revert DuplicateRewardsToken();

            _rewardsTokens.push(rewardsTokens_[i]);

            _rewardsTokenDatas[rewardsTokens_[i]].enabled = true;

            emit RewardsTokenAdded(rewardsTokens_[i]);

            unchecked {
                ++i;
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
                PRECISION;

            token.stakerRewardsRates[_staker] = token.rewardsRate;

            unchecked {
                ++i;
            }
        }
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

    function version() public view virtual override returns (uint16) {
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
        if (!_rewardsTokenDatas[token].enabled)
            revert InvalidRewardsToken(token);

        return (
            _rewardsTokenDatas[token].rewardsRate,
            _rewardsTokenDatas[token].rewardsDistributed,
            _rewardsTokenDatas[token].rewardsClaimed
        );
    }

    function distributableRewards()
        external
        view
        virtual
        override
        returns (uint256[] memory)
    {
        uint256[] memory distributableRewards_ = new uint256[](
            _rewardsTokens.length
        );

        for (uint256 i = 0; i < _rewardsTokens.length; ) {
            distributableRewards_[i] = _distributableRewards(_rewardsTokens[i]);

            unchecked {
                ++i;
            }
        }

        return distributableRewards_;
    }

    function distributableRewards(
        address[] calldata rewardsTokens_
    ) external view virtual override returns (uint256[] memory) {
        uint256[] memory distributableRewards_ = new uint256[](
            rewardsTokens_.length
        );

        for (uint256 i = 0; i < rewardsTokens_.length; ) {
            if (!_rewardsTokenDatas[rewardsTokens_[i]].enabled)
                revert InvalidRewardsToken(rewardsTokens_[i]);

            distributableRewards_[i] = _distributableRewards(rewardsTokens_[i]);

            unchecked {
                ++i;
            }
        }

        return distributableRewards_;
    }

    function _distributableRewards(
        address _token
    ) internal view returns (uint256) {
        if (!_rewardsTokenDatas[_token].enabled)
            revert InvalidRewardsToken(_token);

        uint256 thisBalance;
        if (_token == NATIVE_ASSET) {
            thisBalance = address(this).balance;
        } else if (_token == address(_stakedToken)) {
            thisBalance =
                IERC20(_token).balanceOf(address(this)) -
                _totalStaked;
        } else {
            thisBalance = IERC20(_token).balanceOf(address(this));
        }

        return
            thisBalance +
            _rewardsTokenDatas[_token].rewardsClaimed -
            _rewardsTokenDatas[_token].rewardsDistributed;
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
        if (!_rewardsTokenDatas[token].enabled)
            revert InvalidRewardsToken(token);

        return (
            _rewardsTokenDatas[token].stakerRewardsRates[staker],
            _rewardsTokenDatas[token].stakerAccumulatedRewards[staker]
        );
    }

    function claimableRewards(
        address _staker
    )
        external
        view
        virtual
        override
        returns (uint256[] memory claimableRewards_)
    {
        claimableRewards_ = new uint256[](_rewardsTokens.length);
        for (uint256 i = 0; i < _rewardsTokens.length; ) {
            claimableRewards_[i] = _claimableRewards(
                _staker,
                _rewardsTokens[i]
            );

            unchecked {
                ++i;
            }
        }
    }

    function claimableRewards(
        address _staker,
        address[] memory _tokens
    )
        external
        view
        virtual
        override
        returns (uint256[] memory claimableRewards_)
    {
        claimableRewards_ = new uint256[](_tokens.length);
        for (uint256 i = 0; i < _tokens.length; ) {
            if (!_rewardsTokenDatas[_tokens[i]].enabled)
                revert InvalidRewardsToken(_tokens[i]);

            claimableRewards_[i] = _claimableRewards(_staker, _tokens[i]);

            unchecked {
                ++i;
            }
        }
    }

    function _claimableRewards(
        address _staker,
        address _token
    ) internal view returns (uint256 claimableRewards_) {
        RewardsTokenData storage token = _rewardsTokenDatas[_token];

        claimableRewards_ =
            token.stakerAccumulatedRewards[_staker] +
            ((_stakerData[_staker].stakedAmount *
                (token.rewardsRate - token.stakerRewardsRates[_staker])) /
                PRECISION);
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(IVotesERC20StakedV1).interfaceId ||
            interfaceId == type(IERC20).interfaceId ||
            interfaceId == type(IVotes).interfaceId ||
            interfaceId == type(IVersion).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
