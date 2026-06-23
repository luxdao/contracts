// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BountyV1} from "../contracts/deployables/bounty/BountyV1.sol";
import {EscrowV1} from "../contracts/deployables/bounty/EscrowV1.sol";
import {ReputationV1} from "../contracts/deployables/bounty/ReputationV1.sol";
import {IBountyV1} from "../contracts/interfaces/dao/deployables/IBountyV1.sol";
import {IEscrowV1} from "../contracts/interfaces/dao/deployables/IEscrowV1.sol";
import {IReputationV1} from "../contracts/interfaces/dao/deployables/IReputationV1.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";

/// @dev A minimal contract "signer" standing in for a Safe (incl. a PQ-signed Safe):
/// it can be a bounty's funder, approver, and arbiter, proving the market never
/// assumes an EOA. It forwards arbitrary calls so the test can act AS the Safe.
contract SafeLike {
    function exec(address to, uint256 value, bytes calldata data) external payable returns (bytes memory) {
        (bool ok, bytes memory ret) = to.call{value: value}(data);
        require(ok, "SafeLike: call failed");
        return ret;
    }

    receive() external payable {}
}

/// @dev Malicious worker that, on receiving the native reward during accept(),
/// tries to reenter BountyV1. The nonReentrant guard + already-terminal state must
/// make any reentry revert; the attacker swallows it so we can assert no double-pay.
contract ReentrantWorker {
    BountyV1 public immutable bounty;
    uint256 public bountyId;
    bool public tried;

    constructor(BountyV1 bounty_) {
        bounty = bounty_;
    }

    function setBounty(uint256 id) external {
        bountyId = id;
    }

    function doClaim(uint256 id) external payable {
        bountyId = id;
        bounty.claim{value: msg.value}(id);
    }

    function doSubmit(uint256 id, string calldata ref) external {
        bounty.submit(id, ref);
    }

    receive() external payable {
        if (!tried) {
            tried = true;
            // Try to claim again / re-accept -- must revert under the guard.
            try bounty.accept(bountyId) {} catch {}
        }
    }
}

