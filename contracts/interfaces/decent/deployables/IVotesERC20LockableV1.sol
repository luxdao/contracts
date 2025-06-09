// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IVotesERC20V1} from "./IVotesERC20V1.sol";

interface IVotesERC20LockableV1 is IVotesERC20V1 {
    event Locked(bool isLocked);
    event MaxTotalSupplyUpdated(uint256 newMaxTotalSupply);

    error IsLocked();
    error ExceedMaxTotalSupply();
    error InvalidMaxTotalSupply();

    function initialize(
        Metadata calldata metadata_,
        Allocation[] calldata allocations_,
        address owner_,
        bool locked_,
        uint256 maxTotalSupply_
    ) external;

    function lock(bool locked_) external;

    function locked() external view returns (bool isLocked);

    function mint(address to_, uint256 amount_) external;

    function maxTotalSupply() external view returns (uint256 maxTotalSupply);

    function setMaxTotalSupply(uint256 newMaxTotalSupply_) external;

    function burn(uint256 amount_) external;
}
