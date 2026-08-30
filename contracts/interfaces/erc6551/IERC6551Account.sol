// SPDX-License-Identifier: MIT
// ERC-6551 Token Bound Accounts. These are the signatures the standard
// itself defines (eips.ethereum.org/EIPS/eip-6551), reproduced so contracts
// here can speak it. They carried AGPL from the tree they were first copied
// into; a published interface is not that tree's work.
pragma solidity ^0.8.30;

/// @dev the ERC-165 identifier for this interface is `0x6faff5f1`
interface IERC6551Account {
    /**
     * @dev Allows the account to receive Ether.
     *
     * Accounts MUST implement a `receive` function.
     */
    receive() external payable;

    /**
     * @dev Returns the identifier of the non-fungible token which owns the account.
     *
     * The return value of this function MUST be constant - it MUST NOT change over time.
     *
     * @return chainId       The chain ID of the chain the token exists on
     * @return tokenContract The contract address of the token
     * @return tokenId       The ID of the token
     */
    function token() external view returns (uint256 chainId, address tokenContract, uint256 tokenId);

    /**
     * @dev Returns a value that SHOULD be modified each time the account changes state.
     *
     * @return The current account state
     */
    function state() external view returns (uint256);

    /**
     * @dev Returns a magic value indicating whether a given signer is authorized to act on
     * behalf of the account.
     *
     * MUST return the bytes4 magic value 0x523e3260 if the given signer is valid.
     *
     * @param signer  The address to check signing authorization for
     * @param context Additional data used to determine whether the signer is valid
     * @return magicValue Magic value indicating whether the signer is valid
     */
    function isValidSigner(address signer, bytes calldata context) external view returns (bytes4 magicValue);
}
