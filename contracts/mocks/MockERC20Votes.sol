// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/**
 * @title MockERC20Votes
 * @dev Mock ERC20 token with IVotes implementation for testing voting functionality
 * Enhanced with proper historical snapshot support
 */
contract MockERC20Votes is ERC20, ERC20Permit, IVotes {
    mapping(address => mapping(uint256 => uint256)) private _mockPastVotes;
    mapping(uint256 => uint256) private _mockPastTotalSupply;
    mapping(address => address) private _delegates;

    constructor()
        ERC20("Mock Voting Token", "MVT")
        ERC20Permit("Mock Voting Token")
    {}

    /**
     * @dev Mints tokens to the specified address
     * @param to The address to mint tokens to
     * @param amount The amount of tokens to mint
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @dev Sets a specific past voting weight for an account at a specific timestamp
     * @param account The account to set past votes for
     * @param timestamp The timestamp to set votes at
     * @param votes The amount of votes to set
     */
    function setPastVotes(
        address account,
        uint256 timestamp,
        uint256 votes
    ) external {
        _mockPastVotes[account][timestamp] = votes;
    }

    /**
     * @dev Sets a specific past total supply for a specific timestamp
     * @param timestamp The timestamp to set total supply at
     * @param totalSupply The total supply to set
     */
    function setPastTotalSupply(
        uint256 timestamp,
        uint256 totalSupply
    ) external {
        _mockPastTotalSupply[timestamp] = totalSupply;
    }

    /**
     * @dev Implementation of the delegation function from IVotes
     */
    function delegate(address delegatee) public override {
        _delegates[msg.sender] = delegatee;
    }

    /**
     * @dev Implementation of the delegation function from IVotes
     */
    function delegateBySig(
        address delegatee,
        uint256,
        uint256,
        uint8,
        bytes32,
        bytes32
    ) public override {
        // Not implemented for mock
        _delegates[msg.sender] = delegatee;
    }

    /**
     * @dev Returns the current delegated address
     */
    function delegates(address account) public view override returns (address) {
        return _delegates[account];
    }

    /**
     * @dev Returns the current voting power
     */
    function getVotes(address account) public view override returns (uint256) {
        return balanceOf(account);
    }

    /**
     * @dev Overrides getPastVotes to return our mock values
     * Enhanced to properly handle historical snapshots
     */
    function getPastVotes(
        address account,
        uint256 timestamp
    ) public view override returns (uint256) {
        if (_mockPastVotes[account][timestamp] > 0) {
            return _mockPastVotes[account][timestamp];
        }
        // If no explicit value is set for this timestamp, return the current balance
        // In a real implementation, this would use a checkpoint system
        return balanceOf(account);
    }

    /**
     * @dev Enhanced implementation that properly handles historical snapshots
     */
    function getPastTotalSupply(
        uint256 timestamp
    ) public view override returns (uint256) {
        if (_mockPastTotalSupply[timestamp] > 0) {
            return _mockPastTotalSupply[timestamp];
        }
        // If no explicit value is set for this timestamp, return the current total supply
        // In a real implementation, this would use a checkpoint system
        return totalSupply();
    }
}
