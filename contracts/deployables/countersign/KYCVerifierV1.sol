// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IVersion} from "../../interfaces/decent/deployables/IVersion.sol";
import {IKYCVerifierV1} from "../../interfaces/decent/deployables/IKYCVerifierV1.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract KYCVerifierV1 is IKYCVerifierV1, IVersion, ERC165, EIP712Upgradeable {
    // ======================================================================
    // STATE VARIABLES
    // ======================================================================

    address internal _verifier;

    // keccak256("SignData(address countersign,address account)")
    bytes32 internal constant TYPEHASH =
        keccak256("SignData(address countersign,address account)");

    // ======================================================================
    // CONSTRUCTOR & INITIALIZERS
    // ======================================================================

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address verifier_,
        string memory name_,
        string memory version_
    ) public virtual override initializer {
        _verifier = verifier_;
        __EIP712_init(name_, version_);
    }

    // ======================================================================
    // IKYCVerifier
    // ======================================================================

    // --- View Functions ---

    function verify(
        SignData memory signData_,
        bytes memory signature
    ) public view virtual override returns (bool) {
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(TYPEHASH, signData_.countersign, signData_.account)
            )
        );
        return ECDSA.recover(digest, signature) == _verifier;
    }

    function verifier() public view virtual override returns (address) {
        return _verifier;
    }

    // --- State-Changing Functions ---

    // ======================================================================
    // IVersion
    // ======================================================================

    // --- Pure Functions ---

    function version() public pure virtual override returns (uint16) {
        return 1;
    }

    // ======================================================================
    // ERC165
    // ======================================================================

    // --- View Functions ---

    function supportsInterface(
        bytes4 interfaceId_
    ) public view virtual override returns (bool) {
        return
            interfaceId_ == type(IKYCVerifierV1).interfaceId ||
            interfaceId_ == type(IVersion).interfaceId ||
            super.supportsInterface(interfaceId_);
    }
}
