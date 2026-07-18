// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Escrow} from "../contracts/deployables/bounty/Escrow.sol";
import {IEscrow} from "../contracts/interfaces/dao/deployables/IEscrow.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";
import {MockFeeOnTransferERC20} from "../contracts/mocks/MockFeeOnTransferERC20.sol";
import {MockERC721} from "../contracts/mocks/MockERC721.sol";
import {MockERC1155} from "../contracts/mocks/MockERC1155.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

/// @dev Reenters the escrow on native receipt. Because the escrow is onlyController + CEI,
/// a reenter from the payout recipient can't move funds.
contract EscrowReenterRecipient {
    IEscrow public immutable escrow;
    bytes32 public immutable depositId;
    bool public tried;

    constructor(IEscrow escrow_, bytes32 depositId_) {
        escrow = escrow_;
        depositId = depositId_;
    }

    receive() external payable {
        if (!tried) {
            tried = true;
            try escrow.release(depositId, address(this), 1) {} catch {}
        }
    }
}

/// @dev Malicious ERC-721 recipient: on the safeTransfer callback during release, tries to
/// re-enter the escrow to release a DIFFERENT deposit. The reentrancy guard must block it,
/// yet the legit transfer still completes (magic value returned).
contract ReentrantNftRecipient is IERC721Receiver {
    IEscrow public immutable escrow;
    bytes32 public target; // a different deposit to try to drain
    bool public tried;

    constructor(IEscrow escrow_) {
        escrow = escrow_;
    }

    function setTarget(bytes32 t) external {
        target = t;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (!tried) {
            tried = true;
            try escrow.release(target, address(this), 1) {} catch {}
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev A recipient that can toggle whether it accepts native transfers, and can pull its own
/// escrow credit. Models a formerly-unable recipient recovering a credited (failed) payout.
contract ToggleNativeRecipient {
    IEscrow public immutable escrow;
    bool public accepting;

    constructor(IEscrow escrow_) {
        escrow = escrow_;
    }

    function setAccepting(bool v) external {
        accepting = v;
    }

    function pull(IEscrow.AssetKind kind, address token, uint256 tokenId) external {
        escrow.withdraw(kind, token, tokenId);
    }

    receive() external payable {
        require(accepting, "no receive");
    }
}

/// @notice Direct proofs for the canonical Escrow: native + ERC-20 conservation (v-parity),
/// ERC-721 / ERC-1155 custody, indivisibility, unsolicited-transfer rejection, reentrancy-safety
/// on the NFT safeTransfer callback, AND credit-on-failure pull-payment (H1).
contract EscrowTest is Test {
    Escrow internal escrow;
    MockERC20 internal token;
    MockERC721 internal nft;
    MockERC1155 internal multi;

    address internal owner = address(0x0420);
    address internal controller = address(0xC0117401);
    address internal funder = address(0xF4DE7);
    address internal payee = address(0x9A4EE);

    bytes32 internal constant K1 = keccak256("deposit-1");
    bytes32 internal constant K2 = keccak256("deposit-2");
    bytes32 internal constant KN = keccak256("deposit-nft");

    address internal constant NATIVE = address(0);
    uint256 internal constant TID = 7; // an ERC-721/1155 token id

    function setUp() public {
        Escrow impl = new Escrow();
        escrow = Escrow(
            payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(Escrow.initialize, (owner, controller)))))
        );
        token = new MockERC20("Work Token", "WORK", 18);
        nft = new MockERC721();
        multi = new MockERC1155();
    }

    // --- Wiring / deployability ---

    function test_InitializesAsProxy() public view {
        assertEq(escrow.controller(), controller, "controller set");
        assertEq(escrow.owner(), owner, "owner set");
        assertEq(escrow.version(), 1, "version");
        assertTrue(escrow.deploymentBlock() > 0, "deployment block recorded");
        assertTrue(escrow.supportsInterface(type(IEscrow).interfaceId), "ERC165 IEscrow");
        assertTrue(escrow.supportsInterface(type(IERC721Receiver).interfaceId), "ERC165 IERC721Receiver");
        assertTrue(escrow.supportsInterface(type(IERC1155Receiver).interfaceId), "ERC165 IERC1155Receiver");
    }

    // --- Authorization (parity) ---

    function test_OnlyControllerCanDeposit() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(IEscrow.OnlyController.selector);
        escrow.deposit{value: 1 ether}(K1, IEscrow.AssetKind.Native, NATIVE, funder, 0, 1 ether);
    }

    function test_OnlyControllerCanRelease() public {
        _depositNative(K1, 1 ether);
        vm.expectRevert(IEscrow.OnlyController.selector);
        escrow.release(K1, payee, 1 ether);
    }

    // --- Native + ERC-20 conservation (parity with the fungible market) ---

    function test_NativeDepositReleaseRefund_Conserves() public {
        uint256 escrowStart = address(escrow).balance;
        _depositNative(K1, 3 ether);
        assertEq(address(escrow).balance, escrowStart + 3 ether, "escrow holds deposit");

        vm.prank(controller);
        escrow.release(K1, payee, 2 ether);
        vm.prank(controller);
        escrow.refund(K1, funder, 1 ether);

        assertEq(payee.balance, 2 ether, "payee got release");
        assertEq(funder.balance, 1 ether, "funder got refund");
        assertEq(escrow.remainingOf(K1), 0, "deposit drained");
        assertEq(address(escrow).balance, escrowStart, "escrow net zero -- conserved");
    }

    function test_ERC20DepositReleaseRefund_Conserves() public {
        token.mint(funder, 100 ether);
        vm.prank(funder);
        token.approve(address(escrow), 100 ether);
        vm.prank(controller);
        escrow.deposit(K1, IEscrow.AssetKind.ERC20, address(token), funder, 0, 100 ether);
        assertEq(token.balanceOf(address(escrow)), 100 ether, "escrow holds tokens");

        vm.prank(controller);
        escrow.release(K1, payee, 60 ether);
        vm.prank(controller);
        escrow.refund(K1, funder, 40 ether);
        assertEq(token.balanceOf(payee), 60 ether, "payee release");
        assertEq(token.balanceOf(funder), 40 ether, "funder refund");
        assertEq(token.balanceOf(address(escrow)), 0, "escrow drained");
    }

    function test_RejectsFeeOnTransferDeposit() public {
        MockFeeOnTransferERC20 feeToken = new MockFeeOnTransferERC20("Fee", "FEE", 250);
        feeToken.mint(funder, 100 ether);
        vm.prank(funder);
        feeToken.approve(address(escrow), 100 ether);
        uint256 fee = (100 ether * 250) / 10_000;
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(IEscrow.DepositAmountMismatch.selector, 100 ether, 100 ether - fee));
        escrow.deposit(K1, IEscrow.AssetKind.ERC20, address(feeToken), funder, 0, 100 ether);
        assertEq(escrow.remainingOf(K1), 0, "no deposit recorded");
    }

    function test_CannotReleaseMoreThanRemaining() public {
        _depositNative(K1, 1 ether);
        vm.prank(controller);
        escrow.release(K1, payee, 1 ether);
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(IEscrow.InsufficientDeposit.selector, K1, 0, 1));
        escrow.release(K1, payee, 1);
    }

    function test_RecipientReentrancyCannotDrain() public {
        EscrowReenterRecipient attacker = new EscrowReenterRecipient(escrow, K1);
        _depositNative(K1, 5 ether);
        uint256 escrowStart = address(escrow).balance;
        vm.prank(controller);
        escrow.release(K1, address(attacker), 1 ether);
        assertTrue(attacker.tried(), "attacker attempted reentry");
        assertEq(address(attacker).balance, 1 ether, "exactly the released amount");
        assertEq(address(escrow).balance, escrowStart - 1 ether, "no extra drained");
        assertEq(escrow.remainingOf(K1), 4 ether, "remaining correct");
    }

    // =====================================================================
    // ERC-721 custody
    // =====================================================================

    function test_ERC721_DepositCustodiesReleaseToPayee() public {
        nft.mintToken(funder, TID);
        vm.prank(funder);
        nft.setApprovalForAll(address(escrow), true);

        // Deposit pulls the NFT into escrow custody.
        vm.prank(controller);
        escrow.deposit(KN, IEscrow.AssetKind.ERC721, address(nft), funder, TID, 1);
        assertEq(nft.ownerOf(TID), address(escrow), "escrow custodies the NFT");
        assertEq(escrow.remainingOf(KN), 1, "remaining is 1");
        (IEscrow.AssetKind kind, address tk, address fdr, uint256 tid, uint256 amt, ) = escrow.deposits(KN);
        assertEq(uint8(kind), uint8(IEscrow.AssetKind.ERC721), "kind erc721");
        assertEq(tk, address(nft));
        assertEq(fdr, funder);
        assertEq(tid, TID);
        assertEq(amt, 1);

        // Release moves the whole NFT to the payee.
        vm.prank(controller);
        escrow.release(KN, payee, 1);
        assertEq(nft.ownerOf(TID), payee, "payee received the NFT");
        assertEq(escrow.remainingOf(KN), 0, "deposit drained");
    }

    function test_ERC721_RefundReturnsToFunder() public {
        nft.mintToken(funder, TID);
        vm.prank(funder);
        nft.setApprovalForAll(address(escrow), true);
        vm.prank(controller);
        escrow.deposit(KN, IEscrow.AssetKind.ERC721, address(nft), funder, TID, 1);

        vm.prank(controller);
        escrow.refund(KN, funder, 1);
        assertEq(nft.ownerOf(TID), funder, "funder got the NFT back");
        assertEq(escrow.remainingOf(KN), 0, "deposit drained");
    }

    function test_ERC721_DepositRejectsAmountNotOne() public {
        nft.mintToken(funder, TID);
        vm.prank(funder);
        nft.setApprovalForAll(address(escrow), true);
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(IEscrow.BadERC721Amount.selector, 2));
        escrow.deposit(KN, IEscrow.AssetKind.ERC721, address(nft), funder, TID, 2);
    }

    function test_ERC721_PartialReleaseImpossible() public {
        // An ERC-721 can only move whole. Since amount is always 1, "partial" means asking
        // for 0 (ZeroAmount) — there is no fractional NFT. Prove a >remaining ask reverts and
        // that after a whole release nothing else can move.
        nft.mintToken(funder, TID);
        vm.prank(funder);
        nft.setApprovalForAll(address(escrow), true);
        vm.prank(controller);
        escrow.deposit(KN, IEscrow.AssetKind.ERC721, address(nft), funder, TID, 1);

        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(IEscrow.InsufficientDeposit.selector, KN, 1, 2));
        escrow.release(KN, payee, 2);

        // Whole release, then a second release reverts (drained) — no double-release.
        vm.prank(controller);
        escrow.release(KN, payee, 1);
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(IEscrow.InsufficientDeposit.selector, KN, 0, 1));
        escrow.release(KN, payee, 1);
    }

    function test_ERC721_UnsolicitedTransferRejected() public {
        // A direct safeTransfer into the escrow (outside a deposit() pull) must revert, so the
        // escrow only ever holds NFTs its ledger tracks.
        nft.mintToken(funder, TID);
        vm.prank(funder);
        vm.expectRevert(IEscrow.UnsolicitedTransfer.selector);
        nft.safeTransferFrom(funder, address(escrow), TID);
        assertEq(nft.ownerOf(TID), funder, "NFT stayed with the sender");
    }

    function test_ERC721_ReentrancyOnReleaseCallbackBlocked() public {
        // Two NFT deposits. Releasing deposit A to a malicious receiver that re-enters to
        // release deposit B: the guard blocks the re-entry, B is untouched, A completes.
        ReentrantNftRecipient attacker = new ReentrantNftRecipient(escrow);
        nft.mintToken(funder, TID); //   deposit A
        nft.mintToken(funder, TID + 1); // deposit B
        vm.prank(funder);
        nft.setApprovalForAll(address(escrow), true);
        vm.startPrank(controller);
        escrow.deposit(K1, IEscrow.AssetKind.ERC721, address(nft), funder, TID, 1);
        escrow.deposit(K2, IEscrow.AssetKind.ERC721, address(nft), funder, TID + 1, 1);
        vm.stopPrank();
        attacker.setTarget(K2);

        vm.prank(controller);
        escrow.release(K1, address(attacker), 1);

        assertTrue(attacker.tried(), "attacker attempted reentry");
        assertEq(nft.ownerOf(TID), address(attacker), "A delivered");
        assertEq(nft.ownerOf(TID + 1), address(escrow), "B NOT drained by reentry");
        assertEq(escrow.remainingOf(K2), 1, "B remaining intact");
    }

    // =====================================================================
    // ERC-1155 custody
    // =====================================================================

    function test_ERC1155_DepositCustodiesReleaseQuantity() public {
        multi.mint(funder, TID, 10);
        vm.prank(funder);
        multi.setApprovalForAll(address(escrow), true);

        vm.prank(controller);
        escrow.deposit(KN, IEscrow.AssetKind.ERC1155, address(multi), funder, TID, 10);
        assertEq(multi.balanceOf(address(escrow), TID), 10, "escrow holds quantity");
        assertEq(escrow.remainingOf(KN), 10, "remaining 10");

        // ERC-1155 is genuinely divisible at the escrow layer: release 6, refund 4.
        vm.prank(controller);
        escrow.release(KN, payee, 6);
        vm.prank(controller);
        escrow.refund(KN, funder, 4);
        assertEq(multi.balanceOf(payee, TID), 6, "payee got 6");
        assertEq(multi.balanceOf(funder, TID), 4, "funder got 4 back");
        assertEq(multi.balanceOf(address(escrow), TID), 0, "escrow drained");
        assertEq(escrow.remainingOf(KN), 0, "deposit drained");
    }

    function test_ERC1155_CannotReleaseMoreThanQuantity() public {
        multi.mint(funder, TID, 5);
        vm.prank(funder);
        multi.setApprovalForAll(address(escrow), true);
        vm.prank(controller);
        escrow.deposit(KN, IEscrow.AssetKind.ERC1155, address(multi), funder, TID, 5);
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(IEscrow.InsufficientDeposit.selector, KN, 5, 6));
        escrow.release(KN, payee, 6);
    }

    function test_ERC1155_UnsolicitedTransferRejected() public {
        multi.mint(funder, TID, 3);
        vm.prank(funder);
        vm.expectRevert(IEscrow.UnsolicitedTransfer.selector);
        multi.safeTransferFrom(funder, address(escrow), TID, 3, "");
    }

    function test_ERC1155_UnsolicitedBatchTransferRejected() public {
        multi.mint(funder, TID, 3);
        multi.mint(funder, TID + 1, 4);
        uint256[] memory ids = new uint256[](2);
        ids[0] = TID;
        ids[1] = TID + 1;
        uint256[] memory amts = new uint256[](2);
        amts[0] = 3;
        amts[1] = 4;
        vm.prank(funder);
        vm.expectRevert(IEscrow.UnsolicitedTransfer.selector);
        multi.safeBatchTransferFrom(funder, address(escrow), ids, amts, "");
    }

    // =====================================================================
    // 721 vs 1155 not confusable: same key space, distinct kinds/accounting
    // =====================================================================

    function test_721And1155_NotConfusable() public {
        nft.mintToken(funder, TID);
        multi.mint(funder, TID, 9); // SAME numeric id, different asset
        vm.startPrank(funder);
        nft.setApprovalForAll(address(escrow), true);
        multi.setApprovalForAll(address(escrow), true);
        vm.stopPrank();

        vm.startPrank(controller);
        escrow.deposit(K1, IEscrow.AssetKind.ERC721, address(nft), funder, TID, 1);
        escrow.deposit(K2, IEscrow.AssetKind.ERC1155, address(multi), funder, TID, 9);
        vm.stopPrank();

        // The ERC-721 deposit is indivisible-1; the ERC-1155 deposit is a quantity of 9. They
        // are keyed separately and never cross.
        (IEscrow.AssetKind k1, , , , uint256 a1, ) = escrow.deposits(K1);
        (IEscrow.AssetKind k2, , , , uint256 a2, ) = escrow.deposits(K2);
        assertEq(uint8(k1), uint8(IEscrow.AssetKind.ERC721));
        assertEq(uint8(k2), uint8(IEscrow.AssetKind.ERC1155));
        assertEq(a1, 1);
        assertEq(a2, 9);

        // Releasing the ERC-1155 quantity does not touch the ERC-721 token and vice-versa.
        vm.prank(controller);
        escrow.release(K2, payee, 9);
        assertEq(multi.balanceOf(payee, TID), 9, "1155 released");
        assertEq(nft.ownerOf(TID), address(escrow), "721 still escrowed");
        vm.prank(controller);
        escrow.release(K1, payee, 1);
        assertEq(nft.ownerOf(TID), payee, "721 released");
    }

    // =====================================================================
    // Credit-on-failure pull-payment (H1)
    // =====================================================================

    function test_Credit_OnNativeFailure_ThenWithdraw() public {
        ToggleNativeRecipient r = new ToggleNativeRecipient(escrow); // accepting=false
        _depositNative(K1, 3 ether);
        uint256 escrowStart = address(escrow).balance;

        // Release to a recipient that reverts on receipt: it is CREDITED, not reverted.
        vm.prank(controller);
        bool delivered = escrow.release(K1, address(r), 3 ether);
        assertFalse(delivered, "not delivered -> credited");
        assertEq(address(r).balance, 0, "recipient got nothing");
        assertEq(address(escrow).balance, escrowStart, "asset stayed in escrow");
        assertEq(escrow.creditOf(address(r), IEscrow.AssetKind.Native, NATIVE, 0), 3 ether, "credited");
        assertEq(escrow.remainingOf(K1), 0, "deposit still debited (single-spend preserved)");

        // Recipient fixes itself and pulls the credit.
        r.setAccepting(true);
        r.pull(IEscrow.AssetKind.Native, NATIVE, 0);
        assertEq(address(r).balance, 3 ether, "withdrew the credit");
        assertEq(escrow.creditOf(address(r), IEscrow.AssetKind.Native, NATIVE, 0), 0, "credit cleared");
    }

    function test_Withdraw_StillUnable_KeepsCredit() public {
        ToggleNativeRecipient r = new ToggleNativeRecipient(escrow);
        _depositNative(K1, 1 ether);
        vm.prank(controller);
        escrow.release(K1, address(r), 1 ether); // credited (recipient can't receive)

        // Withdrawing while STILL unable reverts and the credit is preserved (not lost).
        vm.prank(address(r));
        vm.expectRevert(IEscrow.WithdrawFailed.selector);
        escrow.withdraw(IEscrow.AssetKind.Native, NATIVE, 0);
        assertEq(escrow.creditOf(address(r), IEscrow.AssetKind.Native, NATIVE, 0), 1 ether, "credit preserved");
    }

    function test_Withdraw_NoCreditReverts() public {
        vm.prank(payee);
        vm.expectRevert(IEscrow.NoCredit.selector);
        escrow.withdraw(IEscrow.AssetKind.Native, NATIVE, 0);
    }

    function test_ReassignCredit_OnlyController_MovesClaim() public {
        ToggleNativeRecipient r = new ToggleNativeRecipient(escrow);
        _depositNative(K1, 2 ether);
        vm.prank(controller);
        escrow.release(K1, address(r), 2 ether); // credited to r

        // Non-controller cannot reassign.
        vm.expectRevert(IEscrow.OnlyController.selector);
        escrow.reassignCredit(address(r), payee, IEscrow.AssetKind.Native, NATIVE, 0, 2 ether);

        // Reassigning MORE than the source holds reverts (bounds recovery).
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(IEscrow.InsufficientCredit.selector, 2 ether, 3 ether));
        escrow.reassignCredit(address(r), payee, IEscrow.AssetKind.Native, NATIVE, 0, 3 ether);

        // Controller moves the EXACT claim from r to payee.
        vm.prank(controller);
        escrow.reassignCredit(address(r), payee, IEscrow.AssetKind.Native, NATIVE, 0, 2 ether);
        assertEq(escrow.creditOf(address(r), IEscrow.AssetKind.Native, NATIVE, 0), 0, "moved out of r");
        assertEq(escrow.creditOf(payee, IEscrow.AssetKind.Native, NATIVE, 0), 2 ether, "moved to payee");

        // payee (an EOA) withdraws successfully.
        uint256 before = payee.balance;
        vm.prank(payee);
        escrow.withdraw(IEscrow.AssetKind.Native, NATIVE, 0);
        assertEq(payee.balance, before + 2 ether, "payee pulled the reassigned credit");
    }

    // --- helpers ---

    function _depositNative(bytes32 key, uint256 amount) internal {
        vm.deal(controller, controller.balance + amount);
        vm.prank(controller);
        escrow.deposit{value: amount}(key, IEscrow.AssetKind.Native, NATIVE, funder, 0, amount);
    }
}
