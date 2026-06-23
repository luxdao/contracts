// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IThinkingGovernor} from "./interfaces/IThinkingGovernor.sol";
import {IVersion} from "../../interfaces/dao/deployables/IVersion.sol";
import {IDeploymentBlock} from "../../interfaces/dao/IDeploymentBlock.sol";
import {IKeyValuePairsV1} from "../../interfaces/dao/singletons/IKeyValuePairsV1.sol";
import {DeploymentBlockNonInitializable} from "../../DeploymentBlockNonInitializable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

/**
 * @title ThinkingGovernor
 * @author Hanzo AI Inc / Lux Network
 * @notice Governance whose verdict is produced by a quorum of bonded
 * node-operator LLMs and recorded on-chain. The on-chain realization of the
 * Thinking Chains governance layer: the chain "thinks" by aggregating signed,
 * structured operator-LLM verdicts into a canonical decision and a governed knob.
 *
 * THREAT MODEL
 *   Assets:        the canonical decision, the governed knob, operator bonds.
 *   Adversaries:   verdict forgers, double-voters, signature relayers, malleators,
 *                  reentrancy on payout, settle-replayers, cross-spec confusers.
 *   Surface:       registerOperator, deregister, withdrawBond, openThought,
 *                  submitVerdict, settle, claimReward.
 *
 * DEFENSE IN DEPTH
 *   1. ecrecover over the EXACT Go canonical preimage (binds the decision to the
 *      task's modelSpecHash — a "yes under spec A" cannot count toward spec B).
 *   2. recovered signer MUST equal msg.sender (operator-bound; a detached/relayed
 *      signature for another operator is rejected).
 *   3. low-S + v∈{27,28} enforced by OpenZeppelin ECDSA (kills malleability
 *      double-submit; mirrors Go ValidateSignatureValues(homestead=true)).
 *   4. one verdict per operator per task (kills ballot stuffing).
 *   5. eligibility = bonded >= minBond, checked at submit AND counted at settle.
 *   6. strict-majority threshold (>= n/2 + 1) enforced at openThought.
 *   7. pull-payment rewards + checks-effects-interactions on bond return
 *      (no external value-call inside state mutation; nonReentrant on payouts).
 *   8. idempotent settle via the Status state machine (Open -> Settled|Failed once).
 *
 * SIGNATURE V NOTE
 *   Go crypto.Sign yields recovery id v ∈ {0,1}; ecrecover / OZ ECDSA expect
 *   v ∈ {27,28}. A relay submitting a Go operator's signature adds 27 to the
 *   final byte. Foundry's vm.sign already returns v ∈ {27,28}, so genuine test
 *   signatures verify directly. The signed DIGEST is the raw consensusHash (no
 *   EIP-191 prefix), identical to the off-chain operator which signs the raw
 *   keccak digest.
 *
 * @custom:security-contact security@lux.network
 */
