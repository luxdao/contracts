// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

/**
 * @title IReputationV1
 * @notice Composable, non-transferable on-chain completion history for workers
 * @dev ReputationV1 is a minimal, read-anywhere ledger of work-market outcomes:
 * per address it counts completed (accepted) bounties, total value earned, and
 * disputes lost. It is NOT a token — there is nothing to transfer or trade; it is
 * pure reputation, so any contract or UI can read a worker's standing and compose
 * its own gating, ranking, or display on top of it without coordinating with this
 * contract (Rich Hickey: values over places).
 *
 * Exactly ONE writer (the bounty/work-market contract) is authorized to record
 * outcomes, set once at initialization. This keeps the "what happened" authority
 * with the contract that actually adjudicates work, while the "who reads it" set
 * stays open. Records are monotonic increments — history is append-only.
 */
interface IReputationV1 {
    // --- Errors ---

    /** @notice Thrown when a non-writer attempts to record an outcome */
    error OnlyWriter();

    /** @notice Thrown when initializing with a zero writer address */
    error InvalidWriter();

    /** @notice Thrown when recording for the zero address */
    error InvalidWorker();

    // --- Structs ---

    /**
     * @notice A worker's cumulative, non-transferable standing
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
     * @notice Emitted when a worker completes a bounty
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

    // --- View Functions ---

    /**
     * @notice The only address permitted to record outcomes (the work-market contract)
     * @return writer The authorized writer
     */
    function writer() external view returns (address writer);

    /**
     * @notice Returns a worker's full reputation record
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

    // --- State-Changing Functions ---

    /**
     * @notice Records an accepted completion for a worker
     * @dev Writer-only. Increments completed and adds to totalEarned.
     * @param worker The worker credited
     * @param amount The value earned on this completion
     */
    function recordCompletion(address worker, uint256 amount) external;

    /**
     * @notice Records a dispute resolved against a worker
     * @dev Writer-only. Increments disputesLost.
     * @param worker The worker debited
     */
    function recordDisputeLoss(address worker) external;
}
