// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface ICountersignV1 {
    // --- Errors ---

    error InvalidArrayLengths();
    error InvalidSigner();
    error SigningDeadlineElapsed();
    error ExecutionDeadlineElapsed();
    error SignerAlreadySigned();
    error InvalidKYCSignature();

    // --- Structs ---

    struct SignerInitialization {
        address account;
        bool required;
        uint256 weight;
        bytes transactions;
    }

    struct Signer {
        bool isSigner;
        bool required;
        bool signed;
        bool executed;
        uint48 signedTimestamp;
        uint256 weight;
        bytes transactions;
    }

    // --- Events ---

    event Signed(address indexed signer);

    // --- Initializer Functions ---

    function initialize(
        string memory agreementUri_,
        address verificationContract_,
        uint48 signingDeadline_,
        uint48 executionDeadline_,
        address multisend_,
        uint256 minWeight_,
        bytes memory preExecutionTransactions_,
        SignerInitialization[] memory signerInitializations_
    ) external;

    // --- View Functions ---

    function agreementUri() external view returns (string memory agreementUri);

    function kycVerifier() external view returns (address kycVerifier);

    function signingDeadline() external view returns (uint48 signingDeadline);

    function executionDeadline()
        external
        view
        returns (uint48 executionDeadline);

    function multisend() external view returns (address multisend);

    function minWeight() external view returns (uint256 minWeight);

    function signerAddresses()
        external
        view
        returns (address[] memory signerAddresses);

    function signerData(
        address signer
    )
        external
        view
        returns (
            bool isSigner,
            bool required,
            bool signed,
            bool executed,
            uint48 signedTimestamp,
            uint256 weight,
            bytes memory transactions
        );

    function preExecutionTransactions()
        external
        view
        returns (bytes memory preExecutionTransactions);

    // --- State-Changing Functions ---

    function sign() external;

    function execute() external;
}
