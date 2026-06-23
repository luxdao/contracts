// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

/**
 * @title IThinkingGovernor
 * @author Hanzo AI Inc / Lux Network
 * @notice On-chain governance driven by operator-LLM consensus.
 *
 * @dev The "Thinking Governor" lets a set of bonded node-operator LLMs answer a
 * structured governance question and reach an on-chain quorum. Each operator runs
 * an LLM that emits a structured verdict {vote, confidence}; the operator
 * secp256k1-signs the CANONICAL consensus preimage and submits it. The contract
 * verifies the signature with `ecrecover` over the SAME preimage the off-chain
 * operator hashes, tallies verdicts by the consensus key {vote, confidenceBucket},
 * and — if a strict-majority group forms — records the canonical decision on-chain
 * and sets a governed knob. The whole decision is visible on-chain (events +
 * queryable state) so a human, the DAO, or {ModuleGovernorV1} can read what the
 * thinking validators decided.
 *
 * CANONICAL PREIMAGE (byte-for-byte identical to the Go operator in
 * hanzo-evm/operator/canonical/governance.go):
 *
 *   preimage     = modelSpecHash(32) || voteByte(1) || u16be(confidenceBucket)(2)   // 35 bytes
 *   consensusHash = keccak256(preimage)
 *
 * In Solidity this is exactly:
 *   keccak256(abi.encodePacked(bytes32 modelSpecHash, uint8 vote, uint16 confidenceBucket))
 * because abi.encodePacked lays out bytes32 (32) ++ uint8 (1) ++ uint16
 * big-endian (2) with no padding — matching the Go concatenation exactly.
 *
 * The free-form LLM `rationale` is DELIBERATELY excluded from consensus (it is
 * hash-addressed audit evidence, never byte-identical across operators). Only
 * {vote, confidenceBucket} bound to modelSpecHash gate the quorum.
 *
 * @custom:security-contact security@lux.network
 */
interface IThinkingGovernor {
    // ======================================================================
    // ENUMS
    // ======================================================================

    /// @notice Categorical governance verdict. Byte values MUST match the Go
    /// operator's Vote type: yes=1, no=2, abstain=3. 0 is reserved/invalid so a
    /// malformed zero verdict can never collide with a real one. Optional
    /// extensions delay=4, unsafe=5 mirror the documented Go extension points.
    enum Vote {
        Invalid, // 0 — never a valid vote
        Yes, //     1
        No, //      2
        Abstain, // 3
        Delay, //   4 (extension)
        Unsafe //   5 (extension)
    }

    /// @notice Lifecycle of a thinking task.
    enum Status {
        None, //     0 — task does not exist
        Open, //     1 — accepting verdicts
        Settled, //  2 — quorum reached, canonical decision recorded
        Failed //    3 — settled with no quorum
    }

    // ======================================================================
    // STRUCTS
    // ======================================================================

    /// @notice A thinking task: a governance question put to operator-LLM quorum.
    struct Thought {
        bytes32 modelSpecHash; // the model spec all verdicts are bound to
        bytes32 promptHash; // hash of the governance question (audit)
        bytes32 evidenceHash; // hash of the question's supporting evidence (audit)
        uint8 n; // committee size (max distinct operators that may submit)
        uint8 threshold; // strict-majority quorum (>= n/2 + 1)
        uint64 openedAt; // block timestamp the task opened
        uint64 deadline; // openedAt + votingWindow; settle gated until reached (unless full)
        address opener; // who opened the task
        Status status; // lifecycle
        uint8 submissionCount; // verdicts submitted so far (<= n)
        string knobKey; // governed parameter this thought decides
        // --- filled on settle ---
        Vote canonicalVote; // the winning vote (Invalid until settled YES-group)
        uint16 canonicalBucket; // the winning confidence bucket (bps)
        uint8 agreeCount; // size of the winning group
        bytes32 evidenceRoot; // keccak of concatenated agreeing evidence hashes
        // --- commit-reveal (zero/false for the cleartext-submit path) ---
        bool commitReveal; // true ⇒ verdicts MUST go through commit→reveal, cleartext submit barred
        uint64 commitDeadline; // last block timestamp a commit is accepted (commit window close)
        uint64 revealDeadline; // last block timestamp a reveal is accepted (== deadline for CR tasks)
    }

    /// @notice One operator's verdict on a task.
    struct Verdict {
        address operator; // recovered signer == msg.sender
        Vote vote;
        uint16 confidenceBucket; // snapped bps (multiple of 1000), 0..10000
        bytes32 evidenceHash; // operator's hash-addressed rationale/evidence
        uint64 submittedAt;
    }

    // ======================================================================
    // EVENTS
    // ======================================================================

    event OperatorRegistered(address indexed operator, uint256 bond);
    event OperatorDeregisterRequested(address indexed operator, uint64 withdrawableAt);
    event BondWithdrawn(address indexed operator, uint256 amount);

    event ThoughtOpened(
        uint256 indexed taskId,
        bytes32 indexed modelSpecHash,
        bytes32 promptHash,
        bytes32 evidenceHash,
        uint8 n,
        uint8 threshold,
        string knobKey,
        address opener
    );

