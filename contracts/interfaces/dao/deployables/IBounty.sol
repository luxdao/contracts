// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IEscrow} from "./IEscrow.sol";

/**
 * @title IBounty
 * @notice Permissionless two-sided work-market with native / ERC-20 / ERC-721 / ERC-1155
 * rewards and a bridge to global Karma reputation
 * @dev Bounty is the single canonical policy/state-machine of the work-market
 * (propose -> fund -> claim -> submit -> accept/finalize/dispute -> Paid), with two
 * first-class capabilities:
 *
 *  1. Any reward asset. A bounty's reward may be native coin, an ERC-20, an ERC-721 (a
 *     single indivisible token) or an ERC-1155 (a quantity). The reward asset and the stake
 *     asset are DISTINCT: the reward may be an NFT while the worker's stake stays fungible
 *     (native or ERC-20), so the anti-grief stake mechanism (returned on success, slashed on
 *     abandonment) is uniform — an NFT reward cannot double as a slashable fungible stake.
 *
 *  2. Global Karma. On the completion path the worker's local completion ALSO bridges a
 *     flat award into the cross-DAO Karma token, once per bounty, best-effort (a Karma
 *     failure can never block the payout). See IReputation.
 *
 * Lifecycle (illegal transitions revert — a state invariant, not a discretionary gate):
 *   Open -> Funded -> Claimed -> Submitted -> Accepted/Paid
 *                 \-> Cancelled          |   \-> Disputed -> resolve (Paid)
 *                                        \-> finalize (review window elapsed) -> Paid
 *
 * Reward divisibility on dispute:
 *  - Fungible reward (native/ERC-20): the arbiter splits it (workerAmount + funderAmount ==
 *    reward; either may be zero).
 *  - NFT reward (ERC-721/ERC-1155): the NFT is INDIVISIBLE. The arbiter awards the WHOLE
 *    reward to one party — workerAmount must be 0 (funder keeps it) or the full reward
 *    amount (worker gets it); any strict-fractional split reverts NftRewardIndivisible. For
 *    ERC-1155 "whole" means the entire deposited quantity moves to one party. The stake
 *    decision (return vs slash) is orthogonal and unchanged.
 *
 * All value lives in Escrow, keyed per bounty (reward under _rewardKey, stake under
 * _stakeKey per claim attempt); state is committed before any escrow/reputation call
 * (checks-effects-interactions) and every entrypoint is nonReentrant, so the ERC-721/1155
 * safeTransfer callbacks cannot re-enter to double-pay.
 */
interface IBounty {
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
        Accepted, //  5: reserved (payout is atomic; state moves Submitted -> Paid)
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

    /** @notice Thrown when the funder tries to also be the approver of its own bounty */
    error ApproverIsFunder();

    /** @notice Thrown when the funder tries to also be the arbiter of its own bounty */
    error ArbiterIsFunder();

    /** @notice Thrown when the reward spec is inconsistent with its asset kind */
    error RewardAssetInvalid();

    /**
     * @notice Thrown when an arbiter tries to strict-fractionally split an NFT reward
     * @dev An ERC-721/1155 reward is indivisible on dispute: workerAmount must be 0 or the
     * full reward amount.
     */
    error NftRewardIndivisible(uint256 bountyId, uint256 reward, uint256 workerAmount);

    /** @notice Thrown when finalize is called before the submission's review window elapsed */
    error ReviewWindowNotElapsed(uint256 bountyId, uint64 reviewDeadline);

    /** @notice Thrown when a dispute is raised after the review window already elapsed */
    error ReviewWindowElapsed(uint256 bountyId, uint64 reviewDeadline);

    /** @notice Thrown when the claim deadline has not yet passed (for reclaim/slash) */
    error DeadlineNotPassed(uint256 bountyId, uint64 deadline);

    /** @notice Thrown when the claim deadline has already passed (for submit) */
    error DeadlinePassed(uint256 bountyId, uint64 deadline);

    /** @notice Thrown when native value is sent on a call that must not carry value */
    error UnexpectedNativeValue();

    /** @notice Thrown when a dispute resolution splits more/less than the escrowed reward */
    error SplitMismatch(uint256 bountyId, uint256 reward, uint256 requested);

    /** @notice Thrown when the native reward/stake msg.value does not match the configured amount */
    error ValueMismatch(uint256 expected, uint256 provided);

