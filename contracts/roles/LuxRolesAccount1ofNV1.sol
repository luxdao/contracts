// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import { IERC6551Account } from "../interfaces/erc6551/IERC6551Account.sol";
import { IERC6551Executable } from "../interfaces/erc6551/IERC6551Executable.sol";
import { IHats } from "../interfaces/hats/IHats.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title LuxRolesAccount1ofNV1
 * @author Lux Industries Inc
 * @notice ERC-6551 token-bound account for a Lux role (hat) — the `rolesAccount1ofNMasterCopy`.
 *         Deployed once as a master copy; the canonical ERC-6551 registry
 *         (0x000000006551c19487814612e58FE06813775758) clones it (one minimal proxy per hat)
 *         with `tokenContract == rolesProtocol` and `tokenId == hatId`.
 *
 * @dev "1-of-N": ANY current wearer of the bound hat is an authorized signer. Authority is
 *      resolved live against the roles protocol via `isWearerOfHat(signer, hatId)`, so the
 *      account's controller set tracks hat membership automatically (a revoked wearer instantly
 *      loses control; a newly-minted wearer gains it). There is no stored owner and no admin.
 *
 *      This is intentionally minimal and holds no per-hat configuration — all binding data
 *      lives in the ERC-6551 proxy footer (read by `token()`), so a single master copy serves
 *      every hat. Composes with `LuxRolesV1` to give every created role its own sub-wallet.
 *
 * @custom:security-contact security@lux.network
 */
contract LuxRolesAccount1ofNV1 is IERC6551Account, IERC6551Executable, IERC165 {
    using ECDSA for bytes32;

    /// @dev ERC-6551 `isValidSigner` magic value.
    bytes4 internal constant MAGIC_IS_VALID_SIGNER = IERC6551Account.isValidSigner.selector; // 0x523e3260

    /// @dev ERC-1271 `isValidSignature` magic value.
    bytes4 internal constant MAGIC_ERC1271 = 0x1626ba7e;

    /// @notice Monotonic counter bumped on every successful `execute` (ERC-6551 state signal).
    uint256 public state;

    /// @notice Thrown when a non-wearer attempts to act as the account.
    error NotAuthorized();

    /// @notice Thrown for an unsupported ERC-6551 operation type.
    error InvalidOperation();

    /// @dev Accept native asset transfers (streams, direct sends).
    receive() external payable { }

    /*//////////////////////////////////////////////////////////////
                                EXECUTE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IERC6551Executable
    /// @dev Only a current wearer of the bound hat may execute. Supports operation
    ///      0 = CALL and 1 = DELEGATECALL. CREATE (2) / CREATE2 (3) are intentionally
    ///      fail-closed in V1: they are unused by the DAO roles flow and their salt/initcode
    ///      encoding is not fixed by ERC-6551, so enabling them would add ambiguous surface.
    function execute(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        payable
        returns (bytes memory result)
    {
        if (!_isValidSigner(msg.sender)) revert NotAuthorized();

        // bump state before the external interaction.
        unchecked {
            ++state;
        }

        bool ok;
        if (operation == 0) {
            (ok, result) = to.call{ value: value }(data);
        } else if (operation == 1) {
            (ok, result) = to.delegatecall(data);
        } else {
            revert InvalidOperation();
        }

        if (!ok) {
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                             SIGNER CHECKS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IERC6551Account
    function isValidSigner(address signer, bytes calldata) external view returns (bytes4 magicValue) {
        if (_isValidSigner(signer)) {
            magicValue = MAGIC_IS_VALID_SIGNER;
        }
    }

    /// @notice ERC-1271: a signature is valid if it was produced by a current wearer.
    /// @dev Recovers the ECDSA signer and checks hat membership. EOA wearers are supported
    ///      directly; a full nested-ERC-1271 (contract wearer) path is out of scope for V1.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4 magicValue) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        if (err == ECDSA.RecoverError.NoError && _isValidSigner(recovered)) {
            magicValue = MAGIC_ERC1271;
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 TOKEN
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IERC6551Account
    /// @dev Reads the (chainId, tokenContract, tokenId) tuple from the ERC-6551 proxy footer.
    function token() public view returns (uint256 chainId, address tokenContract, uint256 tokenId) {
        bytes memory footer = new bytes(0x60);
        assembly {
            // ERC-6551 minimal-proxy runtime is 0x2d bytes; footer = abi.encode(salt, chainId,
            // tokenContract, tokenId). Skip the 32-byte salt (offset 0x4d) and copy 0x60 bytes.
            extcodecopy(address(), add(footer, 0x20), 0x4d, 0x60)
        }
        return abi.decode(footer, (uint256, address, uint256));
    }

    /*//////////////////////////////////////////////////////////////
                                ERC-165
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IERC6551Account).interfaceId
            || interfaceId == type(IERC6551Executable).interfaceId;
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev A signer is valid iff it currently wears the bound hat.
    function _isValidSigner(address signer) internal view returns (bool) {
        (, address tokenContract, uint256 tokenId) = token();
        return IHats(tokenContract).isWearerOfHat(signer, tokenId);
    }
}
