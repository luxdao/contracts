// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IVotesERC20V1} from "./IVotesERC20V1.sol";

interface IVotesERC20LockableV1 is IVotesERC20V1 {
    // --- Errors ---

    error IsLocked();
    error ExceedMaxTotalSupply();
    error InvalidMaxTotalSupply();

    // --- Events ---

    event Locked(bool isLocked);
    event MaxTotalSupplyUpdated(uint256 newMaxTotalSupply);

    // --- Initializer Functions ---

    function initialize(
        Metadata calldata metadata_,
        Allocation[] calldata allocations_,
        address owner_,
        bool locked_,
        uint256 maxTotalSupply_
    ) external;

    // --- View Functions ---

    function locked() external view returns (bool isLocked);

    function maxTotalSupply() external view returns (uint256 maxTotalSupply);

    function getUnlockTime() external view returns (uint48 unlockTime);

    // --- State-Changing Functions ---

    function lock(bool locked_) external;

    function setMaxTotalSupply(uint256 newMaxTotalSupply_) external;

    function mint(address to_, uint256 amount_) external;

    function burn(uint256 amount_) external;
}
