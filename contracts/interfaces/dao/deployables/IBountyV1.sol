// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

/**
 * @title IBountyV1
 * @notice Permissionless two-sided work-market lifecycle on top of any DAO
 * @dev BountyV1 is the policy/state-machine for a "dework"-style work market. It is
 * the sole controller of an EscrowV1 (custody) and the sole writer of a ReputationV1
 * (history) — three orthogonal contracts, one per concern. A bounty moves through a
 * single, enforced lifecycle:
 *
 *   Open -> Funded -> Claimed -> Submitted -> Accepted -> Paid
 *                 \-> Cancelled (refund)        \-> Disputed -> resolve (split/refund)
 *
 * The market is PERMISSIONLESS: anyone may propose a bounty and anyone may claim an
 * open one — there is no allowlist of who may participate. Abuse is bounded by
 * MECHANISM, not permission:
 *  - A worker must STAKE to claim. The stake is returned on an accepted submission
 *    and SLASHED (to the funder, or to a configured treasury) if the worker abandons
 *    or misses the claim deadline. This makes claim-squatting and grief-claiming
 *    economically costly without gating who may try.
 *  - A claim has a deadline; if the worker does not submit in time, anyone may
 *    reclaim the bounty (slashing the stuck stake), so claims cannot be squatted.
 *  - Illegal lifecycle transitions revert — a legitimate state invariant, not a
 *    discretionary gate.
 *
 * The "approver" (who may accept work) is configurable per bounty: a designated
 * reviewer address for small bounties, or the owning Safe/governance for large ones.
 * Either way authorization is cryptographic (the caller IS the approver address),
 * so a post-quantum-signed Safe can be funder and/or approver with no special-casing.
 *
 * Funds are custodied in EscrowV1 keyed by bountyId for the reward and a separate
 * key for the worker's stake, so reward and stake accounting never cross. The escrow
 * guarantees conservation and reentrancy-safety independently of this contract.
 */
interface IBountyV1 {
    // --- Enums ---

    /**
     * @notice The lifecycle state of a bounty
     * @dev Transitions are enforced; any out-of-order call reverts with InvalidState.
     */
    enum State {
        None, //      0: bounty id does not exist
        Open, //      1: proposed, reward not yet escrowed
        Funded, //    2: reward escrowed, awaiting a worker
        Claimed, //   3: a worker staked and claimed; work in progress
        Submitted, // 4: worker submitted a deliverable, awaiting review
        Accepted, //  5: approver accepted; payout authorized
        Paid, //      6: reward released to worker, stake returned (terminal)
        Disputed, //  7: submission contested; awaiting arbiter resolution
        Cancelled //  8: refunded to funder before completion (terminal)
    }

    // --- Errors ---

    /** @notice Thrown when an action is attempted from an incompatible state */
    error InvalidState(uint256 bountyId, State current, State required);

    /** @notice Thrown when referencing a bounty that does not exist */
    error UnknownBounty(uint256 bountyId);

    /** @notice Thrown when the caller is not the bounty's funder */
    error OnlyFunder();

    /** @notice Thrown when the caller is not the bounty's approver */
    error OnlyApprover();

    /** @notice Thrown when the caller is not the bounty's arbiter */
    error OnlyArbiter();

    /** @notice Thrown when the caller is not the worker who claimed the bounty */
    error OnlyWorker();

    /** @notice Thrown when a reward or stake amount is zero */
    error ZeroAmount();

    /** @notice Thrown when the approver address is zero at proposal time */
    error InvalidApprover();

    /** @notice Thrown when the claim deadline has not yet passed (for reclaim/slash) */
    error DeadlineNotPassed(uint256 bountyId, uint64 deadline);

    /** @notice Thrown when the claim deadline has already passed (for submit) */
    error DeadlinePassed(uint256 bountyId, uint64 deadline);

    /** @notice Thrown when native value is sent on a call that must not carry value */
    error UnexpectedNativeValue();

    /** @notice Thrown when a dispute resolution splits more than the escrowed reward */
    error SplitExceedsReward(uint256 bountyId, uint256 reward, uint256 requested);

    /** @notice Thrown when the claim stake msg.value/allowance does not match the configured stake */
    error StakeMismatch(uint256 expected, uint256 provided);

    // --- Structs ---

