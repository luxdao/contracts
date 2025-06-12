// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IKYCVerifierV1} from "../interfaces/decent/deployables/IKYCVerifierV1.sol";
import {IVersion} from "../interfaces/decent/deployables/IVersion.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

contract MockKYCVerifier is IKYCVerifierV1, IVersion, ERC165 {
    // ======================================================================
    // STATE VARIABLES
    // ======================================================================

    bool internal _verify;

    constructor() {
        initialize(address(this), "", "");
    }

    function initialize(
        address,
        string memory,
        string memory
    ) public { }

    function setVerify(bool verify_) public {
        _verify = verify_;
    }

    function verify(
        SignData memory,
        bytes memory
    ) public view virtual override returns (bool) {
        return _verify;
    }

    function verifier() public view virtual override returns (address) {
        return address(0);
    }

    function version() public pure virtual override returns (uint16) {
        return 1;
    }

    function supportsInterface(
        bytes4 interfaceId_
    ) public view virtual override returns (bool) {
        return
            interfaceId_ == type(IKYCVerifierV1).interfaceId ||
            interfaceId_ == type(IVersion).interfaceId ||
            super.supportsInterface(interfaceId_);
    }
}
