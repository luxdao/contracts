// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Version} from "../Version.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
    uint16 private constant VERSION = 1;
    IERC20 internal _stakedToken;
    uint256 internal _minimumStakingPeriod;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name,
        string memory symbol,
        address owner,
        address stakedToken_,
        uint256 minimumStakingPeriod_
    ) public virtual override initializer {
        __ERC20_init(name, symbol);
        __ERC20Votes_init();
        __UUPSUpgradeable_init();
        __Ownable_init(owner);
        _stakedToken = IERC20(stakedToken_);
        _updateMinimumStakingPeriod(minimumStakingPeriod_);
    }

    function updateMinimumStakingPeriod(
        uint256 newMinimumStakingPeriod
    ) external virtual override onlyOwner {
        _updateMinimumStakingPeriod(newMinimumStakingPeriod);
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