    /**
     * @notice Full record of a bounty
     * @param state Current lifecycle state
     * @param token Reward and stake asset; address(0) for native coin
     * @param funder Who funded the reward (refund target on cancel/dispute)
     * @param approver Who may accept the work (reviewer EOA or owning Safe)
     * @param arbiter Who may resolve a dispute (defaults to approver if unset)
     * @param worker The address that claimed the bounty (zero until claimed)
     * @param reward The escrowed reward amount paid to the worker on acceptance
     * @param stake The amount a worker must escrow to claim
     * @param claimDeadline Timestamp by which the worker must submit (0 until claimed)
     * @param claimWindow Seconds granted to submit after claiming
     * @param claimNonce Number of times this bounty has been claimed (keys the stake
     *        escrow per attempt so a re-claim after a slash never collides)
     */
    struct Bounty {
        State state;
        address token;
        address funder;
        address approver;
        address arbiter;
        address worker;
        uint256 reward;
        uint256 stake;
        uint64 claimDeadline;
        uint64 claimWindow;
        uint64 claimNonce;
    }

    // --- Events ---

    /**
     * @notice Emitted when a bounty is proposed
     * @param bountyId The new bounty id
     * @param funder The proposer/funder
     * @param approver The address that will review submissions
     * @param token The reward/stake asset (address(0) for native)
     * @param reward The reward amount
     * @param stake The required claim stake
     * @param issueRef A URI or content hash describing the work
     */
    event BountyProposed(
        uint256 indexed bountyId,
        address indexed funder,
        address indexed approver,
        address token,
        uint256 reward,
        uint256 stake,
        string issueRef
    );

    /**
     * @notice Emitted when a bounty's reward is escrowed
     * @param bountyId The bounty id
     * @param funder The address that funded the reward
     * @param amount The reward amount escrowed
     */
    event BountyFunded(uint256 indexed bountyId, address indexed funder, uint256 amount);

    /**
     * @notice Emitted when a worker claims a bounty by staking
     * @param bountyId The bounty id
     * @param worker The claiming worker
     * @param stake The stake escrowed
     * @param claimDeadline The timestamp by which the worker must submit
     */
    event BountyClaimed(uint256 indexed bountyId, address indexed worker, uint256 stake, uint64 claimDeadline);

    /**
     * @notice Emitted when a worker submits a deliverable
     * @param bountyId The bounty id
     * @param worker The submitting worker
     * @param deliverableRef A URI or content hash of the deliverable
     */
    event WorkSubmitted(uint256 indexed bountyId, address indexed worker, string deliverableRef);

    /**
     * @notice Emitted when the approver accepts the work
     * @param bountyId The bounty id
     * @param approver The accepting approver
     * @param worker The worker being paid
     */
    event WorkAccepted(uint256 indexed bountyId, address indexed approver, address indexed worker);

    /**
     * @notice Emitted when the reward is released and stake returned to the worker
     * @param bountyId The bounty id
     * @param worker The paid worker
     * @param reward The reward paid
     * @param stakeReturned The stake returned
     */
    event PaymentReleased(uint256 indexed bountyId, address indexed worker, uint256 reward, uint256 stakeReturned);

    /**
     * @notice Emitted when a submission is disputed
     * @param bountyId The bounty id
     * @param disputer The address raising the dispute (funder or approver)
     * @param reasonRef A URI or content hash of the dispute reason
     */
    event BountyDisputed(uint256 indexed bountyId, address indexed disputer, string reasonRef);

    /**
     * @notice Emitted when an arbiter resolves a dispute
     * @param bountyId The bounty id
     * @param arbiter The resolving arbiter
     * @param workerAmount Reward portion paid to the worker
     * @param funderAmount Reward portion refunded to the funder
     * @param workerKeepsStake Whether the worker's stake was returned (true) or slashed (false)
     */
    event DisputeResolved(
        uint256 indexed bountyId,
        address indexed arbiter,
        uint256 workerAmount,
        uint256 funderAmount,
        bool workerKeepsStake
    );

    /**
     * @notice Emitted when a bounty is cancelled and the reward refunded
     * @param bountyId The bounty id
     * @param funder The refunded funder
     * @param amount The refunded reward
     */
    event BountyCancelled(uint256 indexed bountyId, address indexed funder, uint256 amount);

    /**
     * @notice Emitted when a worker's stake is slashed for abandonment/timeout
     * @param bountyId The bounty id
     * @param worker The slashed worker
     * @param to The recipient of the slashed stake (funder or treasury)
     * @param amount The slashed amount
     */
    event StakeSlashed(uint256 indexed bountyId, address indexed worker, address indexed to, uint256 amount);

    // --- View Functions ---

    /**
     * @notice The escrow contract holding all reward and stake funds
     * @return escrow The escrow address
     */
    function escrow() external view returns (address escrow);

    /**
     * @notice The reputation contract this market writes worker outcomes to
     * @return reputation The reputation address
     */
    function reputation() external view returns (address reputation);

    /**
     * @notice The address that receives slashed stakes when no funder route applies
     * @dev If zero, slashed stakes route to the bounty's funder.
     * @return treasury The treasury address (may be zero)
     */
    function treasury() external view returns (address treasury);

