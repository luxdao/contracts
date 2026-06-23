// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IThinkingGovernor} from "./interfaces/IThinkingGovernor.sol";
import {IComputeVerifier} from "./interfaces/IComputeVerifier.sol";
import {ComputeProof, ComputeProofLib} from "./ComputeProofLib.sol";

interface IAICoinMintableG {
    function mintSubsidy(address to, uint256 amount) external;
    function emissionAllowance() external view returns (uint256);
}

interface IComputeProfileView {
    function requiredProofType(uint8 tier) external view returns (uint8);
}

/// @title ThinkingMiner — mine AICoin by REACHING CONSENSUS *backed by proven compute*.
/// @notice The governance counterpart to AICoinMiner. A ThinkingGovernor quorum proves a group
/// of operators AGREED; it does NOT, by itself, prove any of them ran a model — a vote is ~1
/// bit, so "guess the modal YES/NO" used to mint (the C2 hole). This contract closes that: a
/// winning validator is paid ONLY if it has also submitted a valid {ComputeProof} binding the
/// settled thought's (taskId, modelSpecHash, promptHash) to THAT validator's own outputHash,
/// at the proof strength the task's tier requires ({ComputeProfile}). Consensus says "they
/// agreed"; the compute proof says "they computed". Both, or no mint.
///
/// THREAT MODEL (this contract)
///   Assets:      the AICoin subsidy, the shared halving cap.
///   Adversaries: coin-flip guessers (C2), replayers, cross-task / cross-operator proof
///                splicers, callers trying to redirect rewards.
///   Surface:     submitComputeProof, mineSettledThought.
///
/// DEFENSE
///   1. proof gate per winning validator (binding via ComputeProofLib, strength via
///      ComputeProfile, witness via ComputeVerifier) — a guess with no proof earns nothing.
///   2. operator-bound proof: the binding names the operator, recomputed from the thought, so a
///      proof can only count for the validator it was made for (no splicing a peer's proof).
///   3. proven-winners < threshold → mint NOTHING (a sub-quorum of *proven* work does not pay).
///   4. CEI + one-shot replay guard (minedThought) preserved from the original.
///   5. rewards go to the proven winners read from on-chain verdicts, never the caller.
///
/// PERMISSIVE DEFAULT: when the tier's requiredProofType is 0 (the {ComputeProfile} default),
/// the proof gate is OFF and behavior is the original consensus-only mint — so a deployment
/// that has not opted a tier into compute proofs is unchanged. A deployment that wants the C2
/// fix sets its tier's required proofType (and wires the verifier).
///
/// OPTIMISTIC ECONOMIC INVARIANT (proofType 3): an optimistic proof is accepted while its
/// challenge window is OPEN and un-challenged (that is the optimistic model — mint now, slash on
/// later fraud). For this to be SOUND against a profit-motivated liar, a deployment minting under
/// proofType 3 MUST satisfy ONE of:
///   (a) the optimistic backend's per-proof bond >= the max subsidy a single proof can unlock
///       (so a fraudulent mint is never net-profitable — the slash exceeds the take), OR
///   (b) gate on {OptimisticEvidence.finalized} instead (mint only AFTER the window closes with
///       no fraud) — pessimistic, slower, but unconditionally sound.
/// proofTypes 1 (CC-TEE), 2 (zkML), 4 (M-of-N TEE) are synchronously valid (no window), so they
/// carry no such constraint. This contract uses the optimistic (accept-while-pending) path; the
/// bond>=value choice is a governance parameter, not a code constant.
contract ThinkingMiner {
    using ComputeProofLib for *;

    IThinkingGovernor public immutable governor;
    IAICoinMintableG public immutable coin;

    /// @notice The compute-proof gate. address(0) ⇒ proof enforcement entirely disabled (the
    /// pre-enforcement deployment). When set, the tier policy decides whether a given task needs
    /// a proof.
    IComputeVerifier public immutable verifier;

    /// @notice The tier→proof policy. address(0) is treated as "all tiers permissive".
    IComputeProfileView public immutable profile;

    /// @notice The tier this miner mints at. Governs which {ComputeProfile} requirement applies
    /// to every thought it settles. Default 0 ⇒ permissive unless governance sets the tier and
    /// raises its bar. Admin-settable.
    uint8 public tier;

    address public admin;

    /// @notice Total subsidy minted per settled thought, split equally among the PROVEN winning
    /// group. Governable; clamped to the vested halving allowance at mint time.
    uint256 public rewardPerThought;

    /// @notice taskId => already mined (one subsidy per settled thought; the Governor binds one
    /// settlement per task, this is the C-side replay guard).
    mapping(uint256 => bool) public minedThought;

    /// @notice taskId => operator => a valid compute proof has been accepted for this operator's
    /// work on this task. Set by {submitComputeProof}; read at mine time. The bridge between
    /// "agreed" (governor) and "computed" (proof).
    mapping(uint256 => mapping(address => bool)) public proven;

    event ComputeProofAccepted(uint256 indexed taskId, address indexed operator, bytes32 reportData, uint8 proofType);
    event ThoughtMined(uint256 indexed taskId, uint8 canonicalVote, uint256 winners, uint256 totalMinted);
    event ValidatorRewarded(uint256 indexed taskId, address indexed operator, uint256 amount);
    event RewardSet(uint256 amount);
    event TierSet(uint8 tier);
    event AdminTransferred(address indexed from, address indexed to);

    error NotAdmin();
    error AlreadyMined(uint256 taskId);
    error NotSettled(uint256 taskId);
    error NoQuorum(uint256 taskId);
    error NoProvenQuorum(uint256 taskId, uint256 proven, uint8 threshold);
    error NothingToMint();
    error ProofGateUnavailable();
    error InvalidComputeProof(uint256 taskId, address operator);
    error OperatorNotInTask(uint256 taskId, address operator);
    error WrongProofType(uint8 got, uint8 required);

    constructor(
        IThinkingGovernor governor_,
        IAICoinMintableG coin_,
        address admin_,
        uint256 rewardPerThought_,
        IComputeVerifier verifier_,
        IComputeProfileView profile_
    ) {
        governor = governor_;
        coin = coin_;
        admin = admin_ == address(0) ? msg.sender : admin_;
        rewardPerThought = rewardPerThought_;
        verifier = verifier_;
        profile = profile_;
    }

    function setReward(uint256 amount) external {
        if (msg.sender != admin) revert NotAdmin();
        rewardPerThought = amount;
        emit RewardSet(amount);
    }

    function setTier(uint8 tier_) external {
        if (msg.sender != admin) revert NotAdmin();
        tier = tier_;
        emit TierSet(tier_);
    }

    function transferAdmin(address admin_) external {
        if (msg.sender != admin) revert NotAdmin();
        emit AdminTransferred(admin, admin_);
        admin = admin_;
    }

    /// @notice The proofType this miner's tier currently requires (0 = none). Convenience view.
    function requiredProofType() public view returns (uint8) {
        if (address(profile) == address(0)) return 0;
        return profile.requiredProofType(tier);
    }

    /// @notice Submit a compute proof binding an operator's work on a SETTLED-or-open thought.
    /// The miner recomputes the expected reportData from the THOUGHT's (modelSpecHash, promptHash)
    /// — fields the submitter cannot forge, they come from on-chain governor state — plus the
    /// per-work binding the submitter supplies (intentID, openBlockHash, outputHash,
    /// runtimeMeasurement) and the operator. Verification enforces the binding, the runtime
    /// membership, and the backend witness. On success, the operator is marked {proven} for this
    /// task. Permissionless to call: the binding names the operator, so a proof can only ever
    /// credit the operator it was constructed for.
    ///
    /// TIER-CHANGE SEMANTICS: the required proofType is checked HERE, at submission — the binding
    /// moment. A proof accepted under the then-current policy stays {proven}; a later tier change
    /// does not retroactively re-judge it (a stronger-than-now proof trivially still qualifies; a
    /// since-tightened bar does not invalidate a proof that was sufficient when proven). Governance
    /// wanting a higher bar on a thought must tighten the tier BEFORE proofs land for it.
    ///
    /// @param taskId             the governor task.
    /// @param operator           the validator the proof is for (must be a submitter on the task).
    /// @param intentID           the off-chain inference intent id bound into the challenge.
    /// @param openBlockHash      the chain context the challenge opened under.
    /// @param outputHash         the validator's model output hash (what it actually produced).
    /// @param runtimeMeasurement the runtime+sampler measurement (must be governance-accepted).
    /// @param proof              the {ComputeProof} (proofType, reportData, evidence).
    function submitComputeProof(
        uint256 taskId,
        address operator,
        bytes32 intentID,
        bytes32 openBlockHash,
        bytes32 outputHash,
        bytes32 runtimeMeasurement,
        ComputeProof calldata proof
    ) external {
        if (address(verifier) == address(0)) revert ProofGateUnavailable();

        // POLICY: the proof must be of the EXACT strength the tier demands. Without this, a tier
        // requiring a hardware-attested CC proof (proofType 1) could be satisfied by a weaker
        // optimistic proof (proofType 3) — a silent downgrade that defeats the whole point of
        // {ComputeProfile}. When the tier is gated (need != 0) the proofType is pinned to it.
        uint8 need = requiredProofType();
        if (need != 0 && proof.proofType != need) revert WrongProofType(proof.proofType, need);

        IThinkingGovernor.Thought memory t = governor.getThought(taskId);

        // The operator must actually be a submitter on this task: a proof for a non-participant
        // can never tip a quorum it was not part of.
        if (governor.getVerdict(taskId, operator).operator != operator) {
            revert OperatorNotInTask(taskId, operator);
        }

        bytes32 expected = ComputeProofLib.expectedReportData(
            taskId,
            intentID,
            t.modelSpecHash,
            t.promptHash,
            openBlockHash,
            operator,
            outputHash,
            runtimeMeasurement
        );

        if (!verifier.verify(proof, expected, runtimeMeasurement)) {
            revert InvalidComputeProof(taskId, operator);
        }

        proven[taskId][operator] = true;
        emit ComputeProofAccepted(taskId, operator, proof.reportData, proof.proofType);
    }

    /// @notice Mine the subsidy for a SETTLED thought, paying the validators who BOTH formed the
    /// canonical quorum AND proved their compute (when the tier requires it). Permissionless; the
    /// reward goes to the proven winners, never the caller. Reverts if not settled, if no winning
    /// group, or — when proofs are required — if fewer than `threshold` winners are proven.
    function mineSettledThought(uint256 taskId) external returns (uint256 totalMinted) {
        if (minedThought[taskId]) revert AlreadyMined(taskId);
        IThinkingGovernor.Thought memory t = governor.getThought(taskId);
        if (t.status != IThinkingGovernor.Status.Settled) revert NotSettled(taskId);
        if (t.agreeCount == 0) revert NoQuorum(taskId);

        minedThought[taskId] = true; // CEI: mark before the external mint; a revert rolls it back

        uint8 need = requiredProofType();
        IThinkingGovernor.Verdict[] memory vs = governor.getVerdicts(taskId);

        // Count the winners that QUALIFY. A winner qualifies if it matched the canonical vote
        // AND (proofs not required for this tier OR it has a proven compute proof). When proofs
        // are required, an unproven winner is NOT counted — so a coin-flip guesser earns nothing.
        uint256 winners;
        for (uint256 i; i < vs.length; ++i) {
            if (vs[i].vote == t.canonicalVote) {
                if (need == 0 || proven[taskId][vs[i].operator]) {
                    winners++;
                }
            }
        }

        // When proofs are required, the PROVEN winning group must still meet the task threshold:
        // a sub-quorum of proven work does not mint (a single proven guess cannot drain the
        // schedule on a 5-of-9 task; ZERO proven work — a pure guess — mints nothing at all).
        // This check precedes the generic NoQuorum so the failure names the proof shortfall.
        if (need != 0) {
            if (winners < t.threshold) revert NoProvenQuorum(taskId, winners, t.threshold);
        } else if (winners == 0) {
            revert NoQuorum(taskId);
        }

        uint256 allowed = coin.emissionAllowance();
        uint256 share = rewardPerThought / winners;
        if (share * winners > allowed) share = allowed / winners; // clamp total to the vested allowance
        if (share == 0) revert NothingToMint();

        for (uint256 i; i < vs.length; ++i) {
            if (vs[i].vote == t.canonicalVote && (need == 0 || proven[taskId][vs[i].operator])) {
                coin.mintSubsidy(vs[i].operator, share);
                emit ValidatorRewarded(taskId, vs[i].operator, share);
            }
        }
        totalMinted = share * winners;
        emit ThoughtMined(taskId, uint8(t.canonicalVote), winners, totalMinted);
    }

    /// @notice Whether a thought is mintable right now: settled, has a qualifying winning group
    /// (proven when required, sized >= threshold when proofs are required), and not yet mined.
    function mineable(uint256 taskId) external view returns (bool) {
        if (minedThought[taskId]) return false;
        IThinkingGovernor.Thought memory t = governor.getThought(taskId);
        if (t.status != IThinkingGovernor.Status.Settled || t.agreeCount == 0) return false;

        uint8 need = requiredProofType();
        if (need == 0) return true; // consensus-only path

        IThinkingGovernor.Verdict[] memory vs = governor.getVerdicts(taskId);
        uint256 winners;
        for (uint256 i; i < vs.length; ++i) {
            if (vs[i].vote == t.canonicalVote && proven[taskId][vs[i].operator]) winners++;
        }
        return winners >= t.threshold && winners != 0;
    }
}
