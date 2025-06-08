// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IVoterResolverV1 {
    function voter(address _msgSender) external view returns (address);
}
