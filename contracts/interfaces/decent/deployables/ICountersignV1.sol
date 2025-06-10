// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface ICountersignV1 {
    // --- Errors ---

    error InvalidArrayLengths();

    // --- Structs ---

    struct Transaction {
        address target;
        uint256 value;
        bytes data;
    }

    struct Signer {
        bool isSigner;
        bool required;
        bool signed;
        uint256 weight;
        Transaction[] transactions;
    }

    // --- Events ---

    // --- View Functions ---

    function agreementUri() external view returns (string memory agreementUri);

    function verificationContract()
        external
        view
        returns (address verificationContract);

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
            uint256 weight,
            Transaction[] memory transactions
        );

    function preExecutionTransactions()
        external
        view
        returns (Transaction[] memory preExecutionTransactions);
}