contract ThinkingGovernor is
    IThinkingGovernor,
    IVersion,
    DeploymentBlockNonInitializable,
    ReentrancyGuard,
    ERC165
{
    using ECDSA for bytes32;

    // ======================================================================
    // CONSTANTS (protocol invariants — match the Go canonical package)
    // ======================================================================

    /// @notice Confidence grid width in bps. confidence must be a multiple of this
    /// (canonical.ConfidenceGridBps). 1000 bps = 11 buckets {0,1000,...,10000}.
    uint16 public constant CONFIDENCE_GRID_BPS = 1000;

    /// @notice Inclusive max confidence (100.00%). canonical.MaxConfidenceBps.
    uint16 public constant MAX_CONFIDENCE_BPS = 10000;

    /// @notice Hard cap on committee size to bound settle()'s O(n) tally loop and
    /// keep the per-task array storage cheap.
    uint8 public constant MAX_COMMITTEE = 64;

    /// @notice Voting-window bounds. A task cannot settle before its deadline unless
    /// all n verdicts are in; the window must be sane (neither instant nor absurd) so
    /// a griefer cannot force an empty/early settlement and an opener cannot lock a
    /// task open forever.
    uint64 public constant MIN_VOTING_WINDOW = 1 hours;
    uint64 public constant MAX_VOTING_WINDOW = 30 days;

    /// @notice Domain tag for the verdict signature. Mirrors the Go operator's reveal
    /// domain ("hanzo/aiquorum/reveal/v1") for the thinking-governance verdict.
    /// Domain separation prevents a signature minted for this purpose from being
    /// replayed as any other secp256k1-signed message (or vice-versa).
    bytes32 public constant VERDICT_DOMAIN = keccak256("hanzo/thinking-governor/verdict/v1");

    /// @notice Domain tag for the commit-reveal commit digest. Distinct from {VERDICT_DOMAIN} so
    /// a sealed commit can never be confused with (or replayed as) a cleartext-submit signature.
    bytes32 public constant COMMIT_DOMAIN = keccak256("hanzo/thinking-governor/commit/v1");

    // ======================================================================
    // IMMUTABLE CONFIG
    // ======================================================================

    /// @notice Minimum bond an operator must lock to be eligible.
    uint256 private immutable _minBond;

    /// @notice Cooldown (seconds) between deregister() and withdrawBond().
    uint64 public immutable deregisterCooldown;

    /// @notice Per-task reward pool funded by the opener, split among agreeing
    /// operators. Refunded to the opener on a no-quorum. Zero is valid.
    uint256 public immutable rewardPerThought;

    /// @notice Non-refundable fee the opener pays to open a thought. Unlike the
    /// reward (which can round-trip to a self-dealing opener), this fee LEAVES the
    /// opener permanently (accrues to the treasury), so minting a forged on-chain
    /// quorum always costs real value. Zero is valid (disables the anti-sybil fee).
    uint256 private immutable _openFee;

    /// @notice Treasury that accrues open fees via pull-payment. If zero, the open
    /// fee must also be zero (no sink configured).
    address private immutable _treasury;

    /// @notice The DAO KeyValuePairs singleton. When set (non-zero), a YES-quorum
    /// mirrors its knob to ValueUpdated so the existing DAO subgraph indexes it.
    /// Zero is valid: the contract still emits its own {KnobSet} event + stores the
    /// knob, so on-chain visibility never depends on this being configured.
    IKeyValuePairsV1 public immutable keyValuePairs;

    // ======================================================================
    // STORAGE
    // ======================================================================

    struct Operator {
        uint256 bond;
        uint64 deregisterAt; // 0 = active; else the timestamp deregister() was called
        uint64 registeredAt; // block number the operator first bonded (for sortition eligibility)
    }

    /// @notice Count of currently-bonded operators (the sortition population). Used
    /// by value/vote committee sampling so committee share tracks population share.
    uint256 private _operatorCount;

    mapping(address => Operator) private _operators;

    Thought[] private _thoughts;

    // taskId => operator => verdict
    mapping(uint256 => mapping(address => Verdict)) private _verdicts;
    // taskId => operator => has submitted (cheap double-vote guard)
    mapping(uint256 => mapping(address => bool)) private _voted;
    // taskId => list of submitters (bounded by n <= MAX_COMMITTEE)
    mapping(uint256 => address[]) private _submitters;

    // commit-reveal: taskId => operator => sealed commit (zero = not committed)
    mapping(uint256 => mapping(address => bytes32)) private _commit;

    // operator => withdrawable reward (pull-payment)
    mapping(address => uint256) private _rewards;

    // ======================================================================
    // CONSTRUCTOR
    // ======================================================================

    /**
     * @param minBond_ minimum operator bond (wei).
     * @param deregisterCooldown_ seconds an operator must wait after deregister()
     *        before withdrawBond(). (Eligibility is ALSO re-checked at settle, so a
     *        zero cooldown still cannot let an exited operator tip a quorum.)
     * @param rewardPerThought_ wei the opener escrows per task, split among the
     *        agreeing group on a quorum, refunded to the opener on no-quorum. 0 = off.
     * @param openFee_ NON-refundable wei the opener pays per task (anti-sybil). Must
     *        be 0 if treasury_ is address(0).
     * @param treasury_ recipient of open fees (pull-payment). address(0) only if
     *        openFee_ is 0.
     * @param keyValuePairs_ DAO KeyValuePairsV1 singleton (address(0) to skip the
     *        external mirror; the contract still stores + emits the knob itself).
     */
    constructor(
        uint256 minBond_,
        uint64 deregisterCooldown_,
        uint256 rewardPerThought_,
        uint256 openFee_,
        address treasury_,
        address keyValuePairs_
    ) {
        require(treasury_ != address(0) || openFee_ == 0, "openFee needs treasury");
        require(treasury_ != address(this), "treasury cannot be self");
        require(minBond_ > 0, "minBond must be > 0");
        _minBond = minBond_;
        deregisterCooldown = deregisterCooldown_;
        rewardPerThought = rewardPerThought_;
        _openFee = openFee_;
        _treasury = treasury_;
        keyValuePairs = IKeyValuePairsV1(keyValuePairs_);
    }

    // ======================================================================
    // OPERATOR REGISTRY
    // ======================================================================

    /// @inheritdoc IThinkingGovernor
    function registerOperator() external payable override {
        Operator storage op = _operators[msg.sender];
        if (op.bond != 0) revert AlreadyRegistered(msg.sender);
        if (msg.value < _minBond) revert BondTooLow(msg.value, _minBond);
        op.bond = msg.value;
        op.deregisterAt = 0;
        op.registeredAt = uint64(block.number);
        _operatorCount += 1;
        emit OperatorRegistered(msg.sender, msg.value);
    }

    /// @inheritdoc IThinkingGovernor
    /// @dev Starts the withdrawal cooldown. The operator becomes INELIGIBLE for
    /// new verdicts immediately (eligibility requires deregisterAt == 0), but the
    /// bond is only withdrawable after the cooldown.
    function deregister() external override {
        Operator storage op = _operators[msg.sender];
        if (op.bond == 0) revert NoBondToWithdraw();
        op.deregisterAt = uint64(block.timestamp);
        emit OperatorDeregisterRequested(msg.sender, uint64(block.timestamp) + deregisterCooldown);
    }

    /// @inheritdoc IThinkingGovernor
    /// @dev Checks-effects-interactions + nonReentrant. Bond is zeroed before the
    /// transfer so a reentrant call sees no bond.
    function withdrawBond() external override nonReentrant {
        Operator storage op = _operators[msg.sender];
        uint256 amount = op.bond;
        if (amount == 0) revert NoBondToWithdraw();
        if (op.deregisterAt == 0) revert DeregisterCooldownActive(0);
        uint64 ready = op.deregisterAt + deregisterCooldown;
        if (block.timestamp < ready) revert DeregisterCooldownActive(ready);

        // EFFECTS
        op.bond = 0;
        op.deregisterAt = 0;
        if (_operatorCount != 0) _operatorCount -= 1;

        // INTERACTION
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "transfer failed");
        emit BondWithdrawn(msg.sender, amount);
    }

    /// @inheritdoc IThinkingGovernor
    function claimReward() external override nonReentrant {
        uint256 amount = _rewards[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        _rewards[msg.sender] = 0; // EFFECTS before INTERACTION
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "transfer failed");
        emit BondWithdrawn(msg.sender, amount);
    }

    // ======================================================================
    // THINKING TASKS
    // ======================================================================

    /// @inheritdoc IThinkingGovernor
    function openThought(
        bytes32 modelSpecHash,
        bytes32 promptHash,
        bytes32 evidenceHash,
        uint8 n,
        uint8 threshold,
        uint64 votingWindow,
        string calldata knobKey
    ) external payable override returns (uint256 taskId) {
        if (modelSpecHash == bytes32(0)) revert ZeroModelSpec();
        if (n == 0 || n > MAX_COMMITTEE) revert BadCommitteeSize(n);
        // Strict majority: threshold must be at least floor(n/2)+1 and at most n.
        uint8 majority = n / 2 + 1;
        if (threshold < majority || threshold > n) revert BadThreshold(n, threshold);
        if (votingWindow < MIN_VOTING_WINDOW || votingWindow > MAX_VOTING_WINDOW) {
            revert BadVotingWindow(votingWindow);
        }
        if (bytes(knobKey).length == 0) revert EmptyKnobKey();
        // The treasury must not open thoughts: the fee would accrue to its own
        // claimable balance, refunding the opener and nullifying the anti-sybil cost.
        if (msg.sender == _treasury) revert OpenerIsTreasury(msg.sender);
        // Opener pays the refundable reward escrow PLUS the non-refundable open fee.
        if (msg.value != rewardPerThought + _openFee) {
            revert WrongOpenPayment(msg.value, rewardPerThought + _openFee);
        }

        // The open fee leaves the opener permanently (accrues to the treasury) so a
        // forged/sybil quorum always costs real value, independent of reward flow.
        if (_openFee != 0) {
            _rewards[_treasury] += _openFee;
        }

        taskId = _thoughts.length;
        _thoughts.push(
            Thought({
                modelSpecHash: modelSpecHash,
                promptHash: promptHash,
                evidenceHash: evidenceHash,
                n: n,
                threshold: threshold,
                openedAt: uint64(block.timestamp),
                deadline: uint64(block.timestamp) + votingWindow,
                opener: msg.sender,
                status: Status.Open,
                submissionCount: 0,
                knobKey: knobKey,
                canonicalVote: Vote.Invalid,
                canonicalBucket: 0,
                agreeCount: 0,
                evidenceRoot: bytes32(0),
                commitReveal: false,
                commitDeadline: 0,
                revealDeadline: 0
            })
        );

        emit ThoughtOpened(taskId, modelSpecHash, promptHash, evidenceHash, n, threshold, knobKey, msg.sender);
    }

    /// @inheritdoc IThinkingGovernor
    function submitVerdict(
        uint256 taskId,
        uint8 vote,
        uint16 confidenceBucket,
        bytes32 evidenceHash,
        bytes calldata sig
    ) external override {
        Thought storage t = _thoughtAt(taskId);
        // A commit-reveal task admits NO cleartext verdict: a plaintext vote is exactly the
        // value-copyable datum commit-reveal exists to hide. Force the commit→reveal path.
        if (t.commitReveal) revert UseCommitReveal(taskId);
        if (t.status != Status.Open) revert TaskNotOpen(taskId);
        if (t.submissionCount >= t.n) revert TaskFull(taskId);
        if (_voted[taskId][msg.sender]) revert AlreadyVoted(taskId, msg.sender);
        // The opener cannot also be a committee member on its own task — removes the
        // most direct self-deal (opener voting to mint its own decision).
        if (msg.sender == t.opener) revert OpenerCannotVote(taskId, msg.sender);

        // Recover over the domain-separated VERDICT digest, which binds taskId,
        // operator, the consensus fields, AND evidenceHash. OZ ECDSA enforces low-S
        // and v∈{27,28}. Binding taskId makes a verdict non-transferable across tasks
        // (even ones sharing modelSpecHash); binding evidenceHash authenticates the
        // attested evidence; binding operator names the signer in the signature.
        bytes32 digest = _verdictDigest(taskId, msg.sender, t.modelSpecHash, vote, confidenceBucket, evidenceHash);
        address signer = digest.recover(sig);

        // Operator-bound: the signer must be the caller. Kills relay of a detached
        // signature belonging to a different operator.
        if (signer != msg.sender) revert SignerMismatch(signer, msg.sender);

        _recordVerdict(taskId, t, msg.sender, vote, confidenceBucket, evidenceHash);
    }

    /// @dev Shared verdict-recording effects for BOTH the cleartext ({submitVerdict}) and the
    /// commit-reveal ({revealVerdict}) paths — extracted so the tally sees an identical record
    /// regardless of which authentication envelope (signature vs operator-bound commit) admitted
    /// it. Validates structure + eligibility, then writes the verdict, appends the submitter, and
    /// emits {VerdictSubmitted}. The caller has already authenticated the operator.
    function _recordVerdict(
        uint256 taskId,
        Thought storage t,
        address operator,
        uint8 vote,
        uint16 confidenceBucket,
        bytes32 evidenceHash
    ) private {
        // Structural validity of the consensus fields (mirrors the Go schema).
        if (!_isValidVote(vote)) revert InvalidVote(vote);
        if (!_isValidBucket(confidenceBucket)) revert BadConfidenceBucket(confidenceBucket);

        // Eligibility: bonded >= minBond AND not in deregister cooldown.
        if (!_eligible(operator)) revert NotBonded(operator);

        // EFFECTS
        _voted[taskId][operator] = true;
        _verdicts[taskId][operator] = Verdict({
            operator: operator,
            vote: Vote(vote),
            confidenceBucket: confidenceBucket,
            evidenceHash: evidenceHash,
            submittedAt: uint64(block.timestamp)
        });
        _submitters[taskId].push(operator);
        unchecked {
            t.submissionCount += 1; // bounded by n <= MAX_COMMITTEE
        }

        // The consensus hash (Go-parity quorum key) for visibility/indexing.
        bytes32 chash = _consensusHash(t.modelSpecHash, vote, confidenceBucket);
        emit VerdictSubmitted(taskId, operator, vote, confidenceBucket, evidenceHash, chash);
    }

    // ======================================================================
    // COMMIT-REVEAL (anti value-copy; mirrors chains/aivm/commit_reveal.go)
    // ======================================================================

    /// @inheritdoc IThinkingGovernor
    function openThoughtCommitReveal(
        bytes32 modelSpecHash,
        bytes32 promptHash,
        bytes32 evidenceHash,
        uint8 n,
        uint8 threshold,
        uint64 commitWindow,
        uint64 revealWindow,
        string calldata knobKey
    ) external payable override returns (uint256 taskId) {
        if (modelSpecHash == bytes32(0)) revert ZeroModelSpec();
        if (n == 0 || n > MAX_COMMITTEE) revert BadCommitteeSize(n);
        uint8 majority = n / 2 + 1;
        if (threshold < majority || threshold > n) revert BadThreshold(n, threshold);
        // Each window must independently be sane (same bounds as the single voting window): a
        // griefer can neither force an instant commit/reveal nor lock the task open forever.
        if (
            commitWindow < MIN_VOTING_WINDOW ||
            commitWindow > MAX_VOTING_WINDOW ||
            revealWindow < MIN_VOTING_WINDOW ||
            revealWindow > MAX_VOTING_WINDOW
        ) {
            revert BadCommitRevealWindow(commitWindow, revealWindow);
        }
        if (bytes(knobKey).length == 0) revert EmptyKnobKey();
        if (msg.sender == _treasury) revert OpenerIsTreasury(msg.sender);
        if (msg.value != rewardPerThought + _openFee) {
            revert WrongOpenPayment(msg.value, rewardPerThought + _openFee);
        }
        if (_openFee != 0) {
            _rewards[_treasury] += _openFee;
        }

        uint64 commitDeadline = uint64(block.timestamp) + commitWindow;
        uint64 revealDeadline = commitDeadline + revealWindow;

        taskId = _thoughts.length;
        _thoughts.push(
            Thought({
                modelSpecHash: modelSpecHash,
                promptHash: promptHash,
                evidenceHash: evidenceHash,
                n: n,
                threshold: threshold,
                openedAt: uint64(block.timestamp),
                // settle() is gated on `block.timestamp < deadline`; setting it to the reveal
                // close makes settle wait for the WHOLE commit+reveal duration.
                deadline: revealDeadline,
                opener: msg.sender,
                status: Status.Open,
                submissionCount: 0,
                knobKey: knobKey,
                canonicalVote: Vote.Invalid,
                canonicalBucket: 0,
                agreeCount: 0,
                evidenceRoot: bytes32(0),
                commitReveal: true,
                commitDeadline: commitDeadline,
                revealDeadline: revealDeadline
            })
        );

        emit ThoughtOpened(taskId, modelSpecHash, promptHash, evidenceHash, n, threshold, knobKey, msg.sender);
    }

    /// @inheritdoc IThinkingGovernor
    function commitVerdict(uint256 taskId, bytes32 commit) external override {
        Thought storage t = _thoughtAt(taskId);
        if (!t.commitReveal) revert NotCommitReveal(taskId);
        if (t.status != Status.Open) revert TaskNotOpen(taskId);
        if (commit == bytes32(0)) revert EmptyCommit();
        // Commit window: open up to and including commitDeadline.
        if (block.timestamp > t.commitDeadline) revert CommitClosed(taskId);
        if (t.submissionCount >= t.n) revert TaskFull(taskId);
        if (msg.sender == t.opener) revert OpenerCannotVote(taskId, msg.sender);
        // Eligibility is checked at commit AND re-checked at reveal (and again at settle), so an
        // operator that exits between phases cannot tip the quorum.
        if (!_eligible(msg.sender)) revert NotBonded(msg.sender);
        if (_commit[taskId][msg.sender] != bytes32(0)) revert AlreadyCommitted(taskId, msg.sender);

        _commit[taskId][msg.sender] = commit;
        emit VerdictCommitted(taskId, msg.sender, commit);
    }

    /// @inheritdoc IThinkingGovernor
    function revealVerdict(
        uint256 taskId,
        uint8 vote,
        uint16 confidenceBucket,
        bytes32 evidenceHash,
        bytes32 nonce
    ) external override {
        Thought storage t = _thoughtAt(taskId);
        if (!t.commitReveal) revert NotCommitReveal(taskId);
        if (t.status != Status.Open) revert TaskNotOpen(taskId);
        // THE ANTI-COPY GATE: reveal opens STRICTLY AFTER the commit window closes, so no
        // operator can have observed a peer's revealed fields before its own commit was sealed.
        if (block.timestamp <= t.commitDeadline) revert RevealNotOpen(taskId);
        if (block.timestamp > t.revealDeadline) revert RevealClosed(taskId);

        bytes32 stored = _commit[taskId][msg.sender];
        if (stored == bytes32(0)) revert NotCommitted(taskId, msg.sender);
        // _voted is set by _recordVerdict; a second reveal is rejected here (operator-bound).
        if (_voted[taskId][msg.sender]) revert AlreadyVoted(taskId, msg.sender);

        // Recompute the operator-bound commit; a copied commit value reveals to a DIFFERENT
        // digest under the copier's address, so only the original committer can reveal it.
        bytes32 recomputed = _commitDigest(taskId, msg.sender, vote, confidenceBucket, evidenceHash, nonce);
        if (recomputed != stored) revert CommitMismatch(taskId, msg.sender);

        _recordVerdict(taskId, t, msg.sender, vote, confidenceBucket, evidenceHash);
    }

    /// @inheritdoc IThinkingGovernor
    function commitDigest(
        uint256 taskId,
        address operator,
        uint8 vote,
        uint16 confidenceBucket,
        bytes32 evidenceHash,
        bytes32 nonce
    ) external view override returns (bytes32) {
        return _commitDigest(taskId, operator, vote, confidenceBucket, evidenceHash, nonce);
    }

    /// @inheritdoc IThinkingGovernor
    /// @dev Idempotent: once a task leaves Open it can never be settled again.
    /// Tallies verdicts by the consensus key {vote, confidenceBucket}. The largest
    /// group decides; if it reaches threshold the task SETTLES with that canonical
    /// decision, otherwise it FAILS. On a YES-quorum the governed knob is set.
    function settle(uint256 taskId) external override {
        Thought storage t = _thoughtAt(taskId);
        if (t.status != Status.Open) revert AlreadySettled(taskId);

        address[] storage subs = _submitters[taskId];
        uint256 count = subs.length;

        // Liveness gate: a task may only settle once its voting window has CLOSED, or
        // earlier once ALL n committee slots are filled (nothing more can change the
        // outcome). This blocks (a) settling an empty task to Failed, and (b) front-
        // running the threshold-th honest vote to suppress a forming quorum.
        if (block.timestamp < t.deadline) revert SettleTooEarly(taskId, t.deadline);

        // Tally by consensus key, counting ONLY verdicts from operators still
        // eligible at settle time. A verdict from an operator that exited (bond < min
        // or deregistering) after submitting is DROPPED — a zero-skin address cannot
        // tip the canonical quorum. count <= n <= MAX_COMMITTEE bounds the O(n^2).
        bytes32[] memory keys = new bytes32[](count);
        uint8[] memory tallies = new uint8[](count);
        uint256 distinct;

        uint256 bestIdx;
        uint8 bestCount;

        for (uint256 i; i < count; ) {
            if (!_bonded(subs[i])) {
                unchecked {
                    ++i;
                }
                continue;
            }
            Verdict storage v = _verdicts[taskId][subs[i]];
            bytes32 key = _consensusKey(v.vote, v.confidenceBucket);

            uint256 j;
            for (; j < distinct; ) {
                if (keys[j] == key) break;
                unchecked {
                    ++j;
                }
            }
            if (j == distinct) {
                keys[distinct] = key;
                tallies[distinct] = 1;
                if (1 > bestCount) {
                    bestCount = 1;
                    bestIdx = distinct;
                }
                unchecked {
                    ++distinct;
                }
            } else {
                unchecked {
                    tallies[j] += 1;
                }
                if (tallies[j] > bestCount) {
                    bestCount = tallies[j];
                    bestIdx = j;
                }
            }
            unchecked {
                ++i;
            }
        }

        // Emit the full distribution (right-sized) for on-chain dissent visibility.
        bytes32[] memory distKeys = new bytes32[](distinct);
        uint8[] memory distCounts = new uint8[](distinct);
        for (uint256 k; k < distinct; ) {
            distKeys[k] = keys[k];
            distCounts[k] = tallies[k];
            unchecked {
                ++k;
            }
        }
        emit VerdictDistribution(taskId, distKeys, distCounts);

        if (bestCount < t.threshold) {
            // No quorum. Knob unchanged. Reward pool refunded to opener.
            t.status = Status.Failed;
            t.submissionCount = uint8(count);
            _refundOpener(t.opener);
            emit ThoughtSettled(
                taskId,
                uint8(Vote.Invalid),
                0,
                0,
                uint8(count),
                bytes32(0),
                new address[](0)
            );
            return;
        }

        // Quorum reached. Decode the winning consensus key.
        (Vote winVote, uint16 winBucket) = _decodeKey(keys[bestIdx]);

        // Collect the agreeing operators (eligibility re-checked, identical to the
        // tally pass so agreeing.length == bestCount exactly) + fold their evidence
        // hashes into a root in submission order.
        address[] memory agreeing = new address[](bestCount);
        bytes32 evidenceRoot;
        uint256 a;
        for (uint256 i; i < count; ) {
            address opAddr = subs[i];
            if (_bonded(opAddr)) {
                Verdict storage v = _verdicts[taskId][opAddr];
                if (_consensusKey(v.vote, v.confidenceBucket) == keys[bestIdx]) {
                    agreeing[a] = opAddr;
                    evidenceRoot = keccak256(abi.encodePacked(evidenceRoot, v.evidenceHash));
                    unchecked {
                        ++a;
                    }
                }
            }
            unchecked {
                ++i;
            }
        }

        // EFFECTS: record the canonical decision on-chain.
        t.status = Status.Settled;
        t.canonicalVote = winVote;
        t.canonicalBucket = winBucket;
        t.agreeCount = bestCount;
        t.submissionCount = uint8(count);
        t.evidenceRoot = evidenceRoot;

        // Knob effect: only a YES decision sets the governed parameter. The knob is
        // scoped to (modelSpecHash, knobKey) so a decision under one spec can never
        // overwrite a knob governed by another spec. The value encodes
        // {vote, bucket, agreeCount} so a reader gets the full decision from the
        // 32-byte value alone.
        if (winVote == Vote.Yes) {
            bytes32 knobValue = _encodeKnobValue(winVote, winBucket, bestCount);
            _setKnob(t.modelSpecHash, t.knobKey, knobValue, taskId);
        }

        // Rewards (pull-payment): split the escrowed pool among the agreeing group
        // (whatever they decided — forming consensus is the rewarded work). The
        // integer-division remainder is assigned to the FIRST agreer so the FULL
        // escrow is always distributed (no wei is ever locked in the contract).
        // bestCount != 0 here because bestCount >= threshold >= 1.
        if (rewardPerThought != 0) {
            uint256 share = rewardPerThought / bestCount;
            uint256 remainder = rewardPerThought - share * bestCount;
            for (uint256 i; i < bestCount; ) {
                uint256 amt = share + (i == 0 ? remainder : 0);
                if (amt != 0) {
                    _rewards[agreeing[i]] += amt;
                    emit RewardAccrued(agreeing[i], amt, taskId);
                }
                unchecked {
                    ++i;
                }
            }
        }

        emit ThoughtSettled(
            taskId,
            uint8(winVote),
            winBucket,
            bestCount,
            uint8(count),
            evidenceRoot,
            agreeing
        );
    }

    // ======================================================================
    // CANONICAL PREIMAGE (parity surface) — matches Go canonical/governance.go
    // ======================================================================

    /// @inheritdoc IThinkingGovernor
    function consensusPreimage(
        bytes32 modelSpecHash,
        uint8 vote,
        uint16 confidenceBucket
    ) external pure override returns (bytes memory) {
        // abi.encodePacked(bytes32, uint8, uint16) == modelSpecHash(32) ++ vote(1)
        // ++ u16be(bucket)(2). Solidity packs uint16 big-endian, no padding —
        // byte-identical to the Go binary.BigEndian.PutUint16 concatenation.
        return abi.encodePacked(modelSpecHash, vote, confidenceBucket);
    }

    /// @inheritdoc IThinkingGovernor
    function consensusHash(
        bytes32 modelSpecHash,
        uint8 vote,
        uint16 confidenceBucket
    ) external pure override returns (bytes32) {
        return _consensusHash(modelSpecHash, vote, confidenceBucket);
    }

    /// @inheritdoc IThinkingGovernor
    function verdictDigest(
        uint256 taskId,
        address operator,
        bytes32 modelSpecHash,
        uint8 vote,
        uint16 confidenceBucket,
        bytes32 evidenceHash
    ) external view override returns (bytes32) {
        return _verdictDigest(taskId, operator, modelSpecHash, vote, confidenceBucket, evidenceHash);
    }

    // ======================================================================
    // VIEWS
    // ======================================================================

    /// @inheritdoc IThinkingGovernor
    function getThought(uint256 taskId) external view override returns (Thought memory) {
        return _thoughtAt(taskId);
    }

    /// @inheritdoc IThinkingGovernor
    function getVerdict(uint256 taskId, address operator) external view override returns (Verdict memory) {
        _thoughtAt(taskId); // existence check
        return _verdicts[taskId][operator];
    }

    /// @inheritdoc IThinkingGovernor
    function getVerdicts(uint256 taskId) external view override returns (Verdict[] memory) {
        _thoughtAt(taskId);
        address[] storage subs = _submitters[taskId];
        Verdict[] memory out = new Verdict[](subs.length);
        for (uint256 i; i < subs.length; ) {
            out[i] = _verdicts[taskId][subs[i]];
            unchecked {
                ++i;
            }
        }
        return out;
    }

    /// @inheritdoc IThinkingGovernor
    function getCanonicalVerdict(
        uint256 taskId
    ) external view override returns (bool settled, Vote vote, uint16 confidenceBucket, uint8 agreeCount) {
        Thought storage t = _thoughtAt(taskId);
        settled = t.status == Status.Settled;
        vote = t.canonicalVote;
        confidenceBucket = t.canonicalBucket;
        agreeCount = t.agreeCount;
    }

    /// @inheritdoc IThinkingGovernor
    function getKnob(bytes32 modelSpecHash, string calldata key) external view override returns (bytes32) {
        return _knobs[_knobSlot(modelSpecHash, key)];
    }

    /// @inheritdoc IThinkingGovernor
    function openFee() external view override returns (uint256) {
        return _openFee;
    }

    /// @inheritdoc IThinkingGovernor
    function treasury() external view override returns (address) {
        return _treasury;
    }

    /// @inheritdoc IThinkingGovernor
    function isOperator(address who) external view override returns (bool) {
        return _eligible(who);
    }

    /// @inheritdoc IThinkingGovernor
    function bondOf(address who) external view override returns (uint256) {
        return _operators[who].bond;
    }

    /// @inheritdoc IThinkingGovernor
    function operatorCount() external view override returns (uint256) {
        return _operatorCount;
    }

    /// @inheritdoc IThinkingGovernor
    function operatorSince(address who) external view override returns (uint64) {
        return _operators[who].registeredAt;
    }

    /// @inheritdoc IThinkingGovernor
    function rewardOf(address who) external view override returns (uint256) {
        return _rewards[who];
    }

    /// @inheritdoc IThinkingGovernor
    function taskCount() external view override returns (uint256) {
        return _thoughts.length;
    }

    /// @inheritdoc IThinkingGovernor
    function minBond() external view override returns (uint256) {
        return _minBond;
    }

    // ======================================================================
    // IVersion / ERC165
    // ======================================================================

    function version() external pure override returns (uint16) {
        return 1;
    }

    function supportsInterface(bytes4 interfaceId_) public view virtual override returns (bool) {
        return
            interfaceId_ == type(IThinkingGovernor).interfaceId ||
            interfaceId_ == type(IVersion).interfaceId ||
            interfaceId_ == type(IDeploymentBlock).interfaceId ||
            super.supportsInterface(interfaceId_);
    }

    // ======================================================================
    // INTERNAL — knob store (settable ONLY by settle())
    // ======================================================================

    /// @dev The governed knobs, keyed by _knobSlot(modelSpecHash, key) =
    /// keccak256(abi.encode(spec, key)). Written exclusively by _setKnob, which is
    /// called only from settle(). No setter is exposed — the only path to mutate a
    /// knob is a YES-quorum thinking-validator decision under that exact spec.
    mapping(bytes32 => bytes32) private _knobs;

    /// @dev Spec-scoped storage slot for a knob. abi.encode (not encodePacked) so a
    /// dynamic `key` cannot be crafted to collide with a different (spec,key) pair.
    function _knobSlot(bytes32 modelSpecHash, string memory key) private pure returns (bytes32) {
        return keccak256(abi.encode(modelSpecHash, key));
    }

    function _setKnob(bytes32 modelSpecHash, string memory key, bytes32 value, uint256 taskId) private {
        _knobs[_knobSlot(modelSpecHash, key)] = value;
        emit KnobSet(modelSpecHash, key, value, taskId);

        // Mirror to the DAO KeyValuePairs singleton so the existing subgraph
        // surfaces it. Best-effort + isolated: a misbehaving singleton must not be
        // able to revert the settlement (the authoritative record is our own
        // storage + KnobSet event). The mirrored key is SPEC-QUALIFIED
        // ("<specHex>:<key>") so the subgraph namespace can't suffer the cross-spec
        // collision the on-chain slot now prevents. The call is gas-capped: a
        // singleton that BURNS gas (rather than reverting) would otherwise consume
        // 63/64 of the remaining gas (EIP-150) and could brick settle on a
        // low-block-limit chain or tax every settler — try/catch alone does not
        // contain that. 200k is ample for a 1-entry updateValues.
        if (address(keyValuePairs) != address(0)) {
            IKeyValuePairsV1.KeyValuePair[] memory kv = new IKeyValuePairsV1.KeyValuePair[](1);
            string memory qualifiedKey = string(abi.encodePacked(_toHexString(modelSpecHash), ":", key));
            kv[0] = IKeyValuePairsV1.KeyValuePair({key: qualifiedKey, value: _toHexString(value)});
            try keyValuePairs.updateValues{gas: 200_000}(kv) {
                // mirrored
            } catch {
                // ignore: our own state + event is the source of truth
            }
        }
    }

    // ======================================================================
    // INTERNAL — helpers
    // ======================================================================

    function _thoughtAt(uint256 taskId) private view returns (Thought storage) {
        if (taskId >= _thoughts.length) revert UnknownTask(taskId);
        return _thoughts[taskId];
    }

    /// @dev Skin-in-the-game at SETTLE time: a NON-ZERO bond at/above minBond. The
    /// `bond != 0` floor is load-bearing independent of minBond — it distinguishes a
    /// registered operator from the zero Operator struct of an address that never
    /// bonded. Does NOT consider the deregister flag: a deregistered-but-bonded
    /// operator still has capital at risk through settlement, so its already-cast
    /// verdict counts; only a fully-WITHDRAWN operator (bond -> 0) is dropped.
    function _bonded(address who) private view returns (bool) {
        Operator storage op = _operators[who];
        return op.bond != 0 && op.bond >= _minBond;
    }

    /// @dev Eligibility to SUBMIT a new verdict: bonded (see {_bonded}) AND not in a
    /// withdrawal cooldown. Composed on _bonded so the non-zero floor is shared.
    function _eligible(address who) private view returns (bool) {
        return _bonded(who) && _operators[who].deregisterAt == 0;
    }

    function _consensusHash(
        bytes32 modelSpecHash,
        uint8 vote,
        uint16 confidenceBucket
    ) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(modelSpecHash, vote, confidenceBucket));
    }

    /// @dev The signed verdict digest. Domain-separated and bound to the EXACT task,
    /// operator, consensus fields, and evidence. Mirror this concatenation in the Go
    /// operator (domain || u256be(taskId) || spec || vote || u16be(bucket) ||
    /// evidence || operator) to sign on-chain-acceptable verdicts. Note: the CONSENSUS
    /// hash (Go-parity quorum key) is the SEPARATE keccak(spec||vote||bucket) — this
    /// digest is purely the submission-authentication envelope around it, so adding
    /// taskId/operator/evidence here does NOT perturb Go quorum parity.
    function _verdictDigest(
        uint256 taskId,
        address operator,
        bytes32 modelSpecHash,
        uint8 vote,
        uint16 confidenceBucket,
        bytes32 evidenceHash
    ) private view returns (bytes32) {
        // Bind the signature to THIS governor instance and chain (block.chainid +
        // address(this)), not just the purpose domain. Without it a verdict signed
        // for one deployment is byte-identical on another instance or another
        // chain (fork/L2/CREATE2 twin), so an operator's own re-submission could
        // manufacture a quorum it never intended there. This is the EIP-712-style
        // domain separation the prior digest was missing.
        return
            keccak256(
                abi.encodePacked(
                    VERDICT_DOMAIN,
                    block.chainid,
                    address(this),
                    taskId,
                    modelSpecHash,
                    vote,
                    confidenceBucket,
                    evidenceHash,
                    operator
                )
            );
    }

    /// @dev The operator-bound commit digest. Domain-separated and bound to this deployment
    /// (block.chainid + address(this)), the task, the operator, the revealed consensus fields,
    /// the evidence, and a secret nonce. Mirrors the A-Chain ComputeCommit
    /// (chains/aivm/selection.go) discipline: the operator binding means a copied commit cannot
    /// be revealed by anyone else; the nonce keeps the commit hiding (an observer cannot brute-
    /// force the small {vote, bucket} space without it); the deployment binding stops cross-
    /// instance/chain replay. This is the on-chain analogue of the task's
    /// keccak(operator‖vote‖bucket‖evidenceHash‖nonce), hardened with the domain + chain +
    /// instance + task separators the cleartext digest already carries.
    function _commitDigest(
        uint256 taskId,
        address operator,
        uint8 vote,
        uint16 confidenceBucket,
        bytes32 evidenceHash,
        bytes32 nonce
    ) private view returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    COMMIT_DOMAIN,
                    block.chainid,
                    address(this),
                    taskId,
                    operator,
                    vote,
                    confidenceBucket,
                    evidenceHash,
                    nonce
                )
            );
    }

    /// @dev Consensus key for tallying: a verdict agrees with another iff they
    /// share (vote, confidenceBucket). modelSpecHash is constant within a task, so
    /// it need not be re-bound here (it is already bound in the signed digest).
    function _consensusKey(Vote vote, uint16 bucket) private pure returns (bytes32) {
        return bytes32((uint256(uint8(vote)) << 16) | uint256(bucket));
    }

    function _decodeKey(bytes32 key) private pure returns (Vote vote, uint16 bucket) {
        uint256 k = uint256(key);
        vote = Vote(uint8(k >> 16));
        bucket = uint16(k);
    }

    /// @dev Knob value layout (big-endian, self-describing in 32 bytes):
    ///   byte[31] = vote, byte[30..29] = confidenceBucket (be), byte[28] = agreeCount.
    function _encodeKnobValue(Vote vote, uint16 bucket, uint8 agree) private pure returns (bytes32) {
        return bytes32((uint256(agree) << 24) | (uint256(bucket) << 8) | uint256(uint8(vote)));
    }

    function _isValidVote(uint8 vote) private pure returns (bool) {
        // 1=yes,2=no,3=abstain,4=delay,5=unsafe. 0 (Invalid) is rejected.
        return vote >= uint8(Vote.Yes) && vote <= uint8(Vote.Unsafe);
    }

    /// @dev Confidence must be on the canonical grid: a multiple of
    /// CONFIDENCE_GRID_BPS within [0, MAX_CONFIDENCE_BPS]. The operator snaps with
    /// banker's rounding off-chain (canonical.BucketBps); on-chain we require the
    /// already-snapped value so two operators that snapped identically collide.
    function _isValidBucket(uint16 bucket) private pure returns (bool) {
        return bucket <= MAX_CONFIDENCE_BPS && (bucket % CONFIDENCE_GRID_BPS == 0);
    }

    function _refundOpener(address opener) private {
        if (rewardPerThought != 0) {
            _rewards[opener] += rewardPerThought;
        }
    }

    /// @dev "0x"-prefixed lowercase hex of a bytes32, for the string-typed
    /// KeyValuePairs mirror.
    function _toHexString(bytes32 value) private pure returns (string memory) {
        bytes16 hexSymbols = "0123456789abcdef";
        bytes memory buf = new bytes(66);
        buf[0] = "0";
        buf[1] = "x";
        for (uint256 i; i < 32; ) {
            uint8 b = uint8(value[i]);
            buf[2 + i * 2] = hexSymbols[b >> 4];
            buf[3 + i * 2] = hexSymbols[b & 0x0f];
            unchecked {
                ++i;
            }
        }
        return string(buf);
    }
}
