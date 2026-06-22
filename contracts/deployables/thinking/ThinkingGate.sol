// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IThinkingGovernor} from "./interfaces/IThinkingGovernor.sol";

/**
 * @title ThinkingGate
 * @author Hanzo AI Inc / Lux Network
 * @notice Composition seam between operator-LLM consensus ({ThinkingGovernor}) and
 * the rest of the DAO (e.g. {ModuleGovernorV1}). A caller asks the gate "did the
 * thinking validators decide YES on task T?" before taking a governed action — so a
 * proposal can be GATED or ADVISED by the on-chain LLM-quorum decision.
 *
 * This is intentionally a pure, read-only adviser: it never holds funds, never
 * mutates {ThinkingGovernor}, and reverts closed when the decision is absent or not
 * a YES quorum. It composes — it does not entangle. The authoritative decision
 * lives in {ThinkingGovernor}; the gate only interprets it for a consumer.
 *
 * USAGE WITH ModuleGovernorV1
 *   A proposer adapter (or a Safe owner) calls {requireYes}(taskId) at the top of
 *   its submit path; if the thinking validators did not reach a YES quorum the call
 *   reverts and no proposal is created. Alternatively {advise}(taskId) returns the
 *   decision so the proposer can attach it to the proposal metadata for voters to
 *   see what the operator-LLMs concluded.
 *
 * @custom:security-contact security@lux.network
 */
contract ThinkingGate {
    IThinkingGovernor public immutable governor;

    error NoYesQuorum(uint256 taskId);

    constructor(address governor_) {
        governor = IThinkingGovernor(governor_);
    }

    /// @notice True iff the thinking validators reached a settled YES quorum on
    /// `taskId`. This is the gate condition a consumer checks.
    function isYesQuorum(uint256 taskId) public view returns (bool) {
        (bool settled, IThinkingGovernor.Vote vote, , ) = governor.getCanonicalVerdict(taskId);
        return settled && vote == IThinkingGovernor.Vote.Yes;
    }

    /// @notice Reverts unless `taskId` reached a YES quorum. Use as a guard at the
    /// top of a gated action (e.g. submitting a proposal).
    function requireYes(uint256 taskId) external view {
        if (!isYesQuorum(taskId)) revert NoYesQuorum(taskId);
    }

    /// @notice Returns the full canonical decision for a consumer to ADVISE on
    /// (e.g. embed in proposal metadata) without gating.
    function advise(
        uint256 taskId
    ) external view returns (bool settled, IThinkingGovernor.Vote vote, uint16 confidenceBucket, uint8 agreeCount) {
        return governor.getCanonicalVerdict(taskId);
    }
}