    /** @notice Thrown when a claim or review window exceeds MAX_WINDOW (submit-overflow guard) */
    error WindowTooLong(uint64 window, uint64 max);

    /** @notice Thrown when a claim or review window is below MIN_WINDOW (anti-stake-slash floor) */
    error WindowTooShort(uint64 window, uint64 min);

    /**
     * @notice Thrown when a worker's claim does not acknowledge the bounty's actual arbiter
     * @dev Informed consent (H2): the worker must pass the arbiter they see; a mismatch (e.g. the
     * arbiter changed, or the worker is unsure) reverts so they never stake blind to who arbitrates.
     */
    error ArbiterMismatch(uint256 bountyId, address acknowledged, address actual);

    /** @notice Thrown when funder-recovery is attempted before the reward's recovery grace elapsed */
    error RecoveryNotReady(uint256 bountyId, uint64 recoverableAt);

    /** @notice Thrown when funder-recovery is attempted on a reward that was delivered (not credited) */
    error RewardNotCredited(uint256 bountyId);

    // --- Structs ---

    /**
     * @notice The reward side of a bounty at proposal time (calldata ergonomics)
     * @param kind The reward asset class (native/erc20/erc721/erc1155)
     * @param token The reward asset contract; address(0) for native
     * @param tokenId The ERC-721/1155 id (0 for native/erc20)
     * @param amount The reward amount (erc721: must be 1; erc1155: quantity; else value)
     */
    struct RewardSpec {
        IEscrow.AssetKind kind;
        address token;
        uint256 tokenId;
        uint256 amount;
    }

    /**
     * @notice Full record of a bounty
     * @dev The reward asset (kind/token/tokenId/reward) and the stake asset (stakeToken/
     * stake) are stored distinctly; the stake is always fungible.
     * @param state Current lifecycle state
     * @param rewardKind The reward asset class
     * @param rewardToken The reward asset contract; address(0) for native
     * @param rewardTokenId The ERC-721/1155 reward id (0 for native/erc20)
     * @param reward The reward amount (erc721: 1; erc1155: quantity; else value)
     * @param stakeToken The stake asset; address(0) for native (fungible only)
     * @param stake The amount a worker must escrow to claim
     * @param funder Who funded the reward (refund target on cancel/dispute)
     * @param approver Who may accept the work (reviewer EOA or owning Safe)
     * @param arbiter Who may resolve a dispute (defaults to approver if unset)
     * @param worker The address that claimed the bounty (zero until claimed)
     * @param claimDeadline Timestamp by which the worker must submit (0 until claimed)
     * @param claimWindow Seconds granted to submit after claiming
     * @param claimNonce Number of times this bounty has been claimed (keys the stake escrow)
     * @param reviewWindow Seconds the approver has to accept/dispute after a submission
     * @param reviewDeadline Timestamp after which the submission may be finalized to the worker
     * @param rewardCreditedAmount The EXACT reward amount that failed to deliver to the worker and was
     *        credited in escrow (0 = delivered normally or already recovered). Recovery moves exactly
     *        this — never the whole aggregated credit — preserving the stake floor and cross-funder safety.
     * @param settledAt Timestamp the bounty reached Paid (starts the reward-recovery grace)
     */
    struct Bounty {
        State state;
        IEscrow.AssetKind rewardKind;
        address rewardToken;
        uint256 rewardTokenId;
        uint256 reward;
        address stakeToken;
        uint256 stake;
        address funder;
        address approver;
        address arbiter;
        address worker;
        uint64 claimDeadline;
        uint64 claimWindow;
        uint64 claimNonce;
        uint64 reviewWindow;
        uint64 reviewDeadline;
        uint256 rewardCreditedAmount;
        uint64 settledAt;
    }

    // --- Events ---

    /**
     * @notice Emitted when a bounty is proposed
     * @param bountyId The new bounty id
     * @param funder The proposer/funder
     * @param approver The address that will review submissions
     * @param rewardKind The reward asset class
     * @param rewardToken The reward asset (address(0) for native)
     * @param rewardTokenId The ERC-721/1155 reward id
     * @param reward The reward amount
     * @param stakeToken The stake asset (address(0) for native)
     * @param stake The required claim stake
     * @param issueRef A URI or content hash describing the work
     */
    event BountyProposed(
        uint256 indexed bountyId,
        address indexed funder,
        address indexed approver,
        IEscrow.AssetKind rewardKind,
        address rewardToken,
        uint256 rewardTokenId,
        uint256 reward,
        address stakeToken,
        uint256 stake,
        string issueRef
    );