    /**
     * @notice The total number of bounties proposed (next id equals this value)
     * @return count The bounty count
     */
    function bountyCount() external view returns (uint256 count);

    /**
     * @notice Returns the full record of a bounty
     * @param bountyId The bounty id
     * @return bounty The bounty struct
     */
    function bounties(uint256 bountyId) external view returns (Bounty memory bounty);

    /**
     * @notice Returns the current lifecycle state of a bounty
     * @param bountyId The bounty id
     * @return state The state
     */
    function stateOf(uint256 bountyId) external view returns (State state);

    // --- State-Changing Functions ---

    /**
     * @notice Proposes a new bounty (permissionless)
     * @dev The reward is NOT escrowed yet; call fund() to escrow it. The caller
     * becomes the funder. If `arbiter_` is zero, the approver also arbitrates.
     * @param token_ Reward/stake asset; address(0) for native coin
     * @param reward_ The reward amount (escrowed on fund)
     * @param stake_ The stake a worker must post to claim
     * @param approver_ The address that may accept submissions (EOA or Safe)
     * @param arbiter_ The address that may resolve disputes (zero => approver)
     * @param claimWindow_ Seconds a worker has to submit after claiming
     * @param issueRef_ A URI or content hash describing the work
     * @return bountyId The new bounty id
     */
    function propose(
        address token_,
        uint256 reward_,
        uint256 stake_,
        address approver_,
        address arbiter_,
        uint64 claimWindow_,
        string calldata issueRef_
    ) external returns (uint256 bountyId);

    /**
     * @notice Escrows the reward for a bounty, moving it Open -> Funded
     * @dev Anyone may fund (self-funded by the proposer, or a DAO treasury Safe).
     * For native rewards, msg.value must equal the reward. For ERC-20, the caller
     * must have approved the escrow for the reward amount.
     * @param bountyId The bounty to fund
     */
    function fund(uint256 bountyId) external payable;

    /**
     * @notice Claims a funded bounty by posting the stake, moving Funded -> Claimed
     * @dev PERMISSIONLESS — any address may claim. For native, msg.value must equal
     * the stake. For ERC-20, the caller must have approved the escrow for the stake.
     * Sets the submission deadline to now + claimWindow.
     * @param bountyId The bounty to claim
     */
    function claim(uint256 bountyId) external payable;

    /**
     * @notice Submits a deliverable, moving Claimed -> Submitted
     * @dev Worker-only, must be before the claim deadline.
     * @param bountyId The bounty
     * @param deliverableRef A URI or content hash of the deliverable
     */
    function submit(uint256 bountyId, string calldata deliverableRef) external;

    /**
     * @notice Accepts the submitted work and pays out atomically, Submitted -> Paid
     * @dev Approver-only. Releases the reward to the worker, returns the worker's
     * stake, and records the completion in the reputation ledger — all in one call.
     * @param bountyId The bounty
     */
    function accept(uint256 bountyId) external;

    /**
     * @notice Raises a dispute over a submission, Submitted -> Disputed
     * @dev Funder or approver only.
     * @param bountyId The bounty
     * @param reasonRef A URI or content hash of the dispute reason
     */
    function dispute(uint256 bountyId, string calldata reasonRef) external;

    /**
     * @notice Resolves a dispute by splitting the reward and deciding the stake
     * @dev Arbiter-only. `workerAmount + funderAmount` must equal the escrowed
     * reward; either may be zero. If `workerKeepsStake` is true the stake is
     * returned to the worker, otherwise it is slashed. A nonzero worker payout
     * records a completion; otherwise a dispute loss is recorded. Terminal: Paid.
     * @param bountyId The bounty
     * @param workerAmount Reward portion to the worker
     * @param funderAmount Reward portion refunded to the funder
     * @param workerKeepsStake Whether to return (true) or slash (false) the stake
     */
    function resolveDispute(
        uint256 bountyId,
        uint256 workerAmount,
        uint256 funderAmount,
        bool workerKeepsStake
    ) external;

    /**
     * @notice Cancels a bounty before it is claimed and refunds the reward
     * @dev Funder-only. Allowed from Open (nothing escrowed) or Funded (refunds the
     * reward to the funder). Terminal: Cancelled.
     * @param bountyId The bounty
     */
    function cancel(uint256 bountyId) external;

    /**
     * @notice Reclaims a stuck bounty whose worker missed the submit deadline
     * @dev PERMISSIONLESS — anyone may call after the claim deadline. Slashes the
     * worker's stake to the funder (or treasury) and returns the bounty to Funded
     * so a new worker can claim it. The reward stays escrowed.
     * @param bountyId The bounty
     */
    function reclaim(uint256 bountyId) external;
}
