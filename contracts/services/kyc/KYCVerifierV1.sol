// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {
    IKYCVerifierV1
} from "../../interfaces/decent/services/IKYCVerifierV1.sol";
import {IVersion} from "../../interfaces/decent/deployables/IVersion.sol";
import {IDeploymentBlock} from "../../interfaces/decent/IDeploymentBlock.sol";
import {
    DeploymentBlockNonInitializable
} from "../../DeploymentBlockNonInitializable.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title KYCVerifierV1
 * @author Decent Labs
 * @notice KYC verification service using EIP-712 signature verification
 * @dev This contract implements IKYCVerifierV1, providing KYC verification
 * through cryptographic signature verification.
 *
 * Implementation details:
 * - Uses EIP-712 structured data signing for verification
 * - Requires signature from authorized verifier address
 * - Deployed as singleton service per chain
 * - Supports operating contract-specific verification
 *
 * Security considerations:
 * - Verifier address is immutable and set at deployment
 * - Uses ECDSA signature recovery for verification
 * - EIP-712 prevents signature replay across different domains
 * - Operating contract context prevents cross-contract signature reuse
 *
 * @custom:security-contact security@decentlabs.io
 */
contract KYCVerifierV1 is
    IKYCVerifierV1,
    IVersion,
    DeploymentBlockNonInitializable,
    ERC165,
    EIP712
{
    // ======================================================================
    // STATE VARIABLES
    // ======================================================================

    address private immutable _verifier;

    bytes32 internal constant TYPEHASH =
        keccak256(
            "VerificationData(address operatingContract,address account)"
        );

    // ======================================================================
    // CONSTRUCTOR & INITIALIZERS
    // ======================================================================

    constructor(address verifier_) EIP712("KYCVerifier", "1") {
        _verifier = verifier_;
    }

    // ======================================================================
    // IKYCVerifier
    // ======================================================================

    // --- View Functions ---

    /**
     * @inheritdoc IKYCVerifierV1
     * @dev Verifies KYC status using EIP-712 signature verification. The signature
     * must be provided by the authorized verifier address to confirm KYC compliance.
     */
    function verify(
        address operatingContract_,
        address account_,
        bytes calldata signature_
    ) public view virtual override returns (bool) {
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(TYPEHASH, operatingContract_, account_))
        );
    
        return ECDSA.recover(digest, signature_) == _verifier;
    }

    /**
     * @inheritdoc IKYCVerifierV1
     */
    function verifier() public view virtual override returns (address) {
        return _verifier;
    }

    // ======================================================================
    // IVersion
    // ======================================================================

    // --- Pure Functions ---

    /**
     * @inheritdoc IVersion
     */
    function version() public pure virtual override returns (uint16) {
        return 1;
    }

    // ======================================================================
    // ERC165
    // ======================================================================

    // --- View Functions ---

    /**
     * @inheritdoc ERC165
     * @dev Supports IKYCVerifierV1, IVersion, IDeploymentBlock, and IERC165
     */
    function supportsInterface(
        bytes4 interfaceId_
    ) public view virtual override returns (bool) {
        return
            interfaceId_ == type(IKYCVerifierV1).interfaceId ||
            interfaceId_ == type(IVersion).interfaceId ||
            interfaceId_ == type(IDeploymentBlock).interfaceId ||
            super.supportsInterface(interfaceId_);
    }
}
