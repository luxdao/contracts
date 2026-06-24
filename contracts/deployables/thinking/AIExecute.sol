// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

/// @notice Tier-1 source: a knob's continuously-DECIDED value (the AIParams / ThinkingParameters median).
interface IThinkingValue {
    function valueOf(bytes32 modelSpecHash, string calldata knobKey)
        external
        view
        returns (uint256 value, bool decided);
}

/// @notice Tier-3 source: whether an OPERATION hash has been approved by the thinking-quorum, and when.
interface IConsensusApproval {
    function approved(bytes32 operationHash) external view returns (bool ok, uint64 approvedAt);
}

/// @notice Optional policy guard. Mechanism (this contract) stays orthogonal to policy (the guard):
/// a deployment plugs allowlists / value caps / rate limits, or runs guardless (consensus is the gate).
/// `check` MAY mutate (rate-limit bookkeeping); it MUST revert to reject.
interface IGuard {
    function check(address target, uint256 value, bytes calldata data) external;
}

/// @title AIExecute — the ONE surface validator CONSENSUS uses to read and act on-chain.
///
/// Three tiers, one mechanism, decomplected by risk — not three contracts:
///
///   READ    {read*} staticcall any getter and hand back a TYPED value (yes/no, a number, an address,
///           a word). The AI queries arbitrary on-chain state structured.
///
///   ENACT   (Tier 1) {enact} reads a knob the validators have DECIDED in AIParams and splices its value
///           as the sole argument of `target.selector(value)`. A 32-byte word ABI-encodes to ANY single
///           type, so ONE call sets a bool / uint / int / address / bytes32 — the selector picks the
///           structure. Low-risk, idempotent, NO timelock: the value IS the consensus output.
///
///   EXECUTE (Tier 2/3) {execute} runs an ARBITRARY operation — any target, any method, any arguments,
///           any native value — that the validators approved by its hash. High-risk, so it is gated by a
///           timelock window, predecessor ordering, one-shot, a guardian veto, and the optional guard.
///           (Tier 2 "ABI-routed call" is just {execute} with structured calldata; Tier 3 is raw bytes.)
///
/// The operation hash binds chainId + this executor, so an approval can never be replayed on another
/// chain or another executor instance. Governance-neutral and OSS: any chain descending from the Lux
/// primary network can point this at its own quorum and govern any contract.
contract AIExecute {
    /// An operation is a value. Its hash is what consensus approves; the parts bind the exact call.
    struct Operation {
        address target;
        uint256 value;
        bytes data; // full calldata — selector + ABI-encoded args, or empty for a plain transfer
        bytes32 predecessor; // op that must execute first (0 = none)
        bytes32 salt; // disambiguates otherwise-identical ops
        uint64 earliestExecTime; // proposer-declared earliest (0 = as soon as the protocol floor allows)
        uint64 expiryTime; // proposer-declared expiry (0 = never expires)
    }

    IThinkingValue public immutable params; // Tier-1 decided values
    IConsensusApproval public immutable approvals; // Tier-3 op approvals
    uint64 public immutable minDelay; // protocol floor: min wait from approval to execution

    IGuard public guard; // 0 = permissive
    address public guardian; // emergency veto / policy admin (SHOULD be a Safe or the timelock itself)

    mapping(bytes32 => bool) public executed;
    mapping(bytes32 => bool) public canceled;

    event Enacted(
        bytes32 indexed modelSpecHash, string knobKey, address indexed target, bytes4 selector, uint256 value
    );
    event Executed(bytes32 indexed operationId, address indexed target, uint256 value, bytes data, bytes result);
    event Canceled(bytes32 indexed operationId);
    event GuardSet(address indexed guard);
    event GuardianSet(address indexed guardian);

    error ReadFailed();
    error NotDecided();
    error EnactFailed(bytes reason);
    error NotApproved();
    error Timelocked(uint64 executableAt);
    error Expired(uint64 expiredAt);
    error PredecessorPending(bytes32 predecessor);
    error AlreadyExecuted();
    error OperationCanceled();
    error CallReverted(bytes reason);
    error NotGuardian();

    constructor(address params_, address approvals_, uint64 minDelay_, address guardian_) {
        params = IThinkingValue(params_);
        approvals = IConsensusApproval(approvals_);
        minDelay = minDelay_;
        guardian = guardian_;
        emit GuardianSet(guardian_);
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    // ---- structured READ (any contract's state, typed) -----------------------

    function _read(address target, bytes calldata c) private view returns (bytes memory) {
        (bool ok, bytes memory ret) = target.staticcall(c);
        if (!ok) revert ReadFailed();
        return ret;
    }

    function read(address target, bytes calldata c) external view returns (bytes memory) {
        return _read(target, c);
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

    /// @notice Batch read — one staticcall per (target, calldata), raw ABI bytes in order.
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

    // ---- Tier 1: typed ENACT of a decided knob (no timelock) -----------------

    /// @notice Write the validator-DECIDED value for `(modelSpecHash, knobKey)` into `target` via
    /// `target.selector(value)`. The selector's argument type gives the 32-byte word its structure, so
    /// this one call governs a bool / uint / int / address / bytes32 alike. The guard, if set, still
    /// vets the (target, selector). No window: a decided knob is low-risk and idempotent.
    function enact(bytes32 modelSpecHash, string calldata knobKey, address target, bytes4 selector)
        external
        returns (bytes memory)
    {
        (uint256 value, bool decided) = params.valueOf(modelSpecHash, knobKey);
        if (!decided) revert NotDecided();
        bytes memory data = abi.encodeWithSelector(selector, value);
        if (address(guard) != address(0)) guard.check(target, 0, data);
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) revert EnactFailed(ret);
        emit Enacted(modelSpecHash, knobKey, target, selector, value);
        return ret;
    }

    // ---- Tier 2/3: arbitrary EXECUTE of an approved operation (windowed) ------

    /// @notice The id the validators approve to authorize an operation. Binds chainId + this executor so
    /// the approval is non-replayable across chains/instances, and every part so it binds the exact call.
    function hashOperation(Operation calldata op) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                block.chainid,
                address(this),
                op.target,
                op.value,
                keccak256(op.data),
                op.predecessor,
                op.salt,
                op.earliestExecTime,
                op.expiryTime
            )
        );
    }

    /// @notice When an approved op becomes executable: the later of its declared earliest and the
    /// protocol floor (approval time + minDelay). The proposer may ask for MORE delay, never less.
    function executableAt(Operation calldata op) public view returns (bool ok, uint64 at) {
        (bool approved, uint64 approvedAt) = approvals.approved(hashOperation(op));
        if (!approved) return (false, 0);
        uint64 floorTime = approvedAt + minDelay;
        at = op.earliestExecTime > floorTime ? op.earliestExecTime : floorTime;
        ok = true;
    }

    /// @notice Execute an approved operation inside its window. Permissionless — the approval is the
    /// authority, not the caller. Returns the call's raw return data (typed by the target's ABI), so a
    /// structured result (yes/no, a number, …) flows back to whoever reads the {Executed} event or the
    /// return value.
    function execute(Operation calldata op) external payable returns (bytes memory) {
        bytes32 id = hashOperation(op);
        if (canceled[id]) revert OperationCanceled();
        if (executed[id]) revert AlreadyExecuted();

        (bool ok, uint64 startTime) = executableAt(op);
        if (!ok) revert NotApproved();
        if (block.timestamp < startTime) revert Timelocked(startTime);
        if (op.expiryTime != 0 && block.timestamp > op.expiryTime) revert Expired(op.expiryTime);
        if (op.predecessor != bytes32(0) && !executed[op.predecessor]) revert PredecessorPending(op.predecessor);
        if (address(guard) != address(0)) guard.check(op.target, op.value, op.data);

        executed[id] = true; // EFFECTS before INTERACTION
        (bool s, bytes memory ret) = op.target.call{value: op.value}(op.data);
        if (!s) revert CallReverted(ret);
        emit Executed(id, op.target, op.value, op.data, ret);
        return ret;
    }

    // ---- guardian: emergency veto + policy admin -----------------------------

    /// @notice Veto an operation before it executes. The break-glass control: the chain can kill a
    /// malicious approval during its timelock window. One-way (an executed op cannot be canceled).
    function cancel(bytes32 operationId) external onlyGuardian {
        if (executed[operationId]) revert AlreadyExecuted();
        canceled[operationId] = true;
        emit Canceled(operationId);
    }

    function setGuard(IGuard g) external onlyGuardian {
        guard = g;
        emit GuardSet(address(g));
    }

    function setGuardian(address g) external onlyGuardian {
        guardian = g;
        emit GuardianSet(g);
    }
}
