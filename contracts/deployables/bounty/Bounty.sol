// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IBounty} from "../../interfaces/dao/deployables/IBounty.sol";
import {IEscrow} from "../../interfaces/dao/deployables/IEscrow.sol";
import {IReputation} from "../../interfaces/dao/deployables/IReputation.sol";
import {IVersion} from "../../interfaces/dao/deployables/IVersion.sol";
import {IDeploymentBlock} from "../../interfaces/dao/IDeploymentBlock.sol";
import {DeploymentBlockInitializable} from "../../DeploymentBlockInitializable.sol";
import {InitializerEventEmitter} from "../../InitializerEventEmitter.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

/**
 * @title Bounty
 * @author Lux Industries Inc
 * @notice Permissionless two-sided work-market with native / ERC-20 / ERC-721 / ERC-1155
 * rewards and a bridge to global Karma reputation
 * @dev The single canonical policy/state-machine of the work-market. A bounty's reward may
 * be native coin, an ERC-20, an ERC-721 (a single indivisible token) or an ERC-1155 (a
 * quantity); the worker's stake is always fungible (native or ERC-20), so the anti-grief
 * stake mechanism — returned on success, slashed on abandonment — is uniform across reward
 * kinds. On the completion path an accepted bounty also bridges a flat award into the
 * global, cross-DAO Karma reputation (best-effort, once per bounty — see Reputation).
 *
 * It is the sole controller of an Escrow (custody) and the sole writer of a Reputation
 * (history). Three contracts, three concerns, orthogonal: Bounty decides WHEN assets move
 * and WHO is authorized; Escrow guarantees value conservation and reentrancy-safety;
 * Reputation records outcomes and bridges Karma.
 *
 * EIP-7201 namespaced ("DAO.Bounty.main") and deployed as a UUPS proxy with its Escrow /
 * Reputation pair.
 *
 * Lifecycle (illegal transitions revert):
 *   Open -> Funded -> Claimed -> Submitted -> Accepted/Paid
 *                 \-> Cancelled          |   \-> Disputed -> resolve (Paid)
 *                                        \-> finalize (review window elapsed) -> Paid
 *
 * Dispute divisibility: a fungible reward is split (workerAmount + funderAmount == reward);
 * an NFT reward is indivisible and awarded WHOLE to one party (workerAmount is 0 or the full
 * reward). The stake decision is orthogonal.
 *
 * Implementation: EIP-7201 namespaced storage + UUPS; all value lives in
 * Escrow keyed per bounty (reward under _rewardKey, stake under _stakeKey per attempt);
 * nonReentrant on every state-changing entrypoint; state is committed before any external
 * call (checks-effects-interactions), so payouts are atomic and the ERC-721/1155 transfer
 * callbacks cannot re-enter a non-terminal bounty.
 *
 * @custom:security-contact security@lux.network
 */
