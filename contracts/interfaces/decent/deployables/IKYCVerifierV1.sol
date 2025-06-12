// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IKYCVerifierV1 {

    // --- Initializer Functions ---

    function initialize(address zkMeVerify_, address cooperator_) external;

    // --- View Functions ---

    function verify(address account_) external view returns (bool);

    function zkMeVerify() external view returns (address);

    function cooperator() external view returns (address);

}
