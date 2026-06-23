// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

/// @title AIReceiptRoots — committed A-Chain receipt roots, anchored on THIS EVM.
/// @notice The Lux A-Chain (aivm) settles an inference under its own consensus + provider
/// quorum and commits a keccak merkle root over the resulting receipts (chains/aivm
/// receipts.go). That root reaches an EVM one of two ways:
///
///   1. NATIVE (any Lux EVM): the aivmbridge precompile reads the root from C-committed
///      state at the A->C atomic boundary (precompile/aivmbridge/state.go CommitReceiptRoot).
///   2. PORTABLE (any EVM): a warp/bridge relay anchors the root here.
///
/// Either way the root lands in this registry, and a pure-Solidity verifier
/// ({AICoinMiner}) checks receipt inclusion against a root this registry has accepted.
/// Decoupling the root SOURCE (host-specific) from the mint POLICY (one verifier, any
/// EVM) is what makes "any EVM can mint" true — one and only one verification path.
contract AIReceiptRoots {
    /// @notice Governance that manages the relayer set.
    address public admin;

    /// @notice Addresses permitted to anchor A-Chain roots (the warp/bridge relay, or a
    /// host adapter that mirrors the precompile-committed root). NOT the mint authority —
    /// a relayer can only assert "the A-Chain committed this root", never mint.
    mapping(address => bool) public isRelayer;

    /// @notice root => true once anchored. Membership is the whole trust statement: a
    /// receipt is mintable iff it proves inclusion under a root in this set.
    mapping(bytes32 => bool) public isKnownRoot;

    /// @notice root => the A-Chain block height it was committed at (informational:
    /// finality / monotonicity tracking by off-chain consumers and dashboards).
    mapping(bytes32 => uint64) public rootHeight;

    event RootAnchored(bytes32 indexed root, uint64 indexed aChainHeight, address indexed relayer);
    event RelayerSet(address indexed relayer, bool allowed);
    event AdminTransferred(address indexed from, address indexed to);

    error NotAdmin();
    error NotRelayer();
    error ZeroRoot();

    constructor(address admin_) {
        admin = admin_ == address(0) ? msg.sender : admin_;
    }

    function setRelayer(address relayer, bool allowed) external {
        if (msg.sender != admin) revert NotAdmin();
        isRelayer[relayer] = allowed;
        emit RelayerSet(relayer, allowed);
    }

    function transferAdmin(address admin_) external {
        if (msg.sender != admin) revert NotAdmin();
        emit AdminTransferred(admin, admin_);
        admin = admin_;
    }

    /// @notice Anchor an A-Chain receipt root committed at `aChainHeight`. Idempotent on
    /// `root` (re-anchoring keeps the first height). The relayer attests only that the
    /// A-Chain committed this root; the merkle proof a miner submits does the rest.
    function anchorRoot(bytes32 root, uint64 aChainHeight) external {
        if (!isRelayer[msg.sender]) revert NotRelayer();
        if (root == bytes32(0)) revert ZeroRoot();
        if (!isKnownRoot[root]) {
            isKnownRoot[root] = true;
            rootHeight[root] = aChainHeight;
            emit RootAnchored(root, aChainHeight, msg.sender);
        }
    }
}
