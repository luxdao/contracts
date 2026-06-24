// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

/// @notice The validator-consensus value source (ThinkingParameters): a knob's decided value.
interface IThinkingValue {
    function valueOf(bytes32 modelSpecHash, string calldata knobKey)
        external
        view
        returns (uint256 value, bool decided);
}

/// @title ConsensusExecutor — the typed read/write bridge that lets thinking-validator CONSENSUS
/// govern any on-chain parameter, and lets an AI query any contract's state in a structured way.
///
/// Two halves, kept orthogonal:
///   READ  — EVM state is already typed by its ABI; {readUint}/{readBool}/{readInt}/{readAddress}/
///           {readBytes32} staticcall any getter and hand the AI a structured value (yes/no, a
///           number, …). {readMany} batches them.
///   WRITE — {enact} takes a knob the validators have DECIDED (ThinkingParameters median) and splices
///           its value as the sole argument of `target.selector(value)`. A 32-byte word ABI-encodes
///           to ANY single-word type, so the SAME call sets a bool (setFlag), a uint (setLimit), an
///           int (setRate), an address (setOwner), or a bytes32 — the selector picks the structure.
///           Permissionless to call; the target authorizes THIS executor as its governor.
///
/// One idea, one way: consensus decides a value; this writes it, typed, into any contract. OSS and
/// governance-neutral — nothing here is Lux-specific; any chain's validators can drive any contract.
contract ConsensusExecutor {
    IThinkingValue public immutable consensus;

    event Enacted(
        bytes32 indexed modelSpecHash, string knobKey, address indexed target, bytes4 selector, uint256 value
    );

    error NotDecided();
    error ReadFailed();
    error EnactFailed(bytes reason);

    constructor(address consensus_) {
        consensus = IThinkingValue(consensus_);
    }

    // ---- structured READ (any contract's state, typed) -----------------------

    function _read(address target, bytes calldata getterCalldata) private view returns (bytes memory) {
        (bool ok, bytes memory ret) = target.staticcall(getterCalldata);
        if (!ok) revert ReadFailed();
        return ret;
    }

    function read(address target, bytes calldata getterCalldata) external view returns (bytes memory) {
        return _read(target, getterCalldata);
    }

    function readUint(address target, bytes calldata c) external view returns (uint256) {
        return abi.decode(_read(target, c), (uint256));
    }

    function readBool(address target, bytes calldata c) external view returns (bool) {
        return abi.decode(_read(target, c), (bool));
    }

    function readInt(address target, bytes calldata c) external view returns (int256) {
        return abi.decode(_read(target, c), (int256));
    }

    function readAddress(address target, bytes calldata c) external view returns (address) {
        return abi.decode(_read(target, c), (address));
    }

    function readBytes32(address target, bytes calldata c) external view returns (bytes32) {
        return abi.decode(_read(target, c), (bytes32));
    }

    /// @notice Batch read — one staticcall per (target, calldata), raw ABI bytes returned in order.
    function readMany(address[] calldata targets, bytes[] calldata calls)
        external
        view
        returns (bytes[] memory out)
    {
        out = new bytes[](targets.length);
        for (uint256 i; i < targets.length; i++) {
            (bool ok, bytes memory r) = targets[i].staticcall(calls[i]);
            if (!ok) revert ReadFailed();
            out[i] = r;
        }
    }

    // ---- typed WRITE by consensus --------------------------------------------

    /// @notice Write the validator-DECIDED value for `(modelSpecHash, knobKey)` into `target` by
    /// calling `target.selector(value)`. Reverts if consensus has not decided the knob. The value is
    /// a 32-byte word; the selector's argument type (bool / uint / int / address / bytes32) gives it
    /// structure — so one path governs every kind of param. Idempotent: re-enacting writes the
    /// current decided value (which may have moved as the validators re-decided).
    function enact(bytes32 modelSpecHash, string calldata knobKey, address target, bytes4 selector) external {
        (uint256 value, bool decided) = consensus.valueOf(modelSpecHash, knobKey);
        if (!decided) revert NotDecided();
        (bool ok, bytes memory reason) = target.call(abi.encodeWithSelector(selector, value));
        if (!ok) revert EnactFailed(reason);
        emit Enacted(modelSpecHash, knobKey, target, selector, value);
    }
}
