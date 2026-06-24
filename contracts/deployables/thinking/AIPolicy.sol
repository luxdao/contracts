// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IGuard} from "./AIExecute.sol";

/// @title AIPolicy — defense-in-depth policy for AIExecute, kept orthogonal to the execution mechanism.
///
/// Consensus is the primary gate; this is the second wall. It bounds WHAT consensus is even allowed to
/// execute, so a compromised quorum still cannot reach outside the envelope a deployment set: an
/// allowlist of targets, an allowlist of selectors per target, a cap on native value per op, and a
/// per-target minimum gap between calls (rate limit). Each gate is independent and off by default —
/// turn on only what a deployment needs.
///
/// Only the bound `executor` may call {check} (it mutates rate-limit state). Only `admin` configures —
/// admin SHOULD be the consensus timelock or a Safe, so the policy itself is governed.
contract AIPolicy is IGuard {
    address public immutable executor; // the AIExecute instance this guards
    address public admin;

    bool public allowlistTargets; // when true, only allowed targets pass
    bool public allowlistSelectors; // when true, only allowed (target, selector) pass
    uint256 public maxValue; // max native value per op (default 0 = no native value permitted)

    mapping(address => bool) public targetAllowed;
    mapping(address => mapping(bytes4 => bool)) public selectorAllowed;
    mapping(address => uint64) public minGap; // per-target min seconds between calls (0 = no limit)
    mapping(address => uint64) public lastCall;

    event AdminSet(address indexed admin);
    event TargetAllowed(address indexed target, bool allowed);
    event SelectorAllowed(address indexed target, bytes4 indexed selector, bool allowed);
    event MaxValueSet(uint256 maxValue);
    event MinGapSet(address indexed target, uint64 gap);
    event AllowlistToggled(bool targets, bool selectors);

    error NotExecutor();
    error NotAdmin();
    error TargetNotAllowed(address target);
    error SelectorNotAllowed(address target, bytes4 selector);
    error ValueTooHigh(uint256 value, uint256 maxValue);
    error RateLimited(address target, uint64 nextAllowed);

    constructor(address executor_, address admin_) {
        executor = executor_;
        admin = admin_;
        emit AdminSet(admin_);
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    /// @inheritdoc IGuard
    function check(address target, uint256 value, bytes calldata data) external {
        if (msg.sender != executor) revert NotExecutor();
        if (allowlistTargets && !targetAllowed[target]) revert TargetNotAllowed(target);
        if (allowlistSelectors) {
            bytes4 sel = data.length >= 4 ? bytes4(data[:4]) : bytes4(0);
            if (!selectorAllowed[target][sel]) revert SelectorNotAllowed(target, sel);
        }
        if (value > maxValue) revert ValueTooHigh(value, maxValue);
        uint64 gap = minGap[target];
        if (gap != 0) {
            uint64 next = lastCall[target] + gap;
            if (block.timestamp < next) revert RateLimited(target, next);
            lastCall[target] = uint64(block.timestamp);
        }
    }

    // ---- admin (the policy is itself governed) -------------------------------

    function setAdmin(address a) external onlyAdmin {
        admin = a;
        emit AdminSet(a);
    }

    function setAllowlists(bool targets, bool selectors) external onlyAdmin {
        allowlistTargets = targets;
        allowlistSelectors = selectors;
        emit AllowlistToggled(targets, selectors);
    }

    function setTargetAllowed(address target, bool allowed) external onlyAdmin {
        targetAllowed[target] = allowed;
        emit TargetAllowed(target, allowed);
    }

    function setSelectorAllowed(address target, bytes4 selector, bool allowed) external onlyAdmin {
        selectorAllowed[target][selector] = allowed;
        emit SelectorAllowed(target, selector, allowed);
    }

    function setMaxValue(uint256 v) external onlyAdmin {
        maxValue = v;
        emit MaxValueSet(v);
    }

    function setMinGap(address target, uint64 gap) external onlyAdmin {
        minGap[target] = gap;
        emit MinGapSet(target, gap);
    }
}