    /**
     * @notice Emitted when a bounty's reward is escrowed
     * @param bountyId The bounty id
     * @param funder The address that funded the reward
     * @param reward The reward amount escrowed
     */
    event BountyFunded(uint256 indexed bountyId, address indexed funder, uint256 reward);

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
     * @dev The worker's STAKE is always returned on a dispute over a delivered submission (H2
     * anti-robbery floor) — the arbiter rules only on the reward split, never on the stake.
     * @param bountyId The bounty id
     * @param arbiter The resolving arbiter
     * @param workerAmount Reward portion awarded to the worker
     * @param funderAmount Reward portion returned to the funder
     */
    event DisputeResolved(
        uint256 indexed bountyId,
        address indexed arbiter,
        uint256 workerAmount,
        uint256 funderAmount
    );

    /**
     * @notice Emitted when a bounty is cancelled and the reward refunded
     * @param bountyId The bounty id
     * @param funder The refunded funder
     * @param reward The refunded reward amount (0 if never funded)
     */
    event BountyCancelled(uint256 indexed bountyId, address indexed funder, uint256 reward);

    /**
     * @notice Emitted when a worker's stake is slashed for abandonment/timeout
     * @param bountyId The bounty id
     * @param worker The slashed worker
     * @param to The recipient of the slashed stake (funder or treasury)
     * @param amount The slashed amount
     */
    event StakeSlashed(uint256 indexed bountyId, address indexed worker, address indexed to, uint256 amount);

    /**
     * @notice Emitted when a submission is auto-accepted after its review window elapsed
     * @param bountyId The bounty id
     * @param finalizer The permissionless caller that triggered finalization
     * @param worker The worker paid
     */
    event BountyFinalized(uint256 indexed bountyId, address indexed finalizer, address indexed worker);

    /**
     * @notice Emitted when the funder recovers a reward the worker could not receive (post-grace)
     * @param bountyId The bounty id
     * @param funder The funder recovering the reward
     * @param worker The worker whose un-withdrawn reward credit was reassigned
     * @param amount The reward amount reassigned to the funder
     */
    event RewardRecovered(uint256 indexed bountyId, address indexed funder, address indexed worker, uint256 amount);

    // --- View Functions ---

    /**
     * @notice The escrow contract holding all reward and stake assets
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
     * @return treasury The treasury address (may be zero => slashes route to the funder)
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
     * @dev The reward is NOT escrowed yet; call fund() to escrow it. The caller becomes the
     * funder. If `arbiter_` is zero, the approver also arbitrates. The funder may not be the
     * approver or the (effective) arbiter. The reward may be any asset class; the stake must
     * be native or ERC-20.
     * @param reward_ The reward spec (kind/token/tokenId/amount)
     * @param stakeToken_ The stake asset; address(0) for native (must be fungible)
     * @param stake_ The stake a worker must post to claim
     * @param approver_ The address that may accept submissions (EOA or Safe)
     * @param arbiter_ The address that may resolve disputes (zero => approver)
     * @param claimWindow_ Seconds a worker has to submit after claiming
     * @param reviewWindow_ Seconds the approver has to accept/dispute before finalize opens
     * @param issueRef_ A URI or content hash describing the work
     * @return bountyId The new bounty id
     */
    function propose(
        RewardSpec calldata reward_,
        address stakeToken_,
        uint256 stake_,
        address approver_,
        address arbiter_,
        uint64 claimWindow_,
        uint64 reviewWindow_,
        string calldata issueRef_
    ) external returns (uint256 bountyId);

    /**
     * @notice Escrows the reward for a bounty, moving it Open -> Funded
     * @dev Anyone may fund. Native reward: msg.value must equal the reward. ERC-20/721/1155
     * reward: the funder must have approved the escrow for the reward, and no native value
     * may be attached.
     * @param bountyId The bounty to fund
     */
    function fund(uint256 bountyId) external payable;

    /**
     * @notice Claims a funded bounty by posting the stake, moving Funded -> Claimed
     * @dev PERMISSIONLESS. Native stake: msg.value must equal the stake. ERC-20 stake: the caller
     * must have approved the escrow. Sets the submission deadline to now + claimWindow. INFORMED
     * CONSENT (H2): the worker must pass `acknowledgedArbiter == the bounty's arbiter`, so they
     * stake only after seeing (and can decline) who will arbitrate a dispute — the arbiter is fixed
     * at proposal and never changes, so this acknowledgement is binding.
     * @param bountyId The bounty to claim
     * @param acknowledgedArbiter The arbiter the worker acknowledges (must equal the bounty's arbiter)
     */
    function claim(uint256 bountyId, address acknowledgedArbiter) external payable;

    /**
     * @notice Submits a deliverable, moving Claimed -> Submitted
     * @dev Worker-only, before the claim deadline. Starts the review window.
     * @param bountyId The bounty
     * @param deliverableRef A URI or content hash of the deliverable
     */
    function submit(uint256 bountyId, string calldata deliverableRef) external;

    /**
     * @notice Accepts the submitted work and pays out atomically, Submitted -> Paid
     * @dev Approver-only. Releases the reward to the worker, returns the stake, records the
     * completion and bridges Karma — all in one call. No completion is recorded if the worker
     * is also the approver (self-review).
     * @param bountyId The bounty
     */
    function accept(uint256 bountyId) external;

    /**
     * @notice Finalizes a submission the approver never acted on, Submitted -> Paid
     * @dev PERMISSIONLESS once block.timestamp > reviewDeadline. Pays the worker, returns the
     * stake, records completion (unless worker == approver). The liveness escape.
     * @param bountyId The bounty
     */
    function finalize(uint256 bountyId) external;

    /**
     * @notice Raises a dispute over a submission, Submitted -> Disputed
     * @dev Funder or approver only, and only BEFORE the review window elapses.
     * @param bountyId The bounty
     * @param reasonRef A URI or content hash of the dispute reason
     */
    function dispute(uint256 bountyId, string calldata reasonRef) external;

    /**
     * @notice Resolves a dispute by awarding the reward; the worker's STAKE is always returned
     * @dev Arbiter-only. `workerAmount + funderAmount` must equal the escrowed reward. For a fungible
     * reward either may be any split; for an NFT reward workerAmount must be 0 or the full reward
     * (indivisible). A nonzero worker payout records a completion (and bridges Karma); otherwise a
     * dispute loss is recorded. ANTI-ROBBERY FLOOR (H2): once a worker has DELIVERED (Submitted),
     * their stake can NEVER be slashed by dispute — it is always returned here, so a funder cannot
     * (even via a Sybil arbiter) confiscate a delivering worker's staked capital. Stake slashing is
     * exclusive to the abandonment/timeout path (reclaim). Terminal: Paid.
     * @param bountyId The bounty
     * @param workerAmount Reward portion to the worker
     * @param funderAmount Reward portion returned to the funder
     */
    function resolveDispute(uint256 bountyId, uint256 workerAmount, uint256 funderAmount) external;

    /**
     * @notice Recovers a reward the worker provably could not receive, back to the funder (H1)
     * @dev Funder-only, on a Paid bounty whose worker reward payout FAILED and was credited in escrow
     * (rewardCredited), and only after RECOVERY_GRACE has elapsed since settlement — giving the worker
     * ample time to fix their address and withdraw(). Reassigns the worker's remaining reward credit
     * to the funder (who then withdraws from the escrow), so a reward can never lock forever.
     * @param bountyId The bounty
     */
    function recoverReward(uint256 bountyId) external;

    /**
     * @notice Cancels a bounty before it is claimed and refunds the reward
     * @dev Funder-only. Allowed from Open (nothing escrowed) or Funded (refunds the reward).
     * Terminal: Cancelled.
     * @param bountyId The bounty
     */
    function cancel(uint256 bountyId) external;

    /**
     * @notice Reclaims a stuck bounty whose worker missed the submit deadline
     * @dev PERMISSIONLESS after the claim deadline. Slashes the worker's stake to the funder
     * (or treasury) and returns the bounty to Funded so a new worker can claim it. The reward
     * stays escrowed.
     * @param bountyId The bounty
     */
    function reclaim(uint256 bountyId) external;
}
