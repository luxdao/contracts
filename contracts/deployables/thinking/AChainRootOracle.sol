// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

/// @notice The ML-DSA verification precompile (post-quantum signatures). Lives at the AI/PQ range
/// address; verifies an ML-DSA-65 signature over a message by a public key.
interface IMLDSAVerify {
    function verify(bytes calldata publicKey, bytes calldata message, bytes calldata signature)
        external
        view
        returns (bool valid);
}

/// @title AChainRootOracle — the TRUSTLESS, PERMISSIONLESS, POST-QUANTUM relay of A-Chain state to
/// any EVM, so every Lux chain shares one global view of AI settlement without trusting a bridge.
///
/// The A-Chain (aivm) commits its receipt-root + consumed-set-root each epoch and a QUORUM of the
/// A-Chain validators signs `(root, height)` with ML-DSA (the same post-quantum scheme luxfi/warp
/// carries as an MLDSACertSet). ANYONE may relay a signed root here — permissionless, a public good —
/// and the oracle VERIFIES the quorum on-chain via the ML-DSA precompile (trustless: a relayer can
/// only assert what the validators signed, never forge it, never mint). Miners on any chain gate on
/// {isKnownRoot}, so the global compute-claim ledger (AIComputeRegistry) is reconciled network-wide.
///
/// Security: forging an accepted root requires breaking ML-DSA (post-quantum hard) OR corrupting
/// ≥ {threshold} of the A-Chain validator set — the nation-state-resistant bar. This REPLACES the
/// trusted single-relayer model (AIReceiptRoots.setRelayer) with a verified validator quorum.
contract AChainRootOracle {
    /// @notice Domain tag for the signed `(root, height)` preimage.
    bytes32 public constant DOMAIN = keccak256("hanzo/aivm/achain-root/v1");

    /// @notice The ML-DSA verification precompile.
    IMLDSAVerify public immutable mldsa;

    /// @notice keccak(validator ML-DSA public key) => is in the current A-Chain validator set.
    mapping(bytes32 => bool) public isValidatorKey;

    /// @notice Number of distinct validator keys currently registered.
    uint256 public validatorCount;

    /// @notice Minimum distinct validator signatures to accept a root (the quorum).
    uint256 public threshold;

    /// @notice Governance (a Safe) that manages the validator set + threshold. In the fully
    /// sovereign model this is itself driven by the A-Chain's on-chain staking set.
    address public admin;

    /// @notice Accepted A-Chain roots (receipt-root / consumed-set-root). Miners verify inclusion here.
    mapping(bytes32 => bool) public isKnownRoot;

    /// @notice The A-Chain height of the latest accepted root (monotone — no rollback).
    uint64 public latestHeight;

    event RootAnchored(bytes32 indexed root, uint64 indexed height, uint256 signers);
    event ValidatorSet(bytes32 indexed keyHash, bool inSet);
    event ThresholdSet(uint256 threshold);
    event AdminTransferred(address indexed from, address indexed to);

    error NotAdmin();
    error ZeroAddress();
    error StaleHeight(uint64 height, uint64 latest);
    error NotValidator(bytes32 keyHash);
    error SignersNotAscending();
    error QuorumNotMet(uint256 got, uint256 need);
    error BadThreshold();

    constructor(address mldsa_, address admin_) {
        if (mldsa_ == address(0)) revert ZeroAddress();
        mldsa = IMLDSAVerify(mldsa_);
        admin = admin_ == address(0) ? msg.sender : admin_;
    }

    /// @notice PERMISSIONLESS: relay an A-Chain root signed by a validator quorum. `pubkeys[i]` and
    /// `sigs[i]` are the i-th signer's ML-DSA key + signature over `keccak(DOMAIN ‖ root ‖ height)`.
    /// Accepts iff every key is a registered validator, the keys are strictly ascending (distinct,
    /// no double counting), at least {threshold} signatures verify, and `height` advances. Anyone may
    /// call; the oracle trusts only the math.
    function anchorRoot(bytes32 root, uint64 height, bytes[] calldata pubkeys, bytes[] calldata sigs)
        external
    {
        if (height <= latestHeight) revert StaleHeight(height, latestHeight);
        bytes memory message = abi.encodePacked(DOMAIN, root, height);
        uint256 valid;
        bytes32 last; // strictly-ascending key hashes ⇒ each validator counted at most once
        uint256 n = pubkeys.length;
        for (uint256 i; i < n; i++) {
            bytes32 kh = keccak256(pubkeys[i]);
            if (!isValidatorKey[kh]) revert NotValidator(kh);
            if (kh <= last) revert SignersNotAscending();
            last = kh;
            if (mldsa.verify(pubkeys[i], message, sigs[i])) {
                valid++;
            }
        }
        if (valid < threshold) revert QuorumNotMet(valid, threshold);
        isKnownRoot[root] = true;
        latestHeight = height;
        emit RootAnchored(root, height, valid);
    }

    // ---- governance: the A-Chain validator set + quorum ----------------------

    /// @notice Add/remove a validator's ML-DSA public key from the set.
    function setValidator(bytes calldata publicKey, bool inSet) external {
        if (msg.sender != admin) revert NotAdmin();
        bytes32 kh = keccak256(publicKey);
        if (inSet && !isValidatorKey[kh]) {
            isValidatorKey[kh] = true;
            validatorCount++;
        } else if (!inSet && isValidatorKey[kh]) {
            isValidatorKey[kh] = false;
            validatorCount--;
        }
        emit ValidatorSet(kh, inSet);
    }

    /// @notice Set the quorum threshold (1 ≤ threshold ≤ validatorCount).
    function setThreshold(uint256 threshold_) external {
        if (msg.sender != admin) revert NotAdmin();
        if (threshold_ == 0 || threshold_ > validatorCount) revert BadThreshold();
        threshold = threshold_;
        emit ThresholdSet(threshold_);
    }

    function transferAdmin(address admin_) external {
        if (msg.sender != admin) revert NotAdmin();
        if (admin_ == address(0)) revert ZeroAddress();
        emit AdminTransferred(admin, admin_);
        admin = admin_;
    }
}
