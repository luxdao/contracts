// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Reputation} from "../contracts/deployables/bounty/Reputation.sol";
import {IReputation, IKarmaSource} from "../contracts/interfaces/dao/deployables/IReputation.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev Records earnKarma calls so the once-only bridge behaviour can be asserted.
contract MockKarmaSource is IKarmaSource {
    uint256 public calls;
    address public lastAccount;
    uint256 public lastAmount;
    bytes32 public lastReason;

    function earnKarma(address account, uint256 amount, bytes32 reason) external override {
        calls++;
        lastAccount = account;
        lastAmount = amount;
        lastReason = reason;
    }
}

/// @dev A karma source that always reverts — models the Karma soft-cap, a paused controller,
/// or a missing role. The bridge must catch it and NEVER block the completion/payout.
contract RevertingKarmaSource is IKarmaSource {
    error Nope();

    function earnKarma(address, uint256, bytes32) external pure override {
        revert Nope();
    }
}

/// @notice Unit proofs for the canonical Reputation ledger + its best-effort Karma bridge:
/// local append-only recording, writer-gating, once-only karma mint, best-effort isolation
/// (a controller revert never bubbles), and Safe-only (owner) bridge configuration.
contract ReputationTest is Test {
    Reputation internal rep;
    MockKarmaSource internal source;

    address internal owner = address(this); // org-Safe stand-in (owner) AND writer, so the
    address internal writer = address(this); // test can drive both roles directly.
    address internal worker = address(0x9A0);
    address internal stranger = address(0x57A);

    uint256 internal constant KARMA_PER = 10e18;
    bytes32 internal constant SRC = keccak256("chain:market:bounty:0");

    function setUp() public {
        source = new MockKarmaSource();
        Reputation impl = new Reputation();
        rep = Reputation(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(Reputation.initialize, (owner, writer, address(source), KARMA_PER))
                )
            )
        );
    }

    function test_InitializesAsProxy() public view {
        assertEq(rep.writer(), writer, "writer");
        assertEq(rep.karmaController(), address(source), "controller");
        assertEq(rep.karmaPerCompletion(), KARMA_PER, "per-completion");
        assertEq(rep.version(), 1, "version");
        assertTrue(rep.supportsInterface(type(IReputation).interfaceId), "ERC165 IReputation");
    }

    // --- writer gating ---

    function test_OnlyWriterCanRecordCompletion() public {
        vm.prank(stranger);
        vm.expectRevert(IReputation.OnlyWriter.selector);
        rep.recordCompletion(worker, 100, SRC);
    }

    function test_OnlyWriterCanRecordDisputeLoss() public {
        vm.prank(stranger);
        vm.expectRevert(IReputation.OnlyWriter.selector);
        rep.recordDisputeLoss(worker);
    }

    // --- local ledger ---

    function test_RecordCompletion_UpdatesLocalLedger() public {
        rep.recordCompletion(worker, 100, SRC);
        (uint64 completed, uint64 lost, uint256 earned) = rep.reputationOf(worker);
        assertEq(completed, 1, "completed");
        assertEq(lost, 0, "no losses");
        assertEq(earned, 100, "earned");
    }

    function test_RecordDisputeLoss_LocalOnly_NoKarma() public {
        rep.recordDisputeLoss(worker);
        (, uint64 lost, ) = rep.reputationOf(worker);
        assertEq(lost, 1, "dispute loss recorded");
        assertEq(source.calls(), 0, "dispute loss does NOT touch karma");
    }

    // --- karma bridge: once, correct args ---

    function test_KarmaBridged_OnceWithFlatAward() public {
        rep.recordCompletion(worker, 100, SRC);
        assertEq(source.calls(), 1, "earnKarma called once");
        assertEq(source.lastAccount(), worker, "to worker");
        assertEq(source.lastAmount(), KARMA_PER, "flat award, not the reward amount (100)");
        assertEq(source.lastReason(), SRC, "reason == source");
        assertTrue(rep.karmaMinted(SRC), "source marked minted");
    }

    function test_NoDoubleMint_SameSource() public {
        rep.recordCompletion(worker, 100, SRC);
        rep.recordCompletion(worker, 100, SRC); // replay same source
        assertEq(source.calls(), 1, "karma minted exactly once per source (no double-mint)");
        // Local ledger is the writer's responsibility; the source guard protects only karma.
        assertEq(rep.completedOf(worker), 2, "local increments each call");
    }

    function test_DistinctSources_MintEachOnce() public {
        rep.recordCompletion(worker, 100, keccak256("b0"));
        rep.recordCompletion(worker, 100, keccak256("b1"));
        assertEq(source.calls(), 2, "each distinct bounty mints once");
    }

    // --- best-effort: a controller revert never blocks the completion ---

    function test_BestEffort_ControllerRevertDoesNotBlock() public {
        RevertingKarmaSource bad = new RevertingKarmaSource();
        rep.setKarmaController(address(bad));

        // Must NOT revert even though earnKarma reverts.
        rep.recordCompletion(worker, 100, SRC);

        assertEq(rep.completedOf(worker), 1, "local completion still recorded");
        assertEq(rep.earnedOf(worker), 100, "earnings still recorded");
        // LOW fix: a transient failure RELEASES the once-only key so it can be retried later.
        assertFalse(rep.karmaMinted(SRC), "source released for retry after transient failure");
    }

    function test_RetryKarmaBridge_AfterTransientFailure() public {
        RevertingKarmaSource bad = new RevertingKarmaSource();
        rep.setKarmaController(address(bad));
        rep.recordCompletion(worker, 100, SRC); // fails, source released
        assertFalse(rep.karmaMinted(SRC), "not minted");

        // Owner fixes the controller and retries — now it mints, exactly once.
        rep.setKarmaController(address(source));
        rep.retryKarmaBridge(worker, SRC);
        assertEq(source.calls(), 1, "retry minted");
        assertTrue(rep.karmaMinted(SRC), "consumed on success");
        // A second retry is a no-op (already minted).
        rep.retryKarmaBridge(worker, SRC);
        assertEq(source.calls(), 1, "no double-mint on repeat retry");
    }

    function test_RetryKarmaBridge_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        rep.retryKarmaBridge(worker, SRC);
    }

    // --- bridge disabled: no controller / zero per-completion => skip, no revert ---

    function test_BridgeDisabled_NoController() public {
        rep.setKarmaController(address(0));
        rep.recordCompletion(worker, 100, SRC);
        assertEq(source.calls(), 0, "no bridge call");
        assertEq(rep.completedOf(worker), 1, "local still recorded");
        assertFalse(rep.karmaMinted(SRC), "not consumed while disabled");
    }

    function test_BridgeDisabled_ZeroPerCompletion() public {
        rep.setKarmaPerCompletion(0);
        rep.recordCompletion(worker, 100, SRC);
        assertEq(source.calls(), 0, "no bridge call");
        assertFalse(rep.karmaMinted(SRC), "not consumed while disabled");
    }

    // --- Safe-only (owner) configuration ---

    function test_SetKarmaController_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        rep.setKarmaController(address(0xBEEF));
    }

    function test_SetKarmaPerCompletion_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        rep.setKarmaPerCompletion(1);
    }

    function test_OwnerCanRetuneBridge() public {
        rep.setKarmaPerCompletion(25e18);
        assertEq(rep.karmaPerCompletion(), 25e18, "retuned");
        rep.recordCompletion(worker, 1, SRC);
        assertEq(source.lastAmount(), 25e18, "new award used");
    }
}
