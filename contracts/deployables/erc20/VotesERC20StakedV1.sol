// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Version} from "../Version.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20VotesUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/**
 * Staking contract that immediately distributes rewards in full
 * to all stakers upon each distribution.
 */
contract VotesERC20StakedV1 is
    Version,
    ERC20VotesUpgradeable,
    UUPSUpgradeable,
    OwnableUpgradeable
{
    uint16 private constant VERSION = 1;
    IERC20 public stakedToken;
    uint256 public minimumStakingPeriod;

    event MinimumStakingPeriodUpdated(uint256 newMinimumStakingPeriod);

    error NonTransferable();

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
     */
    function initialize(
        string memory name,
        string memory symbol,
        address owner,
        address _stakedToken,
        uint256 _minimumStakingPeriod
    ) public initializer {
        __ERC20_init(name, symbol);
        __ERC20Votes_init();
        __UUPSUpgradeable_init();
        __Ownable_init(owner);
        stakedToken = IERC20(_stakedToken);
        _updateMinimumStakingPeriod(_minimumStakingPeriod);
    }

    /**
     * @notice Updates the minimum staking period, only callable by the owner.
     * @param newMinimumStakingPeriod The new minimum staking period in seconds.
     */
    function updateMinimumStakingPeriod(
        uint256 newMinimumStakingPeriod
    ) public onlyOwner {
        _updateMinimumStakingPeriod(newMinimumStakingPeriod);
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
    function transferFrom(address, address, uint256) public virtual override returns (bool) {
        revert NonTransferable();
    }   

    function approve(address, uint256) public virtual override returns (bool) {
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
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal virtual override onlyOwner {
        // Authorization is handled by the onlyOwner modifier
    }

    /**
     * @notice Updates the minimum staking period.
     * @param newMinimumStakingPeriod The new minimum staking period in seconds.
     */
    function _updateMinimumStakingPeriod(
        uint256 newMinimumStakingPeriod
    ) internal {
        minimumStakingPeriod = newMinimumStakingPeriod;
        emit MinimumStakingPeriodUpdated(newMinimumStakingPeriod);
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