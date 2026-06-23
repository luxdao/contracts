// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IThinkingGovernor} from "./interfaces/IThinkingGovernor.sol";
import {Sortition} from "./Sortition.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title ThinkingParameters
 * @author Hanzo AI Inc / Zoo Labs Foundation
 * @notice Value-deciding governance: the chain THINKS a parameter into existence.
 * Where {ThinkingGovernor} decides a categorical POLICY (yes/no on a pre-baked
 * change), this decides a continuous VALUE: each node operator's LLM reasons about
 * a question and \emph{proposes a number} within a declared range; the chain
 * settles to the \emph{median} of a quorum of proposals and makes it the live knob
 * value. This is "knobs/params based on the LLM of the node operator" taken
 * literally --- the model picks the value, the network aggregates cognition into a
 * decision, and the decision takes effect (the loop closes: anything, including the
 * next round or the governor, can read {valueOf}).
 *
 * @dev Orthogonal + composable (Rich Hickey): it holds no operator set of its own
 * --- eligibility is READ from the canonical {ThinkingGovernor} (one bonded
 * operator set, two decision primitives). The aggregator is the \emph{median},
 * deliberately UNWEIGHTED: one operator, one proposal. This is the
 * equal-vote / equal-weight regime the soundness review identifies as the safe one
 * (a stake/reputation-weighted statistic lets a sub-threshold whale capture the
 * outcome; the median over equal proposals is Byzantine-robust to any minority
 * < 50%). Each proposal is a \emph{signed judgment} (the paper's Mode 2): the
 * operator signs (roundId, spec, value, confidence, evidence) and the digest binds
 * {block.chainid} + {address(this)} from day one (EIP-712-style domain separation),
 * so a proposal can never be replayed across chains or contract instances. The
 * rationale behind a value lives off-chain, committed by {evidenceHash}, so the
 * dashboard can show not just WHAT each node proposed but the hash that pins WHY.
 */
contract ThinkingParameters {
    using ECDSA for bytes32;

    /// @notice Domain tag separating this signature purpose from all others.
    bytes32 public constant PROPOSAL_DOMAIN = keccak256("hanzo/thinking-parameters/proposal/v1");

    /// @notice Minimum voting window so a round cannot be opened-and-settled in a
    /// flash, locking honest sampled operators out (permissionless liveness).
    uint64 public constant MIN_WINDOW = 1 hours;

    IThinkingGovernor public immutable governor; // the canonical bonded-operator set
    address public immutable treasury; //         sink for the non-refundable (sunk) fees
    uint256 public immutable openFee; //          non-refundable, charged at open() (anti-spam)
    uint256 public immutable proposalFee; //      non-refundable per proposal (sunk Sybil cost)
    uint256 public treasuryFees; //               accrued sunk fees, withdrawable to treasury

    enum Status {
        None, //    0
        Open, //    1 accepting proposals
        Settled, // 2 median computed, knob value set
        Failed //   3 deadline passed without quorum
    }

    struct Round {
        bytes32 modelSpecHash; // model all proposals are bound to
        bytes32 promptHash; //   hash of the value question (audit)
        string knobKey; //       the parameter being decided
        uint256 lo; //           inclusive lower bound a proposal must lie in
        uint256 hi; //           inclusive upper bound
        uint8 n; //              committee size (max distinct proposers)
        uint8 threshold; //      min proposals required to settle (quorum)
        uint64 openedAt;
        uint64 deadline; //      openedAt + window; settle gated until reached (unless full)
        address opener;
        Status status;
        uint8 submissionCount; // proposals submitted so far (<= n)
        uint256 canonicalValue; // the decided value (median), set on settle
    }

    struct Proposal {
        address operator;
        uint256 value; //        the LLM's proposed value, in [lo, hi]
        uint16 confidenceBucket; // confidence (bps), for visibility
        bytes32 evidenceHash; // commits the off-chain rationale (the "why")
        uint64 submittedAt;
    }

    Round[] private _rounds;
    mapping(uint256 => Proposal[]) private _proposals; // roundId => proposals
    mapping(uint256 => mapping(address => bool)) private _proposed; // one per operator per round
    mapping(bytes32 => mapping(bytes32 => uint256)) private _value; // spec => key => live value
    mapping(bytes32 => mapping(bytes32 => bool)) private _valueSet; // spec => key => decided?
    // sortition metadata, kept OUT of the Round struct so its ABI (dashboard/scripts) is stable
    mapping(uint256 => uint64) private _openBlock; //  round => block it opened in
    mapping(uint256 => uint256) private _population; // round => operator count at open (sortition population)
    mapping(uint256 => bytes32) private _seed; //      round => committee seed (blockhash(openBlock), cached)

    event RoundOpened(
        uint256 indexed roundId, bytes32 indexed modelSpecHash, string knobKey, uint256 lo, uint256 hi, uint8 n, uint8 threshold, address opener
    );
    event ProposalSubmitted(uint256 indexed roundId, address indexed operator, uint256 value, uint16 confidenceBucket, bytes32 evidenceHash);
    event ParameterDecided(uint256 indexed roundId, bytes32 indexed modelSpecHash, string knobKey, uint256 value, uint8 proposals);
    event RoundFailed(uint256 indexed roundId, uint8 submissionCount, uint8 threshold);

    event FeesWithdrawn(address indexed treasury, uint256 amount);

    error NotEligibleOperator(address who);
    error RoundNotOpen(uint256 roundId);
    error AlreadyProposed(uint256 roundId, address operator);
    error ValueOutOfRange(uint256 value, uint256 lo, uint256 hi);
    error BadRange(uint256 lo, uint256 hi);
    error BadCommittee(uint8 n, uint8 threshold);
    error SignerMismatch(address recovered, address sender);
    error VotingOpen(uint256 roundId); // settle attempted before deadline and not full
    error UnknownRound(uint256 roundId);
    error WindowTooShort(uint64 window); //       below MIN_WINDOW
    error WrongFee(uint256 sent, uint256 want); // open/proposal fee mismatch
    error SeedNotReady(uint256 roundId); //       must submit in a block after open (seed = blockhash(openBlock))
    error NotSampled(address who); //             not in the sortition-sampled committee for this round
    error NotRegisteredBeforeOpen(address who); // registered after the round opened (cannot join its committee)
    error CommitteeFull(uint256 roundId); //      already n proposals

    constructor(IThinkingGovernor governor_, address treasury_, uint256 openFee_, uint256 proposalFee_) {
        require(treasury_ != address(0) || (openFee_ == 0 && proposalFee_ == 0), "fees need treasury");
        governor = governor_;
        treasury = treasury_;
        openFee = openFee_;
        proposalFee = proposalFee_;
    }

    // ----------------------------------------------------------------------
    // open
    // ----------------------------------------------------------------------

    /// @notice Open a value-decision round for `knobKey`: operators will propose a
    /// number in [lo, hi]. Permissionless to open (anyone may pose a question);
    /// only eligible operators may propose. `threshold` is the quorum of proposals
    /// needed to settle; a strict majority (>= n/2 + 1) is required so the median is
    /// taken over a true majority of the committee.
    function open(
        bytes32 modelSpecHash,
        bytes32 promptHash,
        string calldata knobKey,
        uint256 lo,
        uint256 hi,
        uint8 n,
        uint8 threshold,
        uint64 window
    ) external payable returns (uint256 roundId) {
        if (lo > hi) revert BadRange(lo, hi);
        if (n == 0 || threshold == 0 || threshold > n || threshold < n / 2 + 1) revert BadCommittee(n, threshold);
        if (window < MIN_WINDOW) revert WindowTooShort(window); // no flash open-and-settle lockout
        if (msg.value != openFee) revert WrongFee(msg.value, openFee); // non-refundable anti-spam
        if (openFee != 0) treasuryFees += openFee;
        roundId = _rounds.length;
        // Snapshot the sortition population (operators bonded as of now) and the open
        // block; the committee seed is blockhash(openBlock), unknown until the next
        // block, so neither the opener nor operators can grind their selection.
        _openBlock[roundId] = uint64(block.number);
        _population[roundId] = governor.operatorCount();
        _rounds.push(
            Round({
                modelSpecHash: modelSpecHash,
                promptHash: promptHash,
                knobKey: knobKey,
                lo: lo,
                hi: hi,
                n: n,
                threshold: threshold,
                openedAt: uint64(block.timestamp),
                deadline: uint64(block.timestamp) + window,
                opener: msg.sender,
                status: Status.Open,
                submissionCount: 0,
                canonicalValue: 0
            })
        );
        emit RoundOpened(roundId, modelSpecHash, knobKey, lo, hi, n, threshold, msg.sender);
    }

    /// @notice Send accrued non-refundable fees to the treasury (pull-payment).
    function withdrawFees() external {
        uint256 amount = treasuryFees;
        treasuryFees = 0;
        if (amount != 0) {
            (bool ok,) = payable(treasury).call{value: amount}("");
            require(ok, "fee transfer failed");
            emit FeesWithdrawn(treasury, amount);
        }
    }

    // ----------------------------------------------------------------------
    // propose (a signed judgment carrying the LLM's chosen value)
    // ----------------------------------------------------------------------

    /// @notice The digest an operator signs to propose `value`. Binds the chain and
    /// this contract instance (domain separation) so a proposal can never be
    /// replayed on another chain or another ThinkingParameters deployment.
    function proposalDigest(
        uint256 roundId,
        address operator,
        bytes32 modelSpecHash,
        uint256 value,
        uint16 confidenceBucket,
        bytes32 evidenceHash
    ) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                PROPOSAL_DOMAIN, block.chainid, address(this), roundId, modelSpecHash, value, confidenceBucket, evidenceHash, operator
            )
        );
    }

    /// @notice Submit the operator's LLM-chosen value for `roundId`. Caller must be
    /// a bonded, eligible operator (read from the canonical governor); the signature
    /// must recover to the caller; the value must lie in [lo, hi]; one proposal per
    /// operator. Reaching `n` proposals does not auto-settle (settle is explicit).
    function submitProposal(
        uint256 roundId,
        uint256 value,
        uint16 confidenceBucket,
        bytes32 evidenceHash,
        bytes calldata signature
    ) external payable {
        Round storage r = _rounds[roundId];
        if (r.status != Status.Open) revert RoundNotOpen(roundId);
        if (block.timestamp > r.deadline) revert RoundNotOpen(roundId);
        if (r.submissionCount >= r.n) revert CommitteeFull(roundId); // bound the committee to n
        if (msg.value != proposalFee) revert WrongFee(msg.value, proposalFee); // non-refundable sunk Sybil cost
        if (!_eligible(msg.sender)) revert NotEligibleOperator(msg.sender);
        if (_proposed[roundId][msg.sender]) revert AlreadyProposed(roundId, msg.sender);
        if (value < r.lo || value > r.hi) revert ValueOutOfRange(value, r.lo, r.hi);

        // The proposal is a SIGNED judgment: the signature over the domain-separated
        // digest must recover to the caller (no relay of another operator's value).
        bytes32 digest = proposalDigest(roundId, msg.sender, r.modelSpecHash, value, confidenceBucket, evidenceHash);
        address recovered = digest.recover(signature);
        if (recovered != msg.sender) revert SignerMismatch(recovered, msg.sender);

        // PERMISSIONLESS COMMITTEE: the proposer must be (a) registered BEFORE this
        // round opened and (b) sampled by sortition for this round. Sortition makes
        // committee share track population share, so capturing the median requires a
        // MAJORITY OF THE WHOLE OPERATOR POPULATION (not just spamming proposals);
        // the sunk proposalFee + the governor's bond make that majority costly.
        uint64 ob = _openBlock[roundId];
        uint64 since = governor.operatorSince(msg.sender);
        if (since == 0 || since > ob) revert NotRegisteredBeforeOpen(msg.sender);
        bytes32 seed = _seed[roundId];
        if (seed == bytes32(0)) {
            // cache the seed = blockhash(openBlock); available only from openBlock+1
            // .. openBlock+256, so the first proposal must land in that window.
            if (block.number <= ob) revert SeedNotReady(roundId);
            seed = blockhash(ob);
            if (seed == bytes32(0)) revert SeedNotReady(roundId); // window elapsed (>256 blocks)
            _seed[roundId] = seed;
        }
        if (!Sortition.isSelected(seed, msg.sender, _population[roundId], r.n)) revert NotSampled(msg.sender);

        if (proposalFee != 0) treasuryFees += proposalFee;
        _proposed[roundId][msg.sender] = true;
        _proposals[roundId].push(
            Proposal({operator: msg.sender, value: value, confidenceBucket: confidenceBucket, evidenceHash: evidenceHash, submittedAt: uint64(block.timestamp)})
        );
        r.submissionCount += 1;
        emit ProposalSubmitted(roundId, msg.sender, value, confidenceBucket, evidenceHash);
    }

    // ----------------------------------------------------------------------
    // settle (median of the quorum becomes the live value)
    // ----------------------------------------------------------------------

    /// @notice Settle `roundId`: if at least `threshold` proposals are in, the live
    /// value of the knob becomes the MEDIAN of all submitted proposals (Byzantine-
    /// robust to any minority < 50%); otherwise the round Fails. Callable once the
    /// deadline passes, or earlier if the committee is full (submissionCount == n).
    function settle(uint256 roundId) external returns (uint256 value, bool decided) {
        Round storage r = _rounds[roundId];
        if (r.status != Status.Open) revert RoundNotOpen(roundId);
        if (block.timestamp <= r.deadline && r.submissionCount < r.n) revert VotingOpen(roundId);

        if (r.submissionCount < r.threshold) {
            r.status = Status.Failed;
            emit RoundFailed(roundId, r.submissionCount, r.threshold);
            return (0, false);
        }

        value = _median(roundId);
        r.canonicalValue = value;
        r.status = Status.Settled;
        bytes32 kk = keccak256(bytes(r.knobKey));
        _value[r.modelSpecHash][kk] = value;
        _valueSet[r.modelSpecHash][kk] = true;
        emit ParameterDecided(roundId, r.modelSpecHash, r.knobKey, value, r.submissionCount);
        return (value, true);
    }

    /// @dev Median of a round's proposed values. Insertion-sorts a memory copy
    /// (committees are small, n is a uint8); for an even count returns the lower-mid
    /// average (floor) so the result is deterministic and in-range.
    function _median(uint256 roundId) private view returns (uint256) {
        Proposal[] storage ps = _proposals[roundId];
        uint256 m = ps.length;
        uint256[] memory v = new uint256[](m);
        for (uint256 i = 0; i < m; ++i) v[i] = ps[i].value;
        for (uint256 i = 1; i < m; ++i) {
            uint256 key = v[i];
            uint256 j = i;
            while (j > 0 && v[j - 1] > key) {
                v[j] = v[j - 1];
                unchecked {
                    --j;
                }
            }
            v[j] = key;
        }
        if (m % 2 == 1) return v[m / 2];
        // even: average the two central values (floor); both lie in [lo,hi] so the mean does too
        return (v[m / 2 - 1] + v[m / 2]) / 2;
    }

    // ----------------------------------------------------------------------
    // views — the visibility surface
    // ----------------------------------------------------------------------

    /// @notice The live, decided value of a knob (the loop-closing read), and
    /// whether it has been decided at least once.
    function valueOf(bytes32 modelSpecHash, string calldata knobKey) external view returns (uint256 value, bool decided) {
        bytes32 kk = keccak256(bytes(knobKey));
        return (_value[modelSpecHash][kk], _valueSet[modelSpecHash][kk]);
    }

    function getRound(uint256 roundId) external view returns (Round memory) {
        if (roundId >= _rounds.length) revert UnknownRound(roundId);
        return _rounds[roundId];
    }

    function getProposals(uint256 roundId) external view returns (Proposal[] memory) {
        return _proposals[roundId];
    }

    function roundCount() external view returns (uint256) {
        return _rounds.length;
    }

    /// @notice The sortition context of a round: the block it opened in, the
    /// operator population sampled from, and the committee seed (0 until the first
    /// proposal caches blockhash(openBlock)). Lets the dashboard show how the
    /// committee was drawn.
    function committee(uint256 roundId) external view returns (uint64 openBlock, uint256 population, bytes32 seed) {
        return (_openBlock[roundId], _population[roundId], _seed[roundId]);
    }

    /// @notice Whether `who` is in the sampled committee for `roundId` (once seeded).
    /// An operator self-checks this to know if it should propose.
    function isSampled(uint256 roundId, address who) external view returns (bool) {
        bytes32 seed = _seed[roundId];
        if (seed == bytes32(0)) return false;
        uint64 since = governor.operatorSince(who);
        if (since == 0 || since > _openBlock[roundId]) return false;
        return Sortition.isSelected(seed, who, _population[roundId], _rounds[roundId].n);
    }

    function _eligible(address who) internal view returns (bool) {
        return governor.isOperator(who) && governor.bondOf(who) >= governor.minBond();
    }
}
