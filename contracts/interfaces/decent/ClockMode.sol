// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

/**
 * @title ClockMode
 * @dev Enum to distinguish between timestamp-based and block number-based time.
 */
enum ClockMode {
    Timestamp,
    BlockNumber
}
