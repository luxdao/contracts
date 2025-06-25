// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {MockERC20} from "./MockERC20.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IVotesERC20V1} from "../interfaces/decent/deployables/IVotesERC20V1.sol";

/**
 * @title MockVotesERC20V1
 * @notice Mock implementation of IVotesERC20V1 for testing warrant contracts
 * @dev Simplified implementation that only includes the functions needed for warrant testing
 */
contract MockVotesERC20V1 is MockERC20, ERC165 {
    bool private _locked;
    uint48 private _unlockTime;

    constructor() MockERC20("Mock Votes Token", "MVT", 18) {}

    /**
     * @notice Returns whether the token is locked (non-transferable)
     */
    function locked() external view returns (bool) {
        return _locked;
    }

    /**
     * @notice Returns when the token was last unlocked
     */
    function getUnlockTime() external view returns (uint48) {
        return _unlockTime;
    }

    // Mock setters for testing
    function setLocked(bool locked_) external {
        _locked = locked_;
    }

    function setUnlockTime(uint48 unlockTime_) external {
        _unlockTime = unlockTime_;
    }

    /**
     * @notice Check if contract supports a given interface
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(IVotesERC20V1).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}