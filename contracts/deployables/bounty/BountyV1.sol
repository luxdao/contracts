// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IBountyV1} from "../../interfaces/dao/deployables/IBountyV1.sol";
import {IEscrowV1} from "../../interfaces/dao/deployables/IEscrowV1.sol";
import {IReputationV1} from "../../interfaces/dao/deployables/IReputationV1.sol";
import {IVersion} from "../../interfaces/dao/deployables/IVersion.sol";
import {IDeploymentBlock} from "../../interfaces/dao/IDeploymentBlock.sol";
import {DeploymentBlockInitializable} from "../../DeploymentBlockInitializable.sol";
import {InitializerEventEmitter} from "../../InitializerEventEmitter.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

/**
 * @title BountyV1
 * @author Lux Industries Inc
 * @notice Permissionless two-sided work-market lifecycle on top of any DAO
 * @dev The policy/state-machine half of a "dework"-style work market. It is the
 * sole controller of an EscrowV1 (custody) and the sole writer of a ReputationV1
 * (history). Three contracts, three concerns, orthogonal (Rich Hickey): BountyV1
 * decides WHEN funds move and WHO is authorized; EscrowV1 guarantees value
 * conservation and reentrancy-safety; ReputationV1 records outcomes.
 *
 * Lifecycle (illegal transitions revert — a state invariant, not a discretionary gate):
 *   Open -> Funded -> Claimed -> Submitted -> Accepted/Paid
 *                 \-> Cancelled              \-> Disputed -> resolve (Paid)
 *
 * PERMISSIONLESS by design: anyone may propose a bounty and anyone may claim a
 * funded one. There is no allowlist. Abuse is bounded by MECHANISM:
 *  - A worker stakes to claim; the stake is returned on acceptance and slashed on
 *    abandonment/timeout, making claim-squatting and grief-claiming costly.
 *  - Each claim carries a deadline; anyone may `reclaim` a bounty whose worker
 *    missed it, slashing the stuck stake and re-opening the bounty.
 *
 * The approver (accepts work) and arbiter (resolves disputes) are configured per
 * bounty as plain addresses — a reviewer EOA for small bounties, or the owning
 * Safe/governance for large ones. Authorization is cryptographic (caller == the
 * configured address), so a post-quantum-signed Safe can be funder, approver, or
 * arbiter with no special-casing here.
 *
 * Implementation details:
 * - EIP-7201 namespaced storage and UUPS, deployable as master-copy + proxy.
 * - All value lives in EscrowV1, keyed per bounty: reward under _rewardKey, stake
 *   under _stakeKey, so reward and stake accounting never cross.
 * - nonReentrant on every state-changing entrypoint; state is committed before any
 *   external call (checks-effects-interactions), so payouts are atomic and safe.
 *
 * @custom:security-contact security@lux.network
 */
contract BountyV1 is
    IBountyV1,
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
     * @notice Main storage struct for BountyV1 following EIP-7201
     * @dev Contains the escrow/reputation wiring and the bounty ledger
     * @custom:storage-location erc7201:DAO.Bounty.main
     */
    struct BountyStorage {
        /** @notice The escrow custodying all reward and stake funds */
        IEscrowV1 escrow;
        /** @notice The reputation ledger this market writes outcomes to */
        IReputationV1 reputation;
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
     * @dev Returns the storage struct for BountyV1
     * Following the EIP-7201 namespaced storage pattern to avoid storage collisions
     * @return $ The storage struct for BountyV1
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
     * @dev The escrow's controller and the reputation's writer must both be this
     * contract's (proxy) address for the market to operate; that wiring is performed
     * at deployment, outside this call.
     * @param owner_ The upgrade authority
     * @param escrow_ The EscrowV1 instance controlled by this market
     * @param reputation_ The ReputationV1 instance written by this market
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
        $.escrow = IEscrowV1(escrow_);
        $.reputation = IReputationV1(reputation_);
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
        $.escrow = IEscrowV1(escrow_);
        $.reputation = IReputationV1(reputation_);
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
    // IBountyV1 — View Functions
    // ======================================================================

    /**
     * @inheritdoc IBountyV1
     */
    function escrow() public view virtual override returns (address) {
        return address(_getBountyStorage().escrow);
    }

    /**
     * @inheritdoc IBountyV1
     */
    function reputation() public view virtual override returns (address) {
        return address(_getBountyStorage().reputation);
    }

    /**
     * @inheritdoc IBountyV1
     */
    function treasury() public view virtual override returns (address) {
        return _getBountyStorage().treasury;
    }

    /**
     * @inheritdoc IBountyV1
     */
    function bountyCount() public view virtual override returns (uint256) {
        return _getBountyStorage().bountyCount;
    }

    /**
     * @inheritdoc IBountyV1
     */
    function bounties(uint256 bountyId_) public view virtual override returns (Bounty memory) {
        return _getBountyStorage().bounties[bountyId_];
    }

    /**
     * @inheritdoc IBountyV1
     */
    function stateOf(uint256 bountyId_) public view virtual override returns (State) {
        return _getBountyStorage().bounties[bountyId_].state;
    }

    // ======================================================================
    // IBountyV1 — Lifecycle
    // ======================================================================

    /**
     * @inheritdoc IBountyV1
     */
    function propose(
        address token_,
        uint256 reward_,
        uint256 stake_,
        address approver_,
        address arbiter_,
        uint64 claimWindow_,
        string calldata issueRef_
    ) public virtual override returns (uint256 bountyId) {
        if (reward_ == 0 || stake_ == 0) revert ZeroAmount();
        if (approver_ == address(0)) revert InvalidApprover();

        BountyStorage storage $ = _getBountyStorage();
        bountyId = $.bountyCount;
        unchecked {
            $.bountyCount = bountyId + 1;
        }

        Bounty storage b = $.bounties[bountyId];
        b.state = State.Open;
        b.token = token_;
        b.funder = msg.sender;
        b.approver = approver_;
        b.arbiter = arbiter_ == address(0) ? approver_ : arbiter_;
        b.reward = reward_;
        b.stake = stake_;
        b.claimWindow = claimWindow_;

        emit BountyProposed(bountyId, msg.sender, approver_, token_, reward_, stake_, issueRef_);
    }

    /**
     * @inheritdoc IBountyV1
     * @dev Open -> Funded. Anyone may fund (self or DAO treasury). The reward is
     * escrowed under the bounty's reward key, credited to the bounty's funder as the
     * refund target.
     */
    function fund(uint256 bountyId_) public payable virtual override nonReentrant {
        BountyStorage storage $ = _getBountyStorage();
        Bounty storage b = _bounty($, bountyId_);
        _requireState(bountyId_, b.state, State.Open);

        // Effects.
        b.state = State.Funded;

        // Interaction: move the reward into escrow, refundable to the funder.
        _escrowIn($, _rewardKey(bountyId_), b.token, b.funder, b.reward, msg.value);

        emit BountyFunded(bountyId_, b.funder, b.reward);
    }

    /**
     * @inheritdoc IBountyV1
     * @dev Funded -> Claimed. PERMISSIONLESS. The caller stakes; the stake is
     * escrowed under the bounty's stake key, refundable to the worker.
     */
    function claim(uint256 bountyId_) public payable virtual override nonReentrant {
        BountyStorage storage $ = _getBountyStorage();
        Bounty storage b = _bounty($, bountyId_);
        _requireState(bountyId_, b.state, State.Funded);

        // Effects.
        uint64 deadline = uint64(block.timestamp) + b.claimWindow;
        b.state = State.Claimed;
        b.worker = msg.sender;
        b.claimDeadline = deadline;

        // Interaction: move the stake into escrow under this attempt's key,
        // refundable to the worker. Keying by claimNonce means a stake escrowed in a
        // previous (slashed) attempt never collides with this one.
        _escrowIn($, _stakeKey(bountyId_, b.claimNonce), b.token, msg.sender, b.stake, msg.value);

        emit BountyClaimed(bountyId_, msg.sender, b.stake, deadline);
    }

    /**
     * @inheritdoc IBountyV1
     * @dev Claimed -> Submitted. Worker-only, before the deadline.
     */
    function submit(uint256 bountyId_, string calldata deliverableRef_) public virtual override {
        BountyStorage storage $ = _getBountyStorage();
        Bounty storage b = _bounty($, bountyId_);
        _requireState(bountyId_, b.state, State.Claimed);
        if (msg.sender != b.worker) revert OnlyWorker();
        if (block.timestamp > b.claimDeadline) revert DeadlinePassed(bountyId_, b.claimDeadline);

        b.state = State.Submitted;

        emit WorkSubmitted(bountyId_, msg.sender, deliverableRef_);
    }

    /**
     * @inheritdoc IBountyV1
     * @dev Submitted -> Paid. Approver-only. Atomic payout: reward to worker, stake
     * returned to worker, completion recorded — all before the call returns.
     */
    function accept(uint256 bountyId_) public virtual override nonReentrant {
        BountyStorage storage $ = _getBountyStorage();
        Bounty storage b = _bounty($, bountyId_);
        _requireState(bountyId_, b.state, State.Submitted);
        if (msg.sender != b.approver) revert OnlyApprover();

        // Effects.
        b.state = State.Paid;
        address worker = b.worker;
        uint256 reward = b.reward;
        uint256 stake = b.stake;

        // Interactions: pay reward, return stake, record completion.
        $.escrow.release(_rewardKey(bountyId_), worker, reward);
        $.escrow.release(_stakeKey(bountyId_, b.claimNonce), worker, stake);
        $.reputation.recordCompletion(worker, reward);

        emit WorkAccepted(bountyId_, msg.sender, worker);
        emit PaymentReleased(bountyId_, worker, reward, stake);
    }

    /**
     * @inheritdoc IBountyV1
     * @dev Submitted -> Disputed. Funder or approver only.
     */
    function dispute(uint256 bountyId_, string calldata reasonRef_) public virtual override {
        BountyStorage storage $ = _getBountyStorage();
        Bounty storage b = _bounty($, bountyId_);
        _requireState(bountyId_, b.state, State.Submitted);
        if (msg.sender != b.funder && msg.sender != b.approver) revert OnlyApprover();

        b.state = State.Disputed;

        emit BountyDisputed(bountyId_, msg.sender, reasonRef_);
    }

    /**
     * @inheritdoc IBountyV1
     * @dev Disputed -> Paid. Arbiter-only. Splits the reward (workerAmount +
     * funderAmount == reward; either may be zero) and decides the stake. A nonzero
     * worker payout records a completion; otherwise a dispute loss is recorded.
     */
    function resolveDispute(
        uint256 bountyId_,
        uint256 workerAmount_,
        uint256 funderAmount_,
        bool workerKeepsStake_
    ) public virtual override nonReentrant {
        BountyStorage storage $ = _getBountyStorage();
        Bounty storage b = _bounty($, bountyId_);
        _requireState(bountyId_, b.state, State.Disputed);
        if (msg.sender != b.arbiter) revert OnlyArbiter();
        if (workerAmount_ + funderAmount_ != b.reward) {
            revert SplitExceedsReward(bountyId_, b.reward, workerAmount_ + funderAmount_);
        }

        // Effects.
        b.state = State.Paid;
        address worker = b.worker;
        address funder = b.funder;
        uint256 stake = b.stake;

        // Interactions: distribute the reward per the split.
        if (workerAmount_ > 0) {
            $.escrow.release(_rewardKey(bountyId_), worker, workerAmount_);
        }
        if (funderAmount_ > 0) {
            $.escrow.refund(_rewardKey(bountyId_), funder, funderAmount_);
        }

        // Decide the stake: returned to worker, or slashed to funder/treasury.
        bytes32 stakeKey = _stakeKey(bountyId_, b.claimNonce);
        if (workerKeepsStake_) {
            $.escrow.release(stakeKey, worker, stake);
        } else {
            address to = _slashTarget($, funder);
            $.escrow.refund(stakeKey, to, stake);
            emit StakeSlashed(bountyId_, worker, to, stake);
        }

        // Record the outcome for the worker.
        if (workerAmount_ > 0) {
            $.reputation.recordCompletion(worker, workerAmount_);
        } else {
            $.reputation.recordDisputeLoss(worker);
        }

        emit DisputeResolved(bountyId_, msg.sender, workerAmount_, funderAmount_, workerKeepsStake_);
    }

    /**
     * @inheritdoc IBountyV1
     * @dev Open/Funded -> Cancelled. Funder-only. Refunds the escrowed reward (if
     * any) to the funder.
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

        // Interaction: refund the reward if it was escrowed.
        if (wasFunded) {
            $.escrow.refund(_rewardKey(bountyId_), b.funder, b.reward);
        }

        emit BountyCancelled(bountyId_, b.funder, wasFunded ? b.reward : 0);
    }

    /**
     * @inheritdoc IBountyV1
     * @dev Claimed -> Funded. PERMISSIONLESS after the deadline. Slashes the stuck
     * stake to the funder (or treasury) and re-opens the bounty for a new worker.
     * The reward stays escrowed.
     */
    function reclaim(uint256 bountyId_) public virtual override nonReentrant {
        BountyStorage storage $ = _getBountyStorage();
        Bounty storage b = _bounty($, bountyId_);
        _requireState(bountyId_, b.state, State.Claimed);
        if (block.timestamp <= b.claimDeadline) revert DeadlineNotPassed(bountyId_, b.claimDeadline);

        // Effects: re-open for a new claimer; clear worker-specific fields. Bump the
        // claim nonce so the next claim escrows its stake under a fresh key.
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
     * @dev Supports IBountyV1, IVersion, IDeploymentBlock, and IERC165.
     */
    function supportsInterface(bytes4 interfaceId_) public view virtual override returns (bool) {
        return
            interfaceId_ == type(IBountyV1).interfaceId ||
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
     * @dev Moves funds into escrow under a key. For native (token == 0) the exact
     * msg.value must equal the amount and is forwarded to the escrow; for ERC-20 no
     * native value may be attached and the escrow pulls from `payer` (who must have
     * approved the escrow). Centralizing the native/ERC-20 split keeps fund() and
     * claim() identical in shape (one way to escrow value).
     */
    function _escrowIn(
        BountyStorage storage $,
        bytes32 key_,
        address token_,
        address payer_,
        uint256 amount_,
        uint256 nativeValue_
    ) internal {
        if (token_ == address(0)) {
            if (nativeValue_ != amount_) revert StakeMismatch(amount_, nativeValue_);
            $.escrow.deposit{value: amount_}(key_, token_, payer_, amount_);
        } else {
            if (nativeValue_ != 0) revert UnexpectedNativeValue();
            $.escrow.deposit(key_, token_, payer_, amount_);
        }
    }

    /**
     * @dev Resolves where a slashed stake is sent: the configured treasury if set,
     * otherwise the bounty's funder.
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
     * @dev Deterministic escrow key for a bounty's stake deposit on a given claim
     * attempt. The nonce isolates each attempt so a slashed stake never blocks the
     * next worker's claim from re-using the bounty.
     */
    function _stakeKey(uint256 bountyId_, uint64 claimNonce_) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("stake", bountyId_, claimNonce_));
    }
}