    event VerdictSubmitted(
        uint256 indexed taskId,
        address indexed operator,
        uint8 vote,
        uint16 confidenceBucket,
        bytes32 evidenceHash,
        bytes32 consensusHash
    );

    /// @notice The canonical on-chain governance decision. This is the load-bearing
    /// "the blockchain thought and decided" record the DAO/frontend reads.
    event ThoughtSettled(
        uint256 indexed taskId,
        uint8 indexed vote,
        uint16 confidenceBucket,
        uint8 agreeCount,
        uint8 submissionCount,
        bytes32 evidenceRoot,
        address[] agreeingOperators
    );

    /// @notice Emitted alongside settlement so the dissent/confidence distribution
    /// is visible on-chain even when the winning group is not unanimous.
    event VerdictDistribution(uint256 indexed taskId, bytes32[] consensusKeys, uint8[] counts);

    /// @notice A governed knob was set by a YES-quorum decision. The knob is scoped
    /// to (modelSpecHash, key): a decision under one spec can NEVER overwrite a knob
    /// governed by another spec. Mirrors the {KeyValuePairsV1.ValueUpdated} shape so
    /// the SAME subgraph/indexer that reads DAO metadata also surfaces decisions.
    event KnobSet(bytes32 indexed modelSpecHash, string key, bytes32 value, uint256 indexed taskId);

    /// @notice Reward credited to an agreeing operator (pull-payment).
    event RewardAccrued(address indexed operator, uint256 amount, uint256 indexed taskId);

    /// @notice An operator sealed a commit on a commit-reveal task. The commit is the only datum
    /// public during the commit window — and it is operator-bound, so a peer copying these bytes
    /// cannot reveal them (the reveal recomputes against the revealer's own address).
    event VerdictCommitted(uint256 indexed taskId, address indexed operator, bytes32 commit);

    // ======================================================================
    // ERRORS
    // ======================================================================

    error NotBonded(address operator);
    error AlreadyRegistered(address operator);
    error BondTooLow(uint256 sent, uint256 required);
    error DeregisterCooldownActive(uint64 withdrawableAt);
    error NoBondToWithdraw();
    error NothingToWithdraw();

    error BadThreshold(uint8 n, uint8 threshold);
    error BadCommitteeSize(uint8 n);
    error EmptyKnobKey();
    error ZeroModelSpec();
    error BadVotingWindow(uint64 votingWindow);
    error WrongOpenPayment(uint256 sent, uint256 required);

    error UnknownTask(uint256 taskId);
    error TaskNotOpen(uint256 taskId);
    error TaskFull(uint256 taskId);
    error AlreadyVoted(uint256 taskId, address operator);
    error SignerMismatch(address recovered, address sender);
    error InvalidVote(uint8 vote);
    error BadConfidenceBucket(uint16 bucket);
    error AlreadySettled(uint256 taskId);
    error OpenerCannotVote(uint256 taskId, address opener);
    error OpenerIsTreasury(address opener);
    error SettleTooEarly(uint256 taskId, uint64 deadline);

    // ---- commit-reveal ----
    error NotCommitReveal(uint256 taskId); // commit/reveal called on a cleartext task
    error UseCommitReveal(uint256 taskId); // cleartext submitVerdict called on a CR task
    error BadCommitRevealWindow(uint64 commitWindow, uint64 revealWindow);
    error EmptyCommit();
    error CommitClosed(uint256 taskId); // commit after the commit window closed
    error AlreadyCommitted(uint256 taskId, address operator);
    error RevealNotOpen(uint256 taskId); // reveal before the commit window closed (the anti-copy gate)
    error RevealClosed(uint256 taskId); // reveal after the reveal window closed
    error NotCommitted(uint256 taskId, address operator); // reveal with no prior commit
    error CommitMismatch(uint256 taskId, address operator); // reveal does not recompute to the commit

    // ======================================================================
    // OPERATOR REGISTRY
    // ======================================================================

    function registerOperator() external payable;
    function deregister() external;
    function withdrawBond() external;

    // ======================================================================
    // THINKING TASKS
    // ======================================================================

    function openThought(
        bytes32 modelSpecHash,
        bytes32 promptHash,
        bytes32 evidenceHash,
        uint8 n,
        uint8 threshold,
        uint64 votingWindow,
        string calldata knobKey
    ) external payable returns (uint256 taskId);

    function submitVerdict(
        uint256 taskId,
        uint8 vote,
        uint16 confidenceBucket,
        bytes32 evidenceHash,
        bytes calldata sig
    ) external;

    /// @notice Open a COMMIT-REVEAL thought: operators must seal a commit during the commit
    /// window, then reveal strictly after it closes. Prevents the value-copy attack the
    /// cleartext {submitVerdict} path is open to (an operator reading a peer's cleartext verdict
    /// and copying it). Mirrors the A-Chain two-phase commit (chains/aivm/commit_reveal.go):
    /// reveal opens only after commit closes, and the commit binds the operator so a copied
    /// commit cannot be revealed by anyone else. `deadline` is set to the reveal close, so
    /// {settle} waits for the full commit+reveal duration.
    function openThoughtCommitReveal(
        bytes32 modelSpecHash,
        bytes32 promptHash,
        bytes32 evidenceHash,
        uint8 n,
        uint8 threshold,
        uint64 commitWindow,
        uint64 revealWindow,
        string calldata knobKey
    ) external payable returns (uint256 taskId);

