// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IVotesERC20V1} from "./IVotesERC20V1.sol";

interface IVotesERC20LockableV1 is IVotesERC20V1 {
    event Locked(bool isLocked);
    event MaxTotalSupplyUpdated(uint256 newMaxTotalSupply);

    error IsLocked();
    error CannotSwitchLockState(bool newLockState);
    error ExceedMaxTotalSupply();
    error InvalidMaxTotalSupply();

    function initialize(
        address owner_,
        bool locked_,
        uint256 maxTotalSupply_,
        string memory name_,
        string memory symbol_,
        Allocation[] memory allocations_
    ) external;

    function lock(bool _locked) external;

    function locked() external view returns (bool);

    function mint(address to, uint256 amount) external;

    function maxTotalSupply() external view returns (uint256);

    function setMaxTotalSupply(uint256 newMaxTotalSupply) external;

    function burn(uint256 amount) external;
}
