// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IKYCVerifierV1 {
    // --- Errors ---

    // --- Structs ---

    struct SignData {
        address countersign;
        address account;
    }

    // --- Events ---

    // --- Initializer Functions ---

    function initialize(
        address verifier_,
        string memory name_,
        string memory version_
    ) external;

    // --- View Functions ---

    function verify(
        SignData memory signData_,
        bytes memory signature
    ) external view returns (bool);

    function verifier() external view returns (address);

    // --- State-Changing Functions ---
}
