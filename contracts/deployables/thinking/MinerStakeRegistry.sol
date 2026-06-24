// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

/// @title MinerStakeRegistry -- an AI miner publicly bonds capital to provide compute, in proportion
/// to the capacity it declares. The bond is skin in the game: a fraud proof slashes it automatically,
/// and governance may blacklist for harm the math cannot catch.
///
/// Three orthogonal authorities, one per concern (kept apart on purpose):
///   - the MINER controls its own bond (bond / request-unbond / withdraw), with a cooldown so a
///     discrepancy can be proven before it exits;
///   - the SLASHER (the compute-proof fraud verifier) slashes a bond on a PROVEN discrepancy -- no
///     vote, just the math, trustless;
///   - GOVERNANCE (a Safe) may blacklist a miner for off-protocol harm.
///
/// A miner is {eligible} to mine iff it is bonded above the floor, bonded in proportion to its
/// declared capacity, not exiting, and not blacklisted. The mint gate reads {eligible}; whether any
/// single mint is honest is the compute proof's job; the social layer is governance's. Nothing here
/// knows about proofs or coins -- it only holds value at risk.
contract MinerStakeRegistry {
    mapping(address => uint256) public bonded; // wei at risk
    mapping(address => uint256) public capacity; // declared compute units
    mapping(address => uint64) public unbondAt; // 0 = bonded; else when withdrawal opens
    mapping(address => bool) public blacklisted; // governance veto

    uint256 public immutable minBond; // floor to be eligible at all
    uint256 public immutable bondPerUnit; // required wei per declared capacity unit
    uint64 public immutable cooldown; // unbond delay (the fraud window)

    address public admin; // governance (Safe)
    address public slasher; // the fraud-proof verifier authorized to slash

    event Bonded(address indexed miner, uint256 added, uint256 capacity);
    event UnbondRequested(address indexed miner, uint64 withdrawAt);
    event Withdrawn(address indexed miner, uint256 amount);
    event Slashed(address indexed miner, uint256 amount, address indexed to);
    event Blacklisted(address indexed miner, bool on);
    event SlasherSet(address indexed slasher);
    event AdminTransferred(address indexed from, address indexed to);

    error NotAdmin();
    error NotSlasher();
    error Blacklisted_();
    error Underbonded();
    error NothingBonded();
    error CoolingDown();
    error TransferFailed();
    error ZeroAddress();

    constructor(uint256 minBond_, uint256 bondPerUnit_, uint64 cooldown_, address admin_) {
        minBond = minBond_;
        bondPerUnit = bondPerUnit_;
        cooldown = cooldown_;
        admin = admin_ == address(0) ? msg.sender : admin_;
    }

    // ---- the miner controls its own bond -------------------------------------

    /// @notice Bond capital and declare capacity. Bond must cover both the floor and
    /// `capacity*bondPerUnit`, so more declared compute means more at risk. Re-bonding adds and
    /// cancels any pending exit.
    function bond(uint256 declaredCapacity) external payable {
        if (blacklisted[msg.sender]) revert Blacklisted_();
        bonded[msg.sender] += msg.value;
        capacity[msg.sender] = declaredCapacity;
        unbondAt[msg.sender] = 0;
        if (bonded[msg.sender] < minBond || bonded[msg.sender] < declaredCapacity * bondPerUnit) {
            revert Underbonded();
        }
        emit Bonded(msg.sender, msg.value, declaredCapacity);
    }

    /// @notice Begin exiting: starts the cooldown. The miner is ineligible at once but cannot
    /// withdraw until the cooldown elapses -- long enough to prove fraud against a fleeing miner.
    function requestUnbond() external {
        if (bonded[msg.sender] == 0) revert NothingBonded();
        unbondAt[msg.sender] = uint64(block.timestamp) + cooldown;
        emit UnbondRequested(msg.sender, unbondAt[msg.sender]);
    }

    /// @notice Withdraw the bond after the cooldown (if not slashed away).
    function withdraw() external {
        uint64 t = unbondAt[msg.sender];
        if (t == 0 || block.timestamp < t) revert CoolingDown();
        uint256 amt = bonded[msg.sender];
        bonded[msg.sender] = 0;
        capacity[msg.sender] = 0;
        unbondAt[msg.sender] = 0;
        (bool ok,) = payable(msg.sender).call{value: amt}("");
        if (!ok) revert TransferFailed();
        emit Withdrawn(msg.sender, amt);
    }

    // ---- automated slashing (the fraud-proof verifier) -----------------------

    /// @notice Slash a miner's bond on a PROVEN discrepancy (called by the compute-proof fraud
    /// verifier, not by a vote). Pays the slashed amount to `to` (the challenger). Works during the
    /// unbond cooldown, so a miner cannot dodge a fraud proof by exiting first.
    function slash(address miner, uint256 amount, address to) external {
        if (msg.sender != slasher) revert NotSlasher();
        uint256 b = bonded[miner];
        uint256 amt = amount > b ? b : amount;
        bonded[miner] = b - amt; // EFFECTS before INTERACTION
        emit Slashed(miner, amt, to);
        (bool ok,) = payable(to).call{value: amt}("");
        if (!ok) revert TransferFailed();
    }

    // ---- governance (the social layer) ---------------------------------------

    function setBlacklist(address miner, bool on) external {
        if (msg.sender != admin) revert NotAdmin();
        blacklisted[miner] = on;
        emit Blacklisted(miner, on);
    }

    function setSlasher(address slasher_) external {
        if (msg.sender != admin) revert NotAdmin();
        slasher = slasher_;
        emit SlasherSet(slasher_);
    }

    function transferAdmin(address admin_) external {
        if (msg.sender != admin) revert NotAdmin();
        if (admin_ == address(0)) revert ZeroAddress();
        emit AdminTransferred(admin, admin_);
        admin = admin_;
    }

    // ---- the one read the mint gate needs ------------------------------------

    /// @notice Eligible to mine iff bonded above the floor and in proportion to declared capacity,
    /// not exiting, and not blacklisted.
    function eligible(address miner) external view returns (bool) {
        return !blacklisted[miner] && unbondAt[miner] == 0 && bonded[miner] >= minBond
            && bonded[miner] >= capacity[miner] * bondPerUnit;
    }
}
