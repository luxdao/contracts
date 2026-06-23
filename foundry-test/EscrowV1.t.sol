// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {EscrowV1} from "../contracts/deployables/bounty/EscrowV1.sol";
import {IEscrowV1} from "../contracts/interfaces/dao/deployables/IEscrowV1.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";

/// @dev Reenters the escrow on native receipt. Because the escrow is onlyController,
/// a reenter from the payout recipient can't move funds; this proves the recipient
/// path cannot recurse into release/refund regardless.
contract EscrowReenterRecipient {
    IEscrowV1 public immutable escrow;
    bytes32 public immutable depositId;
    bool public tried;

    constructor(IEscrowV1 escrow_, bytes32 depositId_) {
        escrow = escrow_;
        depositId = depositId_;
    }

    receive() external payable {
        if (!tried) {
            tried = true;
            // Attempt to recurse -- must revert (OnlyController), swallowed here.
            try escrow.release(depositId, address(this), 1) {} catch {}
        }
    }
}

/// @notice Direct unit proofs for EscrowV1: conservation, single-spend, controller
/// authorization, native + ERC-20 paths, and the deposit/release/refund accounting.
contract EscrowV1Test is Test {
    EscrowV1 internal escrow;
    MockERC20 internal token;

    address internal owner = address(0x0420);
    address internal controller = address(0xC0117401);
    address internal funder = address(0xF4DE7);
    address internal payee = address(0x9A4EE);

    bytes32 internal constant K1 = keccak256("deposit-1");
    bytes32 internal constant K2 = keccak256("deposit-2");

    address internal constant NATIVE = address(0);

    function setUp() public {
        EscrowV1 impl = new EscrowV1();
        escrow = EscrowV1(
            payable(
                address(
                    new ERC1967Proxy(address(impl), abi.encodeCall(EscrowV1.initialize, (owner, controller)))
                )
            )
        );
        token = new MockERC20("Work Token", "WORK", 18);
    }

    // --- Wiring / deployability ---

    function test_InitializesAsProxy() public view {
        assertEq(escrow.controller(), controller, "controller set");
        assertEq(escrow.owner(), owner, "owner set");
        assertEq(escrow.version(), 1, "version");
        assertTrue(escrow.deploymentBlock() > 0, "deployment block recorded");
        assertTrue(escrow.supportsInterface(type(IEscrowV1).interfaceId), "ERC165 IEscrowV1");
    }

    function test_RevertsOnZeroController() public {
        EscrowV1 impl = new EscrowV1();
        vm.expectRevert(IEscrowV1.InvalidController.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(EscrowV1.initialize, (owner, address(0))));
    }

    function test_SetUpInitializerDecodes() public {
        EscrowV1 impl = new EscrowV1();
        EscrowV1 e = EscrowV1(
            payable(
                address(new ERC1967Proxy(address(impl), abi.encodeCall(EscrowV1.setUp, (abi.encode(owner, controller)))))
            )
        );
        assertEq(e.controller(), controller);
        assertEq(e.owner(), owner);
    }

    // --- Authorization ---

    function test_OnlyControllerCanDeposit() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(IEscrowV1.OnlyController.selector);
        escrow.deposit{value: 1 ether}(K1, NATIVE, funder, 1 ether);
    }

    function test_OnlyControllerCanRelease() public {
        _depositNative(K1, 1 ether);
        vm.expectRevert(IEscrowV1.OnlyController.selector);
        escrow.release(K1, payee, 1 ether);
    }

    function test_OnlyControllerCanRefund() public {
        _depositNative(K1, 1 ether);
        vm.expectRevert(IEscrowV1.OnlyController.selector);
        escrow.refund(K1, funder, 1 ether);
    }

    // --- Native happy path + conservation ---

    function test_NativeDepositReleaseRefund_Conserves() public {
        uint256 escrowStart = address(escrow).balance;

        _depositNative(K1, 3 ether);
        assertEq(address(escrow).balance, escrowStart + 3 ether, "escrow holds deposit");
        assertEq(escrow.remainingOf(K1), 3 ether);

        // Release 2, refund 1 => deposit fully drained, conservation holds.
        uint256 payeeStart = payee.balance;
        uint256 funderStart = funder.balance;

        vm.prank(controller);
        escrow.release(K1, payee, 2 ether);
        vm.prank(controller);
        escrow.refund(K1, funder, 1 ether);

        assertEq(payee.balance, payeeStart + 2 ether, "payee got release");
        assertEq(funder.balance, funderStart + 1 ether, "funder got refund");
        assertEq(escrow.remainingOf(K1), 0, "deposit drained");
        assertEq(address(escrow).balance, escrowStart, "escrow net zero -- conserved");
    }

    function test_NativeValueMustMatchAmount() public {
        vm.deal(controller, 5 ether);
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(IEscrowV1.NativeValueMismatch.selector, 2 ether, 1 ether));
        escrow.deposit{value: 1 ether}(K1, NATIVE, funder, 2 ether);
    }

    // --- ERC-20 happy path + conservation ---

    function test_ERC20DepositReleaseRefund_Conserves() public {
        token.mint(funder, 100 ether);
        vm.prank(funder);
        token.approve(address(escrow), 100 ether);

        vm.prank(controller);
        escrow.deposit(K1, address(token), funder, 100 ether);
        assertEq(token.balanceOf(address(escrow)), 100 ether, "escrow holds tokens");
        assertEq(escrow.remainingOf(K1), 100 ether);

        vm.prank(controller);
        escrow.release(K1, payee, 60 ether);
        vm.prank(controller);
        escrow.refund(K1, funder, 40 ether);

        assertEq(token.balanceOf(payee), 60 ether, "payee release");
        assertEq(token.balanceOf(funder), 40 ether, "funder refund");
        assertEq(token.balanceOf(address(escrow)), 0, "escrow drained -- conserved");
        assertEq(escrow.remainingOf(K1), 0);
    }

    function test_ERC20MustNotCarryNativeValue() public {
        token.mint(funder, 10 ether);
        vm.prank(funder);
        token.approve(address(escrow), 10 ether);
        vm.deal(controller, 1 ether);
        vm.prank(controller);
        vm.expectRevert(IEscrowV1.UnexpectedNativeValue.selector);
        escrow.deposit{value: 1 wei}(K1, address(token), funder, 10 ether);
    }

    // --- Single-spend invariant ---

    function test_CannotReleaseMoreThanRemaining() public {
        _depositNative(K1, 1 ether);
        vm.prank(controller);
        escrow.release(K1, payee, 1 ether);
        // remaining is 0 now
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(IEscrowV1.InsufficientDeposit.selector, K1, 0, 1));
        escrow.release(K1, payee, 1);
    }

    function test_PartialReleasesNeverExceedDeposit() public {
        _depositNative(K1, 10 ether);
        vm.startPrank(controller);
        escrow.release(K1, payee, 4 ether);
        escrow.release(K1, payee, 4 ether);
        // only 2 ether remains; asking for 3 must revert
        vm.expectRevert(abi.encodeWithSelector(IEscrowV1.InsufficientDeposit.selector, K1, 2 ether, 3 ether));
        escrow.release(K1, payee, 3 ether);
        vm.stopPrank();
        assertEq(escrow.remainingOf(K1), 2 ether);
    }

    function test_DepositIdCannotBeReused() public {
        _depositNative(K1, 1 ether);
        vm.deal(controller, 1 ether);
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(IEscrowV1.DepositExists.selector, K1));
        escrow.deposit{value: 1 ether}(K1, NATIVE, funder, 1 ether);
    }

    function test_UnknownDepositReverts() public {
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(IEscrowV1.UnknownDeposit.selector, K2));
        escrow.release(K2, payee, 1);
    }

    function test_ZeroAmountRejected() public {
        vm.prank(controller);
        vm.expectRevert(IEscrowV1.ZeroAmount.selector);
        escrow.deposit(K1, address(token), funder, 0);
    }

    function test_ZeroRecipientRejected() public {
        _depositNative(K1, 1 ether);
        vm.prank(controller);
        vm.expectRevert(IEscrowV1.InvalidRecipient.selector);
        escrow.release(K1, address(0), 1);
    }

    // --- Two deposits are independent (accounting isolation) ---

    function test_TwoDepositsAreIndependent() public {
        _depositNative(K1, 2 ether);
        token.mint(funder, 5 ether);
        vm.prank(funder);
        token.approve(address(escrow), 5 ether);
        vm.prank(controller);
        escrow.deposit(K2, address(token), funder, 5 ether);

        // Drain K1 fully; K2 untouched.
        vm.prank(controller);
        escrow.release(K1, payee, 2 ether);
        assertEq(escrow.remainingOf(K1), 0);
        assertEq(escrow.remainingOf(K2), 5 ether, "other deposit unaffected");
    }

    // --- Reentrancy on the recipient path ---

    function test_RecipientReentrancyCannotDrain() public {
        EscrowReenterRecipient attacker = new EscrowReenterRecipient(escrow, K1);
        _depositNative(K1, 5 ether);

        uint256 escrowStart = address(escrow).balance;
        // Release 1 ether to the attacker; its receive() tries to recurse and fails
        // silently (OnlyController). Exactly 1 ether leaves, nothing more.
        vm.prank(controller);
        escrow.release(K1, address(attacker), 1 ether);

        assertTrue(attacker.tried(), "attacker attempted reentry");
        assertEq(address(attacker).balance, 1 ether, "exactly the released amount");
        assertEq(address(escrow).balance, escrowStart - 1 ether, "no extra drained");
        assertEq(escrow.remainingOf(K1), 4 ether, "remaining correct");
    }

    // --- helpers ---

    function _depositNative(bytes32 key, uint256 amount) internal {
        vm.deal(controller, controller.balance + amount);
        vm.prank(controller);
        escrow.deposit{value: amount}(key, NATIVE, funder, amount);
    }
}