contract Bounty is
    IBounty,
    IVersion,
    DeploymentBlockInitializable,
    InitializerEventEmitter,
    Ownable2StepUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardTransient,
    ERC165
{
    // ======================================================================
    // STATE VARIABLES
    // ======================================================================

    /**
     * @notice Main storage struct for Bounty following EIP-7201
     * @dev Contains the escrow/reputation wiring and the bounty ledger
     * @custom:storage-location erc7201:DAO.Bounty.main
     */
    struct BountyStorage {
        /** @notice The escrow custodying all reward and stake assets */
        IEscrow escrow;
        /** @notice The reputation ledger this market writes outcomes to */
        IReputation reputation;
        /** @notice Where slashed stakes go when no funder route applies (0 => funder) */
        address treasury;
        /** @notice Total number of bounties proposed (also the next id) */
        uint256 bountyCount;
        /** @notice Mapping from bounty id to its record */
        mapping(uint256 bountyId => Bounty bounty) bounties;
    }

    /**
     * @dev Storage slot for BountyStorage calculated using EIP-7201 formula:
     * keccak256(abi.encode(uint256(keccak256("DAO.Bounty.main")) - 1)) & ~bytes32(uint256(0xff))
     */
    bytes32 internal constant BOUNTY_STORAGE_LOCATION =
        0xe9ca8f3ef60272e1cc45846d8d69cc936b7bc80b9d605ea0f76faf7b65936300;

    /**
     * @notice Upper bound on the claim and review windows. Without it an untrusted funder
     * could set a near-uint64.max window that overflows submit()'s checked
     * `block.timestamp + reviewWindow` arithmetic, bricking a staked worker's delivery.
     * 365 days exceeds any legitimate bounty window.
     */
    uint64 internal constant MAX_WINDOW = 365 days;

    /**
     * @notice Lower bound on the claim and review windows (M2). A near-zero claimWindow would let a
     * funder slash a worker's stake (via reclaim) before the worker could realistically submit; a
     * near-zero reviewWindow would deny the approver any review before finalize pays out. 1 hour is
     * the floor that keeps both parties a real minimum to act.
     */
    uint64 internal constant MIN_WINDOW = 1 hours;

    /**
     * @notice Grace period after settlement before a funder may recover a reward the worker could
     * not receive (H1). Gives a credited worker ample time to fix their address and withdraw()
     * before the funder may reclaim the un-withdrawn reward credit.
     */
    uint64 internal constant RECOVERY_GRACE = 30 days;

    /**
     * @dev Returns the storage struct for Bounty
     * @return $ The storage struct for Bounty
     */
    function _getBountyStorage() internal pure returns (BountyStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := BOUNTY_STORAGE_LOCATION
        }
    }

    // ======================================================================
    // CONSTRUCTOR & INITIALIZERS
    // ======================================================================

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the work market
     * @dev The escrow's controller and the reputation's writer must both be this contract's
     * (proxy) address; that wiring is performed at deployment, outside this call.
     * @param owner_ The upgrade authority
     * @param escrow_ The Escrow instance controlled by this market
     * @param reputation_ The Reputation instance written by this market
     * @param treasury_ Recipient of slashed stakes when no funder route applies (may be zero)
     */
    function initialize(
        address owner_,
        address escrow_,
        address reputation_,
        address treasury_
    ) public virtual initializer {
        __InitializerEventEmitter_init(abi.encode(owner_, escrow_, reputation_, treasury_));
        __Ownable_init(owner_);
        __DeploymentBlockInitializable_init();

        BountyStorage storage $ = _getBountyStorage();
        $.escrow = IEscrow(escrow_);
        $.reputation = IReputation(reputation_);
        $.treasury = treasury_;
    }

    /**
     * @notice Zodiac/module-style initializer for proxy-factory deployment
     * @param initializeParams_ ABI-encoded (owner, escrow, reputation, treasury)
     */
    function setUp(bytes memory initializeParams_) public virtual initializer {
        (address owner_, address escrow_, address reputation_, address treasury_) = abi.decode(
            initializeParams_,
            (address, address, address, address)
        );

        __InitializerEventEmitter_init(initializeParams_);
        __Ownable_init(owner_);
        __DeploymentBlockInitializable_init();

        BountyStorage storage $ = _getBountyStorage();
        $.escrow = IEscrow(escrow_);
        $.reputation = IReputation(reputation_);
        $.treasury = treasury_;
    }

    // ======================================================================
    // UUPSUpgradeable
    // ======================================================================

    /**
     * @inheritdoc UUPSUpgradeable
     * @dev Restricted to the owner.
     */
    function _authorizeUpgrade(address newImplementation_) internal virtual override onlyOwner {
        // solhint-disable-previous-line no-empty-blocks
        // Authorization handled by onlyOwner.
    }

    // ======================================================================
    // IBounty — View Functions
    // ======================================================================

    /**
     * @inheritdoc IBounty
     */
    function escrow() public view virtual override returns (address) {
        return address(_getBountyStorage().escrow);
    }

    /**
     * @inheritdoc IBounty
     */
    function reputation() public view virtual override returns (address) {
        return address(_getBountyStorage().reputation);
    }

    /**
     * @inheritdoc IBounty
     */
    function treasury() public view virtual override returns (address) {
        return _getBountyStorage().treasury;
    }

    /**
     * @inheritdoc IBounty
     */
    function bountyCount() public view virtual override returns (uint256) {
        return _getBountyStorage().bountyCount;
    }

    /**
     * @inheritdoc IBounty
     */
    function bounties(uint256 bountyId_) public view virtual override returns (Bounty memory) {
        return _getBountyStorage().bounties[bountyId_];
    }

    /**
     * @inheritdoc IBounty
     */
    function stateOf(uint256 bountyId_) public view virtual override returns (State) {
        return _getBountyStorage().bounties[bountyId_].state;
    }

    // ======================================================================
    // IBounty — Lifecycle
    // ======================================================================

    /**
     * @inheritdoc IBounty
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
    ) public virtual override returns (uint256 bountyId) {
        _validateReward(reward_);
        if (stake_ == 0) revert ZeroAmount();
        if (approver_ == address(0)) revert InvalidApprover();

        // Anti-self-dealing: the funder must not be the party that accepts or arbitrates its
        // own bounty, else a funder=approver=arbiter could dispute its own bounty and resolve
        // workerAmount=0 + slash the stake to itself, robbing a delivered worker.
        if (approver_ == msg.sender) revert ApproverIsFunder();
        address effectiveArbiter = arbiter_ == address(0) ? approver_ : arbiter_;
        if (effectiveArbiter == msg.sender) revert ArbiterIsFunder();

        // Bound both windows: MAX so submit()'s checked deadline arithmetic cannot overflow, MIN so
        // a funder cannot set a near-zero window to slash a worker's stake before they can submit.
        if (claimWindow_ > MAX_WINDOW) revert WindowTooLong(claimWindow_, MAX_WINDOW);
        if (reviewWindow_ > MAX_WINDOW) revert WindowTooLong(reviewWindow_, MAX_WINDOW);
        if (claimWindow_ < MIN_WINDOW) revert WindowTooShort(claimWindow_, MIN_WINDOW);
        if (reviewWindow_ < MIN_WINDOW) revert WindowTooShort(reviewWindow_, MIN_WINDOW);

        BountyStorage storage $ = _getBountyStorage();
        bountyId = $.bountyCount;
        unchecked {
            $.bountyCount = bountyId + 1;
        }

        Bounty storage b = $.bounties[bountyId];
        b.state = State.Open;
        b.rewardKind = reward_.kind;
        b.rewardToken = reward_.token;
        b.rewardTokenId = reward_.tokenId;
        b.reward = reward_.amount;
        b.stakeToken = stakeToken_;
        b.stake = stake_;
        b.funder = msg.sender;
        b.approver = approver_;
        b.arbiter = effectiveArbiter;
        b.claimWindow = claimWindow_;
        b.reviewWindow = reviewWindow_;

        emit BountyProposed(
            bountyId,
            msg.sender,
            approver_,
            reward_.kind,
            reward_.token,
            reward_.tokenId,
            reward_.amount,
            stakeToken_,
            stake_,
            issueRef_
        );
    }

    /**
     * @inheritdoc IBounty
     * @dev Open -> Funded. Anyone may fund. The reward is escrowed under the bounty's reward
     * key, refundable to the bounty's funder.
     */
    function fund(uint256 bountyId_) public payable virtual override nonReentrant {
        BountyStorage storage $ = _getBountyStorage();
        Bounty storage b = _bounty($, bountyId_);
        _requireState(bountyId_, b.state, State.Open);

        // Effects.
        b.state = State.Funded;

        // Interaction: move the reward into escrow, refundable to the funder.
        _escrowReward($, b, bountyId_);

        emit BountyFunded(bountyId_, b.funder, b.reward);
    }

    /**
     * @inheritdoc IBounty
     * @dev Funded -> Claimed. PERMISSIONLESS. The caller stakes (fungible); the stake is escrowed
     * under the bounty's stake key, refundable to the worker. Informed consent (H2): the worker must
     * acknowledge the bounty's arbiter, so they never stake blind to who arbitrates a dispute.
     */
    function claim(uint256 bountyId_, address acknowledgedArbiter_) public payable virtual override nonReentrant {
        BountyStorage storage $ = _getBountyStorage();
        Bounty storage b = _bounty($, bountyId_);
        _requireState(bountyId_, b.state, State.Funded);
        if (acknowledgedArbiter_ != b.arbiter) revert ArbiterMismatch(bountyId_, acknowledgedArbiter_, b.arbiter);

        // Effects.
        uint64 deadline = uint64(block.timestamp) + b.claimWindow;
        b.state = State.Claimed;
        b.worker = msg.sender;
        b.claimDeadline = deadline;

        // Interaction: move the stake into escrow under this attempt's key, refundable to
        // the worker. Keying by claimNonce isolates each attempt's stake.
        _escrowStake($, b, bountyId_, msg.sender);

        emit BountyClaimed(bountyId_, msg.sender, b.stake, deadline);
    }

    /**
     * @inheritdoc IBounty
     * @dev Claimed -> Submitted. Worker-only, before the deadline.
     */
    function submit(uint256 bountyId_, string calldata deliverableRef_) public virtual override {
        BountyStorage storage $ = _getBountyStorage();
        Bounty storage b = _bounty($, bountyId_);
        _requireState(bountyId_, b.state, State.Claimed);
        if (msg.sender != b.worker) revert OnlyWorker();
        if (block.timestamp > b.claimDeadline) revert DeadlinePassed(bountyId_, b.claimDeadline);

        // Effects: enter review and start the review window.
        b.state = State.Submitted;
        b.reviewDeadline = uint64(block.timestamp) + b.reviewWindow;

        emit WorkSubmitted(bountyId_, msg.sender, deliverableRef_);
    }

    /**
     * @inheritdoc IBounty
     * @dev Submitted -> Paid. Approver-only. Atomic payout: reward to worker, stake returned,
     * completion recorded + Karma bridged — all before the call returns.
     */
    function accept(uint256 bountyId_) public virtual override nonReentrant {
        BountyStorage storage $ = _getBountyStorage();
        Bounty storage b = _bounty($, bountyId_);
        _requireState(bountyId_, b.state, State.Submitted);
        if (msg.sender != b.approver) revert OnlyApprover();

        // Effects before interactions (CEI); the shared settlement pays the worker.
        b.state = State.Paid;
        address worker = b.worker;
        _releaseToWorker($, b, bountyId_);

        emit WorkAccepted(bountyId_, msg.sender, worker);
    }

    /**
     * @inheritdoc IBounty
     * @dev Submitted -> Paid. PERMISSIONLESS after the review deadline (the liveness escape:
     * approver silence past the window counts as acceptance).
     */
    function finalize(uint256 bountyId_) public virtual override nonReentrant {
        BountyStorage storage $ = _getBountyStorage();
        Bounty storage b = _bounty($, bountyId_);
        _requireState(bountyId_, b.state, State.Submitted);
        if (block.timestamp <= b.reviewDeadline) {
            revert ReviewWindowNotElapsed(bountyId_, b.reviewDeadline);
        }

        // Effects before interactions (CEI); the shared settlement pays the worker.
        b.state = State.Paid;
        address worker = b.worker;
        _releaseToWorker($, b, bountyId_);

        emit BountyFinalized(bountyId_, msg.sender, worker);
    }

    /**
     * @inheritdoc IBounty
     * @dev Submitted -> Disputed. Funder or approver only, before the review window elapses.
     */
    function dispute(uint256 bountyId_, string calldata reasonRef_) public virtual override {
        BountyStorage storage $ = _getBountyStorage();
        Bounty storage b = _bounty($, bountyId_);
        _requireState(bountyId_, b.state, State.Submitted);
        if (msg.sender != b.funder && msg.sender != b.approver) revert OnlyApprover();
        if (block.timestamp > b.reviewDeadline) revert ReviewWindowElapsed(bountyId_, b.reviewDeadline);

        b.state = State.Disputed;

        emit BountyDisputed(bountyId_, msg.sender, reasonRef_);
    }

    /**
     * @inheritdoc IBounty
     * @dev Disputed -> Paid. Arbiter-only. Awards the reward (fungible split, or the whole
     * indivisible NFT to one party). The worker's STAKE is ALWAYS returned (H2 anti-robbery floor):
     * a delivered worker cannot have their staked capital confiscated by dispute — the arbiter rules
     * only on the reward. Stake slashing is exclusive to the abandonment path (reclaim).
     */
    function resolveDispute(
        uint256 bountyId_,
        uint256 workerAmount_,
        uint256 funderAmount_
    ) public virtual override nonReentrant {
        BountyStorage storage $ = _getBountyStorage();
        Bounty storage b = _bounty($, bountyId_);
        _requireState(bountyId_, b.state, State.Disputed);
        if (msg.sender != b.arbiter) revert OnlyArbiter();

        uint256 reward = b.reward;
        if (workerAmount_ + funderAmount_ != reward) {
            revert SplitMismatch(bountyId_, reward, workerAmount_ + funderAmount_);
        }
        // An NFT reward is indivisible: it goes WHOLE to one party.
        if (_isNftReward(b.rewardKind) && workerAmount_ != 0 && workerAmount_ != reward) {
            revert NftRewardIndivisible(bountyId_, reward, workerAmount_);
        }

        // Effects.
        b.state = State.Paid;
        b.settledAt = uint64(block.timestamp);
        address worker = b.worker;
        address funder = b.funder;

        // Interactions: distribute the reward per the award. A failed worker payout is credited by
        // the escrow (never reverts); track it so the funder can recover it post-grace (H1).
        if (workerAmount_ > 0) {
            bool delivered = $.escrow.release(_rewardKey(bountyId_), worker, workerAmount_);
            if (!delivered) b.rewardCreditedAmount = workerAmount_;
        }
        if (funderAmount_ > 0) {
            $.escrow.refund(_rewardKey(bountyId_), funder, funderAmount_);
        }

        // The stake is ALWAYS returned to the (delivered) worker — never slashed by dispute.
        $.escrow.release(_stakeKey(bountyId_, b.claimNonce), worker, b.stake);

        // Record the outcome. A completion (and Karma bridge) is credited only when the worker got a
        // nonzero payout and is not also the approver (self-review earns nothing).
        if (workerAmount_ > 0) {
            if (worker != b.approver) {
                $.reputation.recordCompletion(worker, workerAmount_, _source(bountyId_));
            }
        } else {
            $.reputation.recordDisputeLoss(worker);
        }

        emit DisputeResolved(bountyId_, msg.sender, workerAmount_, funderAmount_);
    }

    /**
     * @inheritdoc IBounty
     * @dev Paid -> (reward credit reassigned). Funder-only, post-grace, only if the worker's reward
     * payout failed and was credited. Reassigns the worker's un-withdrawn reward credit to the funder
     * so a reward the worker cannot receive never locks forever (H1).
     */
    function recoverReward(uint256 bountyId_) public virtual override nonReentrant {
        BountyStorage storage $ = _getBountyStorage();
        Bounty storage b = _bounty($, bountyId_);
        _requireState(bountyId_, b.state, State.Paid);
        if (msg.sender != b.funder) revert OnlyFunder();
        uint256 amount = b.rewardCreditedAmount;
        if (amount == 0) revert RewardNotCredited(bountyId_);
        uint64 recoverableAt = b.settledAt + RECOVERY_GRACE;
        if (block.timestamp <= recoverableAt) revert RecoveryNotReady(bountyId_, recoverableAt);

        // Effects: consume the recoverable amount up front (no second recovery of this reward).
        b.rewardCreditedAmount = 0;

        // Interaction: move EXACTLY this bounty's credited reward from the worker to the funder —
        // never the whole aggregated credit, so the worker's stake credit (and any other funder's
        // reward credited under the same asset key) is untouched.
        $.escrow.reassignCredit(b.worker, b.funder, b.rewardKind, b.rewardToken, b.rewardTokenId, amount);
        emit RewardRecovered(bountyId_, b.funder, b.worker, amount);
    }

    /**
     * @inheritdoc IBounty
     * @dev Open/Funded -> Cancelled. Funder-only. Refunds the escrowed reward (if any).
     */
    function cancel(uint256 bountyId_) public virtual override nonReentrant {
        BountyStorage storage $ = _getBountyStorage();
        Bounty storage b = _bounty($, bountyId_);
        if (msg.sender != b.funder) revert OnlyFunder();

        State current = b.state;
        if (current != State.Open && current != State.Funded) {
            revert InvalidState(bountyId_, current, State.Funded);
        }

        // Effects.
        bool wasFunded = current == State.Funded;
        b.state = State.Cancelled;

        // Interaction: refund the whole reward if it was escrowed.
        if (wasFunded) {
            $.escrow.refund(_rewardKey(bountyId_), b.funder, b.reward);
        }

        emit BountyCancelled(bountyId_, b.funder, wasFunded ? b.reward : 0);
    }

    /**
     * @inheritdoc IBounty
     * @dev Claimed -> Funded. PERMISSIONLESS after the deadline. Slashes the stuck stake to
     * the funder (or treasury) and re-opens the bounty. The reward stays escrowed.
     */
    function reclaim(uint256 bountyId_) public virtual override nonReentrant {
        BountyStorage storage $ = _getBountyStorage();
        Bounty storage b = _bounty($, bountyId_);
        _requireState(bountyId_, b.state, State.Claimed);
        if (block.timestamp <= b.claimDeadline) revert DeadlineNotPassed(bountyId_, b.claimDeadline);

        // Effects: re-open for a new claimer; clear worker-specific fields. Bump the claim
        // nonce so the next claim escrows its stake under a fresh key.
        address worker = b.worker;
        uint256 stake = b.stake;
        uint64 nonce = b.claimNonce;
        b.state = State.Funded;
        b.worker = address(0);
        b.claimDeadline = 0;
        unchecked {
            b.claimNonce = nonce + 1;
        }

        // Interaction: slash the stuck stake from the attempt being reclaimed.
        address to = _slashTarget($, b.funder);
        $.escrow.refund(_stakeKey(bountyId_, nonce), to, stake);

        emit StakeSlashed(bountyId_, worker, to, stake);
    }

    // ======================================================================
    // IVersion
    // ======================================================================

    /**
     * @inheritdoc IVersion
     */
    function version() public pure virtual override returns (uint16) {
        return 1;
    }

    // ======================================================================
    // ERC165
    // ======================================================================

    /**
     * @inheritdoc ERC165
     * @dev Supports IBounty, IVersion, IDeploymentBlock, and IERC165.
     */
    function supportsInterface(bytes4 interfaceId_) public view virtual override returns (bool) {
        return
            interfaceId_ == type(IBounty).interfaceId ||
            interfaceId_ == type(IVersion).interfaceId ||
            interfaceId_ == type(IDeploymentBlock).interfaceId ||
            super.supportsInterface(interfaceId_);
    }

    // ======================================================================
    // INTERNAL HELPERS
    // ======================================================================

    /**
     * @dev Loads a bounty, reverting if it does not exist.
     */
    function _bounty(BountyStorage storage $, uint256 bountyId_) internal view returns (Bounty storage b) {
        b = $.bounties[bountyId_];
        if (b.state == State.None) revert UnknownBounty(bountyId_);
    }

    /**
     * @dev Enforces that a bounty is in the required state.
     */
    function _requireState(uint256 bountyId_, State current_, State required_) internal pure {
        if (current_ != required_) revert InvalidState(bountyId_, current_, required_);
    }

    /**
     * @dev Validates a reward spec against its asset kind. Native: no token, no id. ERC-20:
     * token, no id. ERC-721: token, amount must be exactly 1 (indivisible). ERC-1155: token,
     * any amount >= 1. Amount is always required (nonzero).
     */
    function _validateReward(RewardSpec calldata reward_) internal pure {
        if (reward_.amount == 0) revert ZeroAmount();
        IEscrow.AssetKind kind = reward_.kind;
        if (kind == IEscrow.AssetKind.Native) {
            if (reward_.token != address(0) || reward_.tokenId != 0) revert RewardAssetInvalid();
        } else if (kind == IEscrow.AssetKind.ERC20) {
            if (reward_.token == address(0) || reward_.tokenId != 0) revert RewardAssetInvalid();
        } else if (kind == IEscrow.AssetKind.ERC721) {
            if (reward_.token == address(0) || reward_.amount != 1) revert RewardAssetInvalid();
        } else {
            // ERC-1155
            if (reward_.token == address(0)) revert RewardAssetInvalid();
        }
    }

    /**
     * @dev Settles a delivered bounty to its worker: releases the whole reward, returns the stake,
     * and records a completion (which best-effort bridges Karma) UNLESS the worker is also the
     * approver (self-review earns nothing). Both accept() and finalize() set state to Paid BEFORE
     * calling this (checks-effects-interactions), so the external calls here cannot re-enter a
     * non-terminal bounty. NEITHER an untransferable reward/stake recipient (the escrow CREDITS on
     * failure instead of reverting — H1) NOR a Karma failure (Reputation wraps the bridge in
     * try/catch) can revert this settlement — a delivered worker is always moved to Paid. If the
     * reward payout was credited (not delivered), it is tracked for post-grace funder-recovery.
     */
    function _releaseToWorker(BountyStorage storage $, Bounty storage b, uint256 bountyId_) internal {
        address worker = b.worker;
        uint256 reward = b.reward;
        uint256 stake = b.stake;

        b.settledAt = uint64(block.timestamp);
        bool rewardDelivered = $.escrow.release(_rewardKey(bountyId_), worker, reward);
        if (!rewardDelivered) b.rewardCreditedAmount = reward;
        // Stake return: a failed transfer is credited to the worker by the escrow (never reverts).
        $.escrow.release(_stakeKey(bountyId_, b.claimNonce), worker, stake);
        if (worker != b.approver) {
            $.reputation.recordCompletion(worker, reward, _source(bountyId_));
        }

        emit PaymentReleased(bountyId_, worker, reward, stake);
    }

    /**
     * @dev Moves a bounty's reward into escrow under its reward key. Native: msg.value must
     * equal the reward and is forwarded; ERC-20/721/1155: no native value, and the escrow
     * pulls from the funder (who must have approved the escrow). Refund target is the funder.
     */
    function _escrowReward(BountyStorage storage $, Bounty storage b, uint256 bountyId_) internal {
        bytes32 key = _rewardKey(bountyId_);
        if (b.rewardKind == IEscrow.AssetKind.Native) {
            if (msg.value != b.reward) revert ValueMismatch(b.reward, msg.value);
            $.escrow.deposit{value: b.reward}(key, IEscrow.AssetKind.Native, address(0), b.funder, 0, b.reward);
        } else {
            if (msg.value != 0) revert UnexpectedNativeValue();
            $.escrow.deposit(key, b.rewardKind, b.rewardToken, b.funder, b.rewardTokenId, b.reward);
        }
    }

    /**
     * @dev Moves a worker's (fungible) stake into escrow under this attempt's stake key.
     * Native: msg.value must equal the stake and is forwarded; ERC-20: no native value, and
     * the escrow pulls from the worker (who must have approved the escrow).
     */
    function _escrowStake(
        BountyStorage storage $,
        Bounty storage b,
        uint256 bountyId_,
        address worker_
    ) internal {
        bytes32 key = _stakeKey(bountyId_, b.claimNonce);
        if (b.stakeToken == address(0)) {
            if (msg.value != b.stake) revert ValueMismatch(b.stake, msg.value);
            $.escrow.deposit{value: b.stake}(key, IEscrow.AssetKind.Native, address(0), worker_, 0, b.stake);
        } else {
            if (msg.value != 0) revert UnexpectedNativeValue();
            $.escrow.deposit(key, IEscrow.AssetKind.ERC20, b.stakeToken, worker_, 0, b.stake);
        }
    }

    /**
     * @dev Whether a reward asset kind is a (indivisible) NFT.
     */
    function _isNftReward(IEscrow.AssetKind kind_) internal pure returns (bool) {
        return kind_ == IEscrow.AssetKind.ERC721 || kind_ == IEscrow.AssetKind.ERC1155;
    }

    /**
     * @dev Resolves where a slashed stake is sent: the configured treasury if set, otherwise
     * the bounty's funder.
     */
    function _slashTarget(BountyStorage storage $, address funder_) internal view returns (address) {
        address t = $.treasury;
        return t == address(0) ? funder_ : t;
    }

    /**
     * @dev Deterministic escrow key for a bounty's reward deposit.
     */
    function _rewardKey(uint256 bountyId_) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("reward", bountyId_));
    }

    /**
     * @dev Deterministic escrow key for a bounty's stake deposit on a given claim attempt.
     */
    function _stakeKey(uint256 bountyId_, uint64 claimNonce_) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("stake", bountyId_, claimNonce_));
    }

    /**
     * @dev The once-only Karma source tag / reason for a completion: encodes the chain, this
     * market's address, and the bounty id, so it is globally unique and cannot collide across
     * markets or chains.
     */
    function _source(uint256 bountyId_) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), bountyId_));
    }
}
