// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IERC721VotingStrategyV1} from "../interfaces/decent/deployables/IERC721VotingStrategyV1.sol";

/**
 * @title MockERC721VotingStrategy
 * @dev Simple mock implementation of IERC721VotingStrategyV1 for testing
 */
contract MockERC721VotingStrategy is IERC721VotingStrategyV1 {
    // Mapping of token address to voting weight
    mapping(address => uint256) private _tokenWeights;
    address public owner;

    event WeightSet(address indexed tokenAddress, uint256 weight);

    constructor(address _owner) {
        owner = _owner;
    }

    /**
     * @dev Sets the weight for a specific token address
     * @param tokenAddress The ERC721 token address
     * @param weight The weight to assign
     */
    function setTokenWeight(address tokenAddress, uint256 weight) external {
        require(msg.sender == owner, "Not authorized");
        _tokenWeights[tokenAddress] = weight;
        emit WeightSet(tokenAddress, weight);
    }

    /**
     * @dev Returns the current token weight for the given ERC-721 token address
     * @param _tokenAddress The ERC-721 token address
     */
    function getTokenWeight(
        address _tokenAddress
    ) external view override returns (uint256) {
        return _tokenWeights[_tokenAddress];
    }
}
