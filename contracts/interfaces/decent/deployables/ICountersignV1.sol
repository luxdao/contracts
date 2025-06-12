// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface ICountersignV1 {
    // --- Errors ---

    error InvalidArrayLengths();
    error InvalidSigner();
    error SigningDeadlineElapsed();
    error SignerAlreadySigned();
    error InvalidKYCSignature();

    // --- Structs ---

    struct Transaction {
        address target;
        uint256 value;
        bytes data;
    }

    struct SignerInitialization {
        address account;
        bool required;
        uint256 weight;
        Transaction[] transactions;
    }

    struct Signer {
        bool isSigner;
        bool required;
        bool signed;
        uint256 signedTimestamp;
        uint256 weight;
        Transaction[] transactions;
    }

    // --- Events ---

    event Signed(address indexed signer, bytes signature);

    // --- Initializer Functions ---

    function initialize(
        string memory agreementUri_,
        address verificationContract_,
        uint256 signingDeadline_,
        uint256 executionDeadline_,
        uint256 minWeight_,
        SignerInitialization[] memory signerInitializations_,
        Transaction[] memory preExecutionTransactions_
    ) external;

    // --- View Functions ---

    function agreementUri() external view returns (string memory agreementUri_);

    function kycVerifier() external view returns (address kycVerifier_);

    function signingDeadline() external view returns (uint256 signingDeadline_);

    function executionDeadline()
        external
        view
        returns (uint256 executionDeadline_);

    function minWeight() external view returns (uint256 minWeight_);

    function signerAddresses()
        external
        view
        returns (address[] memory signerAddresses_);

    function signerData(
        address signer
    )
        external
        view
        returns (
            bool isSigner_,
            bool required_,
            bool signed_,
            uint256 signedTimestamp_,
            uint256 weight_,
            Transaction[] memory transactions
        );

    function preExecutionTransactions()
        external
        view
        returns (Transaction[] memory preExecutionTransactions_);

    // --- State-Changing Functions ---

    function sign(bytes memory signature_) external;
}