/// @notice Full-lifecycle proofs for the permissionless work market. Conservation is
/// asserted across happy path, slash, dispute (split + refund), cancel and reclaim.
contract BountyV1Test is Test {
    BountyV1 internal bounty;
    EscrowV1 internal escrow;
    ReputationV1 internal rep;
    MockERC20 internal token;

    address internal owner = address(0x0420);
    address internal funder = address(0xF4DE7);
    address internal approver = address(0xA999);
    address internal arbiter = address(0xA981E7);
    address internal worker = address(0x9A0);
    address internal stranger = address(0x57A);
    address internal treasury = address(0x77EA);

    address internal constant NATIVE = address(0);

    uint256 internal constant REWARD = 10 ether;
    uint256 internal constant STAKE = 1 ether;
    uint64 internal constant WINDOW = 3 days;

    function setUp() public {
        token = new MockERC20("Work Token", "WORK", 18);

        // Break the escrow<->bounty wiring cycle by predicting the bounty proxy
        // address: in setUp() the next CREATE from this contract after the escrow
        // impl + escrow proxy + reputation impl + reputation proxy + bounty impl is
        // the bounty proxy. This mirrors a deploy script that predicts the proxy
        // address, points escrow/reputation at it, then deploys the proxy.
        EscrowV1 escrowImpl = new EscrowV1();
        ReputationV1 repImpl = new ReputationV1();
        BountyV1 bountyImpl = new BountyV1();

        // After the two proxies below + nothing else, the bounty proxy is created at
        // nonce(this)+3 (escrow proxy, rep proxy, bounty proxy). Compute it now.
        address predictedBounty = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);

        escrow = EscrowV1(
            payable(
                address(
                    new ERC1967Proxy(
                        address(escrowImpl),
                        abi.encodeCall(EscrowV1.initialize, (owner, predictedBounty))
                    )
                )
            )
        );
        rep = ReputationV1(
            address(
                new ERC1967Proxy(
                    address(repImpl),
                    abi.encodeCall(ReputationV1.initialize, (owner, predictedBounty))
                )
            )
        );
        bounty = BountyV1(
            address(
                new ERC1967Proxy(
                    address(bountyImpl),
                    abi.encodeCall(BountyV1.initialize, (owner, address(escrow), address(rep), treasury))
                )
            )
        );

        assertEq(address(bounty), predictedBounty, "prediction held");
        assertEq(escrow.controller(), address(bounty), "escrow controller is bounty");
        assertEq(rep.writer(), address(bounty), "reputation writer is bounty");
    }

    // ==================================================================
    // Wiring / deployability
    // ==================================================================

    function test_InitializesAsProxy() public view {
        assertEq(bounty.escrow(), address(escrow));
        assertEq(bounty.reputation(), address(rep));
        assertEq(bounty.treasury(), treasury);
        assertEq(bounty.owner(), owner);
        assertEq(bounty.version(), 1);
        assertTrue(bounty.deploymentBlock() > 0);
        assertTrue(bounty.supportsInterface(type(IBountyV1).interfaceId));
    }

    // ==================================================================
    // Happy path -- NATIVE -- full conservation
    // ==================================================================

    function test_HappyPath_Native_Conserves() public {
        // Conservation baseline: total native across all actors + escrow is constant.
        vm.deal(funder, REWARD);
        vm.deal(worker, STAKE);
        uint256 total = _sumNative();

        // Propose (funder) -- permissionless.
        vm.prank(funder);
        uint256 id = bounty.propose(NATIVE, REWARD, STAKE, approver, arbiter, WINDOW, "ipfs://issue");
        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Open));

        // Fund (funder escrows reward).
        vm.prank(funder);
        bounty.fund{value: REWARD}(id);
        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Funded));
        assertEq(address(escrow).balance, REWARD, "reward escrowed");

        // Claim (worker stakes) -- permissionless.
        vm.prank(worker);
        bounty.claim{value: STAKE}(id);
        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Claimed));
        assertEq(address(escrow).balance, REWARD + STAKE, "reward + stake escrowed");

        // Submit (worker).
        vm.prank(worker);
        bounty.submit(id, "ipfs://deliverable");
        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Submitted));

        // Accept (approver) -- atomic payout.
        vm.prank(approver);
        bounty.accept(id);
        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Paid));

        // Worker got reward + stake back; escrow empty; reputation credited.
        assertEq(worker.balance, REWARD + STAKE, "worker paid reward + stake returned");
        assertEq(address(escrow).balance, 0, "escrow drained");
        assertEq(rep.completedOf(worker), 1, "completion recorded");
        assertEq(rep.earnedOf(worker), REWARD, "earnings recorded");

        // Conservation: nothing minted or burned.
        assertEq(_sumNative(), total, "native conserved across lifecycle");
    }

    // ==================================================================
    // Happy path -- ERC-20 -- full conservation
    // ==================================================================

    function test_HappyPath_ERC20_Conserves() public {
        token.mint(funder, REWARD);
        token.mint(worker, STAKE);
        uint256 supply = token.totalSupply();

        vm.prank(funder);
        uint256 id = bounty.propose(address(token), REWARD, STAKE, approver, arbiter, WINDOW, "issue");

        // Funder approves the ESCROW (escrow pulls), then funds.
        vm.prank(funder);
        token.approve(address(escrow), REWARD);
        vm.prank(funder);
        bounty.fund(id);
        assertEq(token.balanceOf(address(escrow)), REWARD);

        // Worker approves the escrow, then claims.
        vm.prank(worker);
        token.approve(address(escrow), STAKE);
        vm.prank(worker);
        bounty.claim(id);
        assertEq(token.balanceOf(address(escrow)), REWARD + STAKE);

        vm.prank(worker);
        bounty.submit(id, "deliverable");
        vm.prank(approver);
        bounty.accept(id);

        assertEq(token.balanceOf(worker), REWARD + STAKE, "worker reward + stake");
        assertEq(token.balanceOf(address(escrow)), 0, "escrow drained");
        assertEq(token.totalSupply(), supply, "token supply conserved");
        assertEq(rep.completedOf(worker), 1);
    }

    // ==================================================================
    // Permissionless claim
    // ==================================================================

    function test_AnyAddressCanClaim() public {
        uint256 id = _proposeAndFundNative();

        // An arbitrary, never-allowlisted address claims successfully.
        address rando = address(0xBEEF1234);
        vm.deal(rando, STAKE);
        vm.prank(rando);
        bounty.claim{value: STAKE}(id);

        IBountyV1.Bounty memory b = bounty.bounties(id);
        assertEq(b.worker, rando, "arbitrary address became worker");
        assertEq(uint8(b.state), uint8(IBountyV1.State.Claimed));
    }

    // ==================================================================
    // Stake slash on abandonment / timeout
    // ==================================================================

    function test_ReclaimSlashesStakeToTreasury_AndReopens() public {
        uint256 id = _proposeAndFundNative();
        vm.deal(worker, STAKE);
        vm.prank(worker);
        bounty.claim{value: STAKE}(id);

        // Before deadline: cannot reclaim.
        IBountyV1.Bounty memory b0 = bounty.bounties(id);
        vm.expectRevert(abi.encodeWithSelector(IBountyV1.DeadlineNotPassed.selector, id, b0.claimDeadline));
        bounty.reclaim(id);

        // After deadline: ANYONE reclaims; stake is slashed to treasury, bounty reopens.
        vm.warp(block.timestamp + WINDOW + 1);
        uint256 treStart = treasury.balance;
        vm.prank(stranger);
        bounty.reclaim(id);

        assertEq(treasury.balance, treStart + STAKE, "stake slashed to treasury");
        IBountyV1.Bounty memory b1 = bounty.bounties(id);
        assertEq(uint8(b1.state), uint8(IBountyV1.State.Funded), "reopened");
        assertEq(b1.worker, address(0), "worker cleared");
        assertEq(address(escrow).balance, REWARD, "reward still escrowed");

        // A fresh worker can now claim the reopened bounty.
        vm.deal(worker, STAKE);
        vm.prank(worker);
        bounty.claim{value: STAKE}(id);
        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Claimed));
    }

    function test_SlashRoutesToFunderWhenNoTreasury() public {
        // Re-deploy a market with treasury == address(0): slash must route to funder.
        (BountyV1 b2, EscrowV1 e2, ) = _deployMarket(address(0));

        vm.deal(funder, REWARD);
        vm.prank(funder);
        uint256 id = b2.propose(NATIVE, REWARD, STAKE, approver, arbiter, WINDOW, "issue");
        vm.prank(funder);
        b2.fund{value: REWARD}(id);
        vm.deal(worker, STAKE);
        vm.prank(worker);
        b2.claim{value: STAKE}(id);

        vm.warp(block.timestamp + WINDOW + 1);
        uint256 funderStart = funder.balance;
        b2.reclaim(id);
        assertEq(funder.balance, funderStart + STAKE, "slash routed to funder");
        assertEq(address(e2).balance, REWARD, "reward intact");
    }

    function test_SubmitAfterDeadlineReverts() public {
        uint256 id = _proposeAndFundNative();
        vm.deal(worker, STAKE);
        vm.prank(worker);
        bounty.claim{value: STAKE}(id);

        vm.warp(block.timestamp + WINDOW + 1);
        IBountyV1.Bounty memory b = bounty.bounties(id);
        vm.prank(worker);
        vm.expectRevert(abi.encodeWithSelector(IBountyV1.DeadlinePassed.selector, id, b.claimDeadline));
        bounty.submit(id, "late");
    }

    // ==================================================================
    // Dispute -> arbiter resolve (split + refund + stake decision), conservation
    // ==================================================================

    function test_Dispute_SplitRewardKeepStake_Conserves() public {
        // Drive to Submitted (helper deals + escrows reward and stake), then snapshot
        // the conservation total: reward + stake now live in the escrow.
        uint256 id = _toSubmitted(NATIVE);
        uint256 total = _sumNative();

        // Funder disputes.
        vm.prank(funder);
        bounty.dispute(id, "ipfs://reason");
        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Disputed));

        // Arbiter splits 7 to worker / 3 back to funder, worker keeps stake.
        vm.prank(arbiter);
        bounty.resolveDispute(id, 7 ether, 3 ether, true);

        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Paid));
        assertEq(worker.balance, 7 ether + STAKE, "worker: split + stake");
        assertEq(funder.balance, 3 ether, "funder: refunded portion");
        assertEq(address(escrow).balance, 0, "escrow drained");
        assertEq(rep.completedOf(worker), 1, "nonzero worker payout => completion");
        assertEq(_sumNative(), total, "conserved across dispute split");
    }

    function test_Dispute_FullRefundSlashStake_RecordsLoss_Conserves() public {
        uint256 id = _toSubmitted(NATIVE);
        uint256 total = _sumNative();

        vm.prank(approver);
        bounty.dispute(id, "bad work");

        // Arbiter: 0 to worker, full reward back to funder, slash the stake to treasury.
        uint256 treStart = treasury.balance;
        vm.prank(arbiter);
        bounty.resolveDispute(id, 0, REWARD, false);

        assertEq(worker.balance, 0, "worker gets nothing");
        assertEq(funder.balance, REWARD, "funder fully refunded");
        assertEq(treasury.balance, treStart + STAKE, "stake slashed to treasury");
        assertEq(address(escrow).balance, 0, "escrow drained");
        (, uint64 lost, ) = rep.reputationOf(worker);
        assertEq(lost, 1, "dispute loss recorded");
        assertEq(rep.completedOf(worker), 0, "no completion");
        assertEq(_sumNative(), total, "conserved across full-refund + slash");
    }

    function test_Dispute_SplitMustEqualReward() public {
        uint256 id = _toSubmitted(NATIVE);
        vm.prank(funder);
        bounty.dispute(id, "r");
        vm.prank(arbiter);
        vm.expectRevert(abi.encodeWithSelector(IBountyV1.SplitExceedsReward.selector, id, REWARD, 11 ether));
        bounty.resolveDispute(id, 8 ether, 3 ether, true); // 11 != 10
    }

    function test_OnlyArbiterResolves() public {
        uint256 id = _toSubmitted(NATIVE);
        vm.prank(funder);
        bounty.dispute(id, "r");
        vm.prank(stranger);
        vm.expectRevert(IBountyV1.OnlyArbiter.selector);
        bounty.resolveDispute(id, REWARD, 0, true);
    }

    function test_OnlyFunderOrApproverDisputes() public {
        uint256 id = _toSubmitted(NATIVE);
        vm.prank(stranger);
        vm.expectRevert(IBountyV1.OnlyApprover.selector);
        bounty.dispute(id, "r");
    }

    // ==================================================================
    // Cancel / refund on expiry
    // ==================================================================

    function test_CancelOpen_NoEscrow() public {
        vm.prank(funder);
        uint256 id = bounty.propose(NATIVE, REWARD, STAKE, approver, arbiter, WINDOW, "issue");
        vm.prank(funder);
        bounty.cancel(id);
        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Cancelled));
    }

    function test_CancelFunded_RefundsReward_Conserves() public {
        uint256 id = _proposeAndFundNative();
        uint256 total = _sumNative();

        vm.prank(funder);
        bounty.cancel(id);

        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Cancelled));
        assertEq(funder.balance, REWARD, "reward refunded to funder");
        assertEq(address(escrow).balance, 0, "escrow drained");
        assertEq(_sumNative(), total, "conserved across cancel/refund");
    }

    function test_OnlyFunderCancels() public {
        uint256 id = _proposeAndFundNative();
        vm.prank(stranger);
        vm.expectRevert(IBountyV1.OnlyFunder.selector);
        bounty.cancel(id);
    }

    function test_CannotCancelAfterClaimed() public {
        uint256 id = _proposeAndFundNative();
        vm.deal(worker, STAKE);
        vm.prank(worker);
        bounty.claim{value: STAKE}(id);
        vm.prank(funder);
        vm.expectRevert(
            abi.encodeWithSelector(IBountyV1.InvalidState.selector, id, IBountyV1.State.Claimed, IBountyV1.State.Funded)
        );
        bounty.cancel(id);
    }

    // ==================================================================
    // Illegal-transition guards
    // ==================================================================

    function test_CannotClaimUnfunded() public {
        vm.prank(funder);
        uint256 id = bounty.propose(NATIVE, REWARD, STAKE, approver, arbiter, WINDOW, "issue");
        vm.deal(worker, STAKE);
        vm.prank(worker);
        vm.expectRevert(
            abi.encodeWithSelector(IBountyV1.InvalidState.selector, id, IBountyV1.State.Open, IBountyV1.State.Funded)
        );
        bounty.claim{value: STAKE}(id);
    }

    function test_CannotSubmitBeforeClaim() public {
        uint256 id = _proposeAndFundNative();
        vm.prank(worker);
        vm.expectRevert(
            abi.encodeWithSelector(IBountyV1.InvalidState.selector, id, IBountyV1.State.Funded, IBountyV1.State.Claimed)
        );
        bounty.submit(id, "x");
    }

    function test_CannotAcceptBeforeSubmit() public {
        uint256 id = _proposeAndFundNative();
        vm.deal(worker, STAKE);
        vm.prank(worker);
        bounty.claim{value: STAKE}(id);
        vm.prank(approver);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBountyV1.InvalidState.selector,
                id,
                IBountyV1.State.Claimed,
                IBountyV1.State.Submitted
            )
        );
        bounty.accept(id);
    }

    function test_OnlyWorkerSubmits() public {
        uint256 id = _proposeAndFundNative();
        vm.deal(worker, STAKE);
        vm.prank(worker);
        bounty.claim{value: STAKE}(id);
        vm.prank(stranger);
        vm.expectRevert(IBountyV1.OnlyWorker.selector);
        bounty.submit(id, "x");
    }

    function test_OnlyApproverAccepts() public {
        uint256 id = _toSubmitted(NATIVE);
        vm.prank(stranger);
        vm.expectRevert(IBountyV1.OnlyApprover.selector);
        bounty.accept(id);
    }

    function test_UnknownBountyReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IBountyV1.UnknownBounty.selector, uint256(999)));
        bounty.fund{value: 0}(999);
    }

    function test_ProposeRejectsZeroRewardOrStake() public {
        vm.prank(funder);
        vm.expectRevert(IBountyV1.ZeroAmount.selector);
        bounty.propose(NATIVE, 0, STAKE, approver, arbiter, WINDOW, "i");
        vm.prank(funder);
        vm.expectRevert(IBountyV1.ZeroAmount.selector);
        bounty.propose(NATIVE, REWARD, 0, approver, arbiter, WINDOW, "i");
    }

    function test_ProposeRejectsZeroApprover() public {
        vm.prank(funder);
        vm.expectRevert(IBountyV1.InvalidApprover.selector);
        bounty.propose(NATIVE, REWARD, STAKE, address(0), arbiter, WINDOW, "i");
    }

    // ==================================================================
    // Native-value mismatches at the boundary
    // ==================================================================

    function test_FundNativeWrongValueReverts() public {
        vm.prank(funder);
        uint256 id = bounty.propose(NATIVE, REWARD, STAKE, approver, arbiter, WINDOW, "i");
        vm.deal(funder, REWARD);
        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(IBountyV1.StakeMismatch.selector, REWARD, 1 ether));
        bounty.fund{value: 1 ether}(id);
    }

    function test_FundERC20WithNativeValueReverts() public {
        token.mint(funder, REWARD);
        vm.prank(funder);
        uint256 id = bounty.propose(address(token), REWARD, STAKE, approver, arbiter, WINDOW, "i");
        vm.prank(funder);
        token.approve(address(escrow), REWARD);
        vm.deal(funder, 1 ether);
        vm.prank(funder);
        vm.expectRevert(IBountyV1.UnexpectedNativeValue.selector);
        bounty.fund{value: 1 wei}(id);
    }

    // ==================================================================
    // Reentrancy: malicious worker cannot double-spend on accept()
    // ==================================================================

    function test_ReentrantWorkerCannotDoublePay() public {
        ReentrantWorker attacker = new ReentrantWorker(bounty);
        uint256 id = _proposeAndFundNative();

        // Fund the stake from the test contract (the caller pays doClaim's value), so
        // the attacker starts at zero and ends holding exactly what it is paid.
        vm.deal(address(this), STAKE);
        attacker.doClaim{value: STAKE}(id);
        attacker.doSubmit(id, "deliverable");
        assertEq(address(attacker).balance, 0, "attacker forwarded its whole stake");

        uint256 escrowBefore = address(escrow).balance; // REWARD + STAKE
        vm.prank(approver);
        bounty.accept(id);

        assertTrue(attacker.tried(), "attacker attempted reentry on receive");
        // Attacker received exactly REWARD + STAKE once; escrow emptied; no extra.
        assertEq(address(attacker).balance, REWARD + STAKE, "paid exactly once");
        assertEq(address(escrow).balance, escrowBefore - (REWARD + STAKE), "escrow drained exactly");
        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Paid));
    }

    // ==================================================================
    // Contract signer (Safe / PQ-Safe) as funder + approver + arbiter
    // ==================================================================

    function test_SafeContractAsFunderApproverArbiter() public {
        SafeLike safe = new SafeLike();
        vm.deal(address(safe), REWARD);

        // Safe proposes (funder = safe), funds, approver = safe, arbiter = safe.
        bytes memory ret = safe.exec(
            address(bounty),
            0,
            abi.encodeCall(
                IBountyV1.propose,
                (NATIVE, REWARD, STAKE, address(safe), address(safe), WINDOW, "issue")
            )
        );
        uint256 id = abi.decode(ret, (uint256));

        safe.exec(address(bounty), REWARD, abi.encodeCall(IBountyV1.fund, (id)));

        vm.deal(worker, STAKE);
        vm.prank(worker);
        bounty.claim{value: STAKE}(id);
        vm.prank(worker);
        bounty.submit(id, "deliverable");

        // Safe accepts (as approver) -- authorization is purely "caller == approver".
        safe.exec(address(bounty), 0, abi.encodeCall(IBountyV1.accept, (id)));

        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Paid));
        assertEq(worker.balance, REWARD + STAKE, "worker paid by Safe-run market");
        assertEq(rep.completedOf(worker), 1);
    }

    // ==================================================================
    // helpers
    // ==================================================================

    function _deployMarket(address treasury_) internal returns (BountyV1 b, EscrowV1 e, ReputationV1 r) {
        EscrowV1 ei = new EscrowV1();
        ReputationV1 ri = new ReputationV1();
        BountyV1 bi = new BountyV1();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        e = EscrowV1(
            payable(address(new ERC1967Proxy(address(ei), abi.encodeCall(EscrowV1.initialize, (owner, predicted)))))
        );
        r = ReputationV1(
            address(new ERC1967Proxy(address(ri), abi.encodeCall(ReputationV1.initialize, (owner, predicted))))
        );
        b = BountyV1(
            address(
                new ERC1967Proxy(
                    address(bi),
                    abi.encodeCall(BountyV1.initialize, (owner, address(e), address(r), treasury_))
                )
            )
        );
        require(address(b) == predicted, "predict");
    }

    function _proposeAndFundNative() internal returns (uint256 id) {
        vm.deal(funder, funder.balance + REWARD);
        vm.prank(funder);
        id = bounty.propose(NATIVE, REWARD, STAKE, approver, arbiter, WINDOW, "issue");
        vm.prank(funder);
        bounty.fund{value: REWARD}(id);
    }

    function _toSubmitted(address tok) internal returns (uint256 id) {
        if (tok == NATIVE) {
            id = _proposeAndFundNative();
            vm.deal(worker, worker.balance + STAKE);
            vm.prank(worker);
            bounty.claim{value: STAKE}(id);
        } else {
            token.mint(funder, REWARD);
            token.mint(worker, STAKE);
            vm.prank(funder);
            id = bounty.propose(tok, REWARD, STAKE, approver, arbiter, WINDOW, "issue");
            vm.prank(funder);
            token.approve(address(escrow), REWARD);
            vm.prank(funder);
            bounty.fund(id);
            vm.prank(worker);
            token.approve(address(escrow), STAKE);
            vm.prank(worker);
            bounty.claim(id);
        }
        vm.prank(worker);
        bounty.submit(id, "deliverable");
    }

    /// @dev Sum of native held by every actor + the escrow. Invariant across paths.
    function _sumNative() internal view returns (uint256) {
        return
            funder.balance +
            worker.balance +
            approver.balance +
            arbiter.balance +
            stranger.balance +
            treasury.balance +
            address(escrow).balance +
            address(bounty).balance;
    }
}
