// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

/**
 * @title IKarmaSource
 * @notice Minimal view of the global Karma controller's earn entrypoint
 * @dev The reputation ledger depends only on this one method, not on the concrete
 * KarmaController, so the two are decoupled (Rich Hickey: depend on the value/shape, not
 * the place). The controller mints Karma to `account` and records activity; it is gated by
 * a KARMA_SOURCE role that only the reputation ledger holds, and the controller itself
 * holds the mint authority on the Karma token — so the reputation ledger can never mint
 * Karma except through this narrow, role-gated path.
 */
interface IKarmaSource {
    /**
     * @notice Mints global Karma to an account for a positive action
     * @param account The recipient of the Karma
     * @param amount The Karma amount to mint
     * @param reason A source tag (this market encodes chainid+market+bountyId)
     */
    function earnKarma(address account, uint256 amount, bytes32 reason) external;
}

/**
 * @title IReputation
 * @notice Composable worker completion history that ALSO bridges to global Karma
 * @dev IReputation is the single canonical reputation half of the work-market. It exposes a
 * per-worker ledger (completed / disputesLost / totalEarned, read anywhere, non-transferable)
 * and a one-way bridge from a recorded completion into the GLOBAL, cross-DAO Karma reputation.
 * EIP-7201 namespaced and deployed as a UUPS proxy.
 *
 * The completion record carries a `source` tag (the work-market encodes
 * keccak256(chainid, market, bountyId)) that is BOTH the Karma reason AND the once-only
 * key: each source can bridge Karma at most once, so a completion can never double-mint.
 *
 * MONEY-PATH SAFETY (the load-bearing property): recordCompletion is called by the
 * work-market DURING a bounty payout, AFTER the escrow has already released the reward and
 * stake. The Karma bridge is therefore BEST-EFFORT — the external earnKarma call is wrapped
 * so that ANY failure (Karma soft-cap reached, controller paused, role not yet granted, a
 * controller bug) is caught and emitted, never bubbled. A reputation/Karma side-effect can
 * NEVER revert and thus can never brick a worker's payout. The local ledger increment is
 * pure storage and always succeeds; global Karma is an opportunistic projection on top.
 *
 * Karma amount is DECOUPLED from the reward amount: each completion bridges a flat,
 * owner-configurable `karmaPerCompletion`, not the raw reward. Rewards span native / ERC-20
 * / ERC-721 / ERC-1155 with incommensurable units (an NFT reward has amount 1), and a
 * reward-proportional score would both be meaningless across asset classes and let a
 * self-funded whale bounty farm the Karma cap. A flat per-completion award is the only
 * coherent, Sybil-resistant choice.
 */
interface IReputation {
    // --- Errors ---

    /** @notice Thrown when a non-writer attempts to record an outcome */
    error OnlyWriter();

    /** @notice Thrown when initializing with a zero writer address */
    error InvalidWriter();

    /** @notice Thrown when recording for the zero address */
    error InvalidWorker();

    // --- Structs ---

    /**
     * @notice A worker's cumulative, non-transferable standing (local to this market)
     * @param completed Number of bounties the worker delivered and had accepted
     * @param disputesLost Number of bounties resolved against the worker
     * @param totalEarned Cumulative value paid out to the worker across bounties
     */
    struct Reputation {
        uint64 completed;
        uint64 disputesLost;
        uint256 totalEarned;
    }

    // --- Events ---

    /**
     * @notice Emitted when a worker completes a bounty (local ledger increment)
     * @param worker The worker credited
     * @param amount The value earned on this completion
     * @param completed The worker's new completed count
     * @param totalEarned The worker's new cumulative earnings
     */
    event CompletionRecorded(address indexed worker, uint256 amount, uint64 completed, uint256 totalEarned);

    /**
     * @notice Emitted when a dispute is resolved against a worker
     * @param worker The worker debited a dispute loss
     * @param disputesLost The worker's new disputes-lost count
     */
    event DisputeLossRecorded(address indexed worker, uint64 disputesLost);

    /**
     * @notice Emitted when a completion successfully bridged into global Karma
     * @param worker The worker credited with Karma
     * @param karmaAmount The flat Karma amount minted
     * @param source The once-only source tag (also the Karma reason)
     */
    event KarmaBridged(address indexed worker, uint256 karmaAmount, bytes32 indexed source);

    /**
     * @notice Emitted when the Karma bridge was a no-op for a completion
     * @dev Either the bridge is disabled (no controller / zero per-completion) or this
     * source already bridged. The local completion is still recorded.
     * @param worker The worker whose completion did not bridge
     * @param source The source tag
     */
    event KarmaBridgeSkipped(address indexed worker, bytes32 indexed source);