    /// @notice Seal a commit for a commit-reveal task during the commit window. `commit` MUST be
    /// {commitDigest}(taskId, msg.sender, vote, bucket, evidenceHash, nonce). One per operator.
    function commitVerdict(uint256 taskId, bytes32 commit) external;

    /// @notice Reveal a previously-committed verdict, strictly after the commit window closes.
    /// The contract recomputes the operator-bound commit and rejects a mismatch; no signature is
    /// needed because the operator-bound commit IS the authentication. Records the verdict for the
    /// tally exactly as {submitVerdict} would.
    function revealVerdict(
        uint256 taskId,
        uint8 vote,
        uint16 confidenceBucket,
        bytes32 evidenceHash,
        bytes32 nonce
    ) external;

    /// @notice The operator-bound commit an operator seals (and the contract recomputes at
    /// reveal). Domain-separated and bound to this deployment + task + operator, so a commit is
    /// non-transferable across operators, tasks, instances, or chains.
    function commitDigest(
        uint256 taskId,
        address operator,
        uint8 vote,
        uint16 confidenceBucket,
        bytes32 evidenceHash,
        bytes32 nonce
    ) external view returns (bytes32);

    function settle(uint256 taskId) external;

    function claimReward() external;

    // ======================================================================
    // CANONICAL PREIMAGE (parity surface)
    // ======================================================================

    /// @notice The canonical consensus preimage bytes (35) — exactly what the Go
    /// operator hashes. Exposed so off-chain tooling can assert byte-parity.
    function consensusPreimage(
        bytes32 modelSpecHash,
        uint8 vote,
        uint16 confidenceBucket
    ) external pure returns (bytes memory);

    /// @notice keccak256(consensusPreimage(...)) — the consensus hash that gates the
    /// quorum tally. Identical to canonical.OutputHashGovernance on the Go side. This
    /// is the value compared across operators to form agreement; it is NOT what an
    /// operator signs at submission (see {verdictDigest}).
    function consensusHash(
        bytes32 modelSpecHash,
        uint8 vote,
        uint16 confidenceBucket
    ) external pure returns (bytes32);

    /// @notice The digest an operator SIGNS to submit a verdict. Domain-separated
    /// and bound to the EXACT task, operator, consensus fields, and evidence — the
    /// on-chain mirror of the Go operator's reveal digest
    /// ("hanzo/thinking-governor/verdict/v1"). Binding taskId makes a verdict
    /// non-transferable across tasks (even tasks sharing a modelSpecHash); binding
    /// operator + evidenceHash authenticates who submitted and which evidence they
    /// attest, closing the unsigned-evidence gap while leaving the consensus hash
    /// (and thus Go quorum parity) untouched.
    function verdictDigest(
        uint256 taskId,
        address operator,
        bytes32 modelSpecHash,
        uint8 vote,
        uint16 confidenceBucket,
        bytes32 evidenceHash
    ) external view returns (bytes32);

    // ======================================================================
    // VIEWS
    // ======================================================================

    function getThought(uint256 taskId) external view returns (Thought memory);

    function getVerdict(uint256 taskId, address operator) external view returns (Verdict memory);

    function getVerdicts(uint256 taskId) external view returns (Verdict[] memory);

    /// @notice The on-chain canonical decision for a settled task.
    /// @return settled true iff the task reached quorum (Status.Settled).
    /// @return vote the winning vote.
    /// @return confidenceBucket the winning confidence bucket (bps).
    /// @return agreeCount size of the agreeing group.
    function getCanonicalVerdict(
        uint256 taskId
    ) external view returns (bool settled, Vote vote, uint16 confidenceBucket, uint8 agreeCount);

    /// @notice Read a governed knob set by a thinking-validator decision. Knobs are
    /// scoped to (modelSpecHash, key): the consumer MUST supply the spec that governs
    /// its parameter, so an attacker opening a task under a different spec can never
    /// overwrite the value the consumer reads.
    function getKnob(bytes32 modelSpecHash, string calldata key) external view returns (bytes32);

    function isOperator(address who) external view returns (bool);

    function bondOf(address who) external view returns (uint256);

    /// @notice Count of currently-bonded operators — the sortition population.
    function operatorCount() external view returns (uint256);

    /// @notice Block number an operator first bonded (0 if never) — sortition
    /// eligibility uses it to require registration BEFORE a round opened.
    function operatorSince(address who) external view returns (uint64);

    function rewardOf(address who) external view returns (uint256);

    function taskCount() external view returns (uint256);

    function minBond() external view returns (uint256);

    /// @notice Non-refundable fee required to open a thought (anti-sybil/anti-spam).
    function openFee() external view returns (uint256);

    /// @notice Treasury that accrues open fees (pull-payment).
    function treasury() external view returns (address);
}
