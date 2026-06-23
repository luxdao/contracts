// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IThinkingGovernor} from "./interfaces/IThinkingGovernor.sol";
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

    IThinkingGovernor public immutable governor; // the canonical bonded-operator set

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

    event RoundOpened(
        uint256 indexed roundId, bytes32 indexed modelSpecHash, string knobKey, uint256 lo, uint256 hi, uint8 n, uint8 threshold, address opener
    );
    event ProposalSubmitted(uint256 indexed roundId, address indexed operator, uint256 value, uint16 confidenceBucket, bytes32 evidenceHash);
    event ParameterDecided(uint256 indexed roundId, bytes32 indexed modelSpecHash, string knobKey, uint256 value, uint8 proposals);
    event RoundFailed(uint256 indexed roundId, uint8 submissionCount, uint8 threshold);

    error NotEligibleOperator(address who);
    error RoundNotOpen(uint256 roundId);
    error AlreadyProposed(uint256 roundId, address operator);
    error ValueOutOfRange(uint256 value, uint256 lo, uint256 hi);
    error BadRange(uint256 lo, uint256 hi);
    error BadCommittee(uint8 n, uint8 threshold);
    error SignerMismatch(address recovered, address sender);
    error VotingOpen(uint256 roundId); // settle attempted before deadline and not full
    error UnknownRound(uint256 roundId);

    constructor(IThinkingGovernor governor_) {
        governor = governor_;
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
    ) external returns (uint256 roundId) {
        if (lo > hi) revert BadRange(lo, hi);
        if (n == 0 || threshold == 0 || threshold > n || threshold < n / 2 + 1) revert BadCommittee(n, threshold);
        roundId = _rounds.length;
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
    ) external {
        Round storage r = _rounds[roundId];
        if (r.status != Status.Open) revert RoundNotOpen(roundId);
        if (block.timestamp > r.deadline) revert RoundNotOpen(roundId);
        if (!_eligible(msg.sender)) revert NotEligibleOperator(msg.sender);
        if (_proposed[roundId][msg.sender]) revert AlreadyProposed(roundId, msg.sender);
        if (value < r.lo || value > r.hi) revert ValueOutOfRange(value, r.lo, r.hi);

        bytes32 digest = proposalDigest(roundId, msg.sender, r.modelSpecHash, value, confidenceBucket, evidenceHash);
        address recovered = digest.recover(signature);
        if (recovered != msg.sender) revert SignerMismatch(recovered, msg.sender);

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

    function _eligible(address who) internal view returns (bool) {
        return governor.isOperator(who) && governor.bondOf(who) >= governor.minBond();
    }
}
