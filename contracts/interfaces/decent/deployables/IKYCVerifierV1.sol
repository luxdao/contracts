// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IKYCVerifierV1 {
    // --- Errors ---

    // --- Structs ---

    // --- Events ---

    // --- Initializer Functions ---

    function initialize(
        address decentSigner_,
        string memory name_,
        string memory version_
    ) external;

    // --- View Functions ---

    function verify(
        address countersign_,
        address account_,
        bytes memory signature
    ) external view returns (bool);

    function verifier() external view returns (address);

    // --- State-Changing Functions ---
}
