// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

/**
 * @title IKYCVerifierV1
 * @notice Service interface for Know Your Customer (KYC) verification
 * @dev This interface provides a standard way to verify if an address has completed
 * KYC requirements. It's designed as a service contract that can be deployed once
 * per chain and referenced by multiple contracts that need KYC verification.
 *
 * Key features:
 * - Simple boolean verification for addresses
 * - Stateless view function for gas-efficient checks
 *
 * Usage:
 * - CountersignV1 and PublicSaleV1 use this to verify signers before accepting signatures
 *
 * Security:
 * - Verification logic is critical for compliance
 */
interface IKYCVerifierV1 {
    // --- View Functions ---

    /**
     * @notice Verifies if an address is KYC verified
     * @dev Returns true if the address is KYC verified, false otherwise.
     * Implementation can check on-chain records, merkle proofs, or oracle data.
     * Should be gas-efficient as it may be called frequently.
     * @param operatingContract_ The address of the contract that is verifying KYC status
     * @param account_ The address to verify KYC status for
     * @param signature_ The verifier signature attesting to KYC status
     * @return verified True if the address is KYC verified, false otherwise
     */
    function verify(
        address operatingContract_,
        address account_,
        bytes calldata signature_
    ) external view returns (bool verified);

    /**
     * @notice Returns the address of the verifier
     * @dev The verifier is the address that is authorized to sign KYC attestations
     * @return verifier The address of the verifier
     */
    function verifier() external view returns (address);
}