    /**
     * @notice Emitted when the Karma bridge attempt reverted and was caught (best-effort)
     * @dev The payout still succeeds; a governance keeper may re-mint later using `source`.
     * @param worker The worker whose Karma mint failed
     * @param karmaAmount The Karma amount that failed to mint
     * @param source The source tag (also the intended Karma reason)
     * @param reason The low-level revert data from the controller
     */
    event KarmaBridgeFailed(address indexed worker, uint256 karmaAmount, bytes32 indexed source, bytes reason);

    /**
     * @notice Emitted when the owner reconfigures the Karma bridge
     * @param karmaController The new controller (address(0) disables the bridge)
     * @param karmaPerCompletion The new flat per-completion Karma award
     */
    event KarmaConfigUpdated(address indexed karmaController, uint256 karmaPerCompletion);

    // --- View Functions ---

    /**
     * @notice The only address permitted to record outcomes (the work-market contract)
     * @return writer The authorized writer
     */
    function writer() external view returns (address writer);

    /**
     * @notice Returns a worker's full reputation record (local to this market)
     * @param worker The address to query
     * @return completed Accepted-bounty count
     * @return disputesLost Lost-dispute count
     * @return totalEarned Cumulative earnings
     */
    function reputationOf(
        address worker
    ) external view returns (uint64 completed, uint64 disputesLost, uint256 totalEarned);

    /**
     * @notice Returns a worker's completed-bounty count
     * @param worker The address to query
     * @return completed Accepted-bounty count
     */
    function completedOf(address worker) external view returns (uint64 completed);

    /**
     * @notice Returns a worker's cumulative earnings
     * @param worker The address to query
     * @return totalEarned Cumulative earnings
     */
    function earnedOf(address worker) external view returns (uint256 totalEarned);

    /**
     * @notice The global Karma controller this market bridges completions into
     * @return karmaController The controller address (address(0) if the bridge is disabled)
     */
    function karmaController() external view returns (address karmaController);

    /**
     * @notice The flat Karma amount minted per completion
     * @return amount The per-completion Karma award (0 disables the bridge)
     */
    function karmaPerCompletion() external view returns (uint256 amount);

    /**
     * @notice Whether a given completion source already bridged Karma
     * @param source The source tag
     * @return minted True if Karma already bridged for this source (double-mint guard)
     */
    function karmaMinted(bytes32 source) external view returns (bool minted);

    // --- State-Changing Functions ---

    /**
     * @notice Records an accepted completion for a worker and bridges it into global Karma
     * @dev Writer-only. Increments the local ledger (always), then best-effort mints
     * `karmaPerCompletion` global Karma to the worker keyed once-only by `source`. The Karma
     * call can never revert this function — a delivered worker's payout is never blocked by a
     * Karma failure.
     * @param worker The worker credited
     * @param amount The value earned on this completion (added to local totalEarned)
     * @param source The once-only completion tag (chainid+market+bountyId); the Karma reason
     */
    function recordCompletion(address worker, uint256 amount, bytes32 source) external;

    /**
     * @notice Records a dispute resolved against a worker (local only; no Karma effect)
     * @dev Writer-only. Increments disputesLost. Dispute losses do not slash Karma —
     * Karma slashing stays Safe-governed on the Karma token, orthogonal to this market.
     * @param worker The worker debited
     */
    function recordDisputeLoss(address worker) external;

    /**
     * @notice Re-attempts a Karma bridge that previously failed transiently (owner-only)
     * @dev Owner (org Safe) only. Because a failed bridge RELEASES the once-only key, this can
     * re-mint a completion's Karma after the transient cause is cleared (unpause / raise cap). It
     * grants no new privilege — the owner is the Karma admin and can mint directly regardless.
     * Still exactly-once: if the source already succeeded, it is a no-op.
     * @param worker The worker to credit
     * @param source The completion source tag (from a KarmaBridgeFailed event)
     */
    function retryKarmaBridge(address worker, bytes32 source) external;

    /**
     * @notice Sets the global Karma controller (owner-only; Safe-governed in production)
     * @dev address(0) disables the bridge (completions still record locally).
     * @param karmaController The new controller
     */
    function setKarmaController(address karmaController) external;

    /**
     * @notice Sets the flat per-completion Karma award (owner-only; Safe-governed)
     * @param amount The new per-completion Karma award (0 disables minting)
     */
    function setKarmaPerCompletion(uint256 amount) external;
}
