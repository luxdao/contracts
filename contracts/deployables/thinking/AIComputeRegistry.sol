// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

/// @title AIComputeRegistry — the GLOBAL compute-claim ledger that reconciles AI minting across
/// EVERY Lux chain, so a unit of AI work mints its subsidy EXACTLY ONCE, network-wide.
///
/// The problem this closes: a proof's on-chain binding includes the chain id, so the SAME proof
/// cannot be replayed on another chain — but a prover could do the work ONCE and submit DISTINCT
/// (chain-bound) proofs of the same computation to many chains, minting the fair-launch subsidy N
/// times for one piece of work. The registry keys on the CHAIN-INDEPENDENT computation commitment
/// `keccak(DOMAIN ‖ modelSpec ‖ promptHash ‖ outputHash)` and records the first claimant. A second
/// claim for the same computation — from any miner, any chain — reverts. First-correct-proof wins;
/// redundant recomputation earns nothing, which is exactly the Bitcoin-style incentive to do NOVEL
/// work rather than re-mine what is already settled.
///
/// This is the A-Chain (aivm) reconciliation ledger expressed at the EVM layer. On the Lux primary
/// network it is a single instance every miner calls directly. On a separate L1 the miner gates on
/// the registry's committed root, relayed in trustlessly (see {AChainRootOracle}); the key space is
/// identical, so a claim anywhere is visible everywhere.
contract AIComputeRegistry {
    /// @notice Domain tag for the computation key — disjoint from any other keccak preimage.
    bytes32 public constant DOMAIN = keccak256("hanzo/poi/compute-claim/v1");

    /// @notice computationKey => the miner contract that first claimed it (address(0) = unclaimed).
    mapping(bytes32 => address) public claimedBy;

    /// @notice The chain on which a computation was claimed (for cross-chain audit).
    mapping(bytes32 => uint256) public claimedOnChain;

    /// @notice Authorized miner contracts (per chain). A claimer is always a proof-enforcing
    /// CONTRACT, never an EOA — the same god-key defense as the coin's mint seam.
    mapping(address => bool) public isMiner;

    /// @notice Governance that manages the miner set (a Safe/timelock in production).
    address public admin;

    event Claimed(bytes32 indexed computationKey, address indexed miner, uint256 chainId);
    event MinerSet(address indexed miner, bool allowed);
    event AdminTransferred(address indexed from, address indexed to);

    error AlreadyClaimed(bytes32 computationKey, address by, uint256 onChain);
    error NotMiner();
    error NotAdmin();
    error MinerMustBeContract();
    error ZeroAddress();

    constructor(address admin_) {
        admin = admin_ == address(0) ? msg.sender : admin_;
    }

    /// @notice The chain-independent computation commitment. Identical across chains for the same
    /// `(model, prompt, output)`, so it is the global key a subsidy mints against exactly once.
    function computationKey(bytes32 modelSpec, bytes32 promptHash, bytes32 outputHash)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(DOMAIN, modelSpec, promptHash, outputHash));
    }

    /// @notice Atomically claim a computation for minting. Reverts {AlreadyClaimed} if it was already
    /// claimed by any miner on any chain — the global first-claim-wins guarantee. Called by an
    /// authorized miner inside its mint flow, BEFORE the external mint (CEI), so a mint revert also
    /// rolls back the claim.
    function claim(bytes32 computationKey_) external {
        if (!isMiner[msg.sender]) revert NotMiner();
        address by = claimedBy[computationKey_];
        if (by != address(0)) revert AlreadyClaimed(computationKey_, by, claimedOnChain[computationKey_]);
        claimedBy[computationKey_] = msg.sender;
        claimedOnChain[computationKey_] = block.chainid;
        emit Claimed(computationKey_, msg.sender, block.chainid);
    }

    /// @notice Whether a computation has already been claimed (a keeper/dashboard read).
    function isClaimed(bytes32 computationKey_) external view returns (bool) {
        return claimedBy[computationKey_] != address(0);
    }

    // ---- governance ----------------------------------------------------------

    /// @notice Authorize/deauthorize a miner contract. A miner MUST be a contract (never an EOA):
    /// the only thing that can claim is a proof-enforcing miner whose code gates the mint.
    function setMiner(address miner_, bool allowed) external {
        if (msg.sender != admin) revert NotAdmin();
        if (allowed && miner_.code.length == 0) revert MinerMustBeContract();
        isMiner[miner_] = allowed;
        emit MinerSet(miner_, allowed);
    }

    function transferAdmin(address admin_) external {
        if (msg.sender != admin) revert NotAdmin();
        if (admin_ == address(0)) revert ZeroAddress();
        emit AdminTransferred(admin, admin_);
        admin = admin_;
    }
}
