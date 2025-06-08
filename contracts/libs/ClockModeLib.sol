// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {ClockMode} from "../interfaces/decent/ClockMode.sol";
import {IERC6372} from "@openzeppelin/contracts/interfaces/IERC6372.sol";

/**
 * @title ClockModeLib
 * @dev Library for handling operations related to ClockMode.
 */
library ClockModeLib {
    bytes32 internal constant CLOCK_MODE_TIMESTAMP_BYTES32 =
        keccak256("mode=timestamp");

    /**
     * @dev Gets the clock mode of a token.
     * Attempts to call CLOCK_MODE() on the token. If it reverts or returns an unexpected value,
     * defaults to BlockNumber.
     * @param token_ The token address.
     * @return The detected ClockMode.
     */
    function getClockMode(address token_) internal view returns (ClockMode) {
        try IERC6372(token_).CLOCK_MODE() returns (string memory mode) {
            if (keccak256(bytes(mode)) == CLOCK_MODE_TIMESTAMP_BYTES32) {
                return ClockMode.Timestamp;
            }
            return ClockMode.BlockNumber;
        } catch {
            return ClockMode.BlockNumber;
        }
    }

    /**
     * @dev Gets the current time point (block number or timestamp) based on the ClockMode.
     * @param mode_ The ClockMode to use.
     * @return The current time point.
     */
    function getCurrentPoint(ClockMode mode_) internal view returns (uint256) {
        if (mode_ == ClockMode.Timestamp) {
            return block.timestamp;
        } else {
            return block.number;
        }
    }
}
