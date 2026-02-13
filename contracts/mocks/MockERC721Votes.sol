// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/**
 * @title MockERC721Votes
 * @dev Mock ERC721 token with IVotes implementation for testing NFT-based voting
 * Each NFT = 1 vote (1 token = 1 vote model)
 */
contract MockERC721Votes is ERC721, IVotes {
    mapping(address => address) private _delegates;
    mapping(address => mapping(uint256 => uint256)) private _mockPastVotes;
    mapping(address => mapping(uint256 => bool)) private _hasMockPastVoteBeenSet;
    mapping(uint256 => uint256) private _mockPastTotalSupply;
    mapping(uint256 => bool) private _hasMockPastTotalSupplyBeenSet;

    uint256 private _totalMinted;
    string public _name;
    string public _symbol;
    bool private _initialized;

    constructor() ERC721("Mock NFT Votes", "MNFTV") {}

    /**
     * @dev Initialize the token (for proxy pattern compatibility)
     */
    function initialize(string memory name_, string memory symbol_) external {
        require(!_initialized, "Already initialized");
        _name = name_;
        _symbol = symbol_;
        _initialized = true;
    }

    function name() public view override returns (string memory) {
        return _initialized ? _name : "Mock NFT Votes";
    }

    function symbol() public view override returns (string memory) {
        return _initialized ? _symbol : "MNFTV";
    }

    function clock() public view returns (uint256) {
        return block.timestamp;
    }

    function CLOCK_MODE() public pure returns (string memory) {
        return "mode=timestamp";
    }

    /**
     * @dev Safely mints a token to the specified address
     */
    function safeMint(address to, uint256 tokenId) external {
        _safeMint(to, tokenId);
        _totalMinted++;
    }

    /**
     * @dev Mints a token to the specified address
     */
    function mint(address to) external {
        _safeMint(to, _totalMinted++);
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
        _delegates[msg.sender] = delegatee;
    }

    /**
     * @dev Returns the current delegated address
     */
    function delegates(address account) public view override returns (address) {
        return _delegates[account];
    }

    /**
     * @dev Returns the current voting power (1 NFT = 1 vote)
     */
    function getVotes(address account) public view override returns (uint256) {
        return balanceOf(account);
    }

    /**
     * @dev Returns the voting power at a past timepoint
     */
    function getPastVotes(
        address account,
        uint256 timepoint
    ) public view override returns (uint256) {
        require(timepoint < block.timestamp, "ERC5805FutureLookup");
        if (_hasMockPastVoteBeenSet[account][timepoint]) {
            return _mockPastVotes[account][timepoint];
        }
        // If no explicit value is set, return current balance if self-delegated
        if (_delegates[account] == account) {
            return balanceOf(account);
        }
        return 0;
    }

    /**
     * @dev Returns the total voting power at a past timepoint
     */
    function getPastTotalSupply(
        uint256 timepoint
    ) public view override returns (uint256) {
        if (_hasMockPastTotalSupplyBeenSet[timepoint]) {
            return _mockPastTotalSupply[timepoint];
        }
        return _totalMinted;
    }

    /**
     * @dev Sets a specific past voting weight for testing
     */
    function setPastVotes(
        address account,
        uint256 timepoint,
        uint256 votes
    ) external {
        _mockPastVotes[account][timepoint] = votes;
        _hasMockPastVoteBeenSet[account][timepoint] = true;
    }

    /**
     * @dev Sets a specific past total supply for testing
     */
    function setPastTotalSupply(
        uint256 timepoint,
        uint256 totalSupply
    ) external {
        _mockPastTotalSupply[timepoint] = totalSupply;
        _hasMockPastTotalSupplyBeenSet[timepoint] = true;
    }

    /**
     * @notice Check if contract supports a given interface
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(IVotes).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
