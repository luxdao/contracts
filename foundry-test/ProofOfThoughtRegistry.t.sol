// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ProofOfThoughtRegistry} from "../contracts/deployables/thinking/ProofOfThoughtRegistry.sol";
import {IProofOfThoughtRegistry} from "../contracts/deployables/thinking/interfaces/IProofOfThoughtRegistry.sol";

/// @notice PR1 — Proof-of-Thought receipt registry. Proves the on-chain ledger
/// of paid cognition: register, replay-safety, deterministic ids, enumeration,
/// and the Tier-1 (operator=0) vs Tier-2 (operator set) records.
contract ProofOfThoughtRegistryTest is Test {
    ProofOfThoughtRegistry reg;

    bytes32 constant MODEL = keccak256("zen-nano");
    bytes32 constant PROMPT = keccak256("should proposal 42 activate?");
    bytes32 constant OUTPUT = keccak256("YES@8000");
    bytes32 constant PAYMENT = keccak256("x402:0xpaymenthash");
    bytes32 constant QUORUM = keccak256("receipt_root:0xabc");
    address constant PAYER = address(0xA11CE);
    address constant OPERATOR = address(0x09E7A7);

    function setUp() public {
        reg = new ProofOfThoughtRegistry(address(this)); // test is admin
        reg.setRecorder(address(this), true); // ...and an authorized recorder
    }

    // ---- access control ---------------------------------------------------

    function test_Register_OnlyRecorder() public {
        address stranger = address(0xBAD);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ProofOfThoughtRegistry.NotRecorder.selector, stranger));
        reg.register(MODEL, PROMPT, OUTPUT, PAYMENT, QUORUM, PAYER, OPERATOR, 1);
    }

    function test_SetRecorder_OnlyAdmin() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(ProofOfThoughtRegistry.NotAdmin.selector);
        reg.setRecorder(address(0xBAD), true);
    }

    // ---- determinism ------------------------------------------------------

    function test_ComputeReceiptId_Deterministic() public view {
        bytes32 a = reg.computeReceiptId(MODEL, PROMPT, OUTPUT, PAYMENT, PAYER, OPERATOR);
        bytes32 b = reg.computeReceiptId(MODEL, PROMPT, OUTPUT, PAYMENT, PAYER, OPERATOR);
        assertEq(a, b, "receiptId must be deterministic");
        // any field change => different id
        assertTrue(a != reg.computeReceiptId(MODEL, PROMPT, OUTPUT, PAYMENT, PAYER, address(0)), "operator binds");
        assertTrue(a != reg.computeReceiptId(MODEL, PROMPT, keccak256("NO"), PAYMENT, PAYER, OPERATOR), "output binds");
        assertTrue(a != reg.computeReceiptId(MODEL, PROMPT, OUTPUT, keccak256("other-pay"), PAYER, OPERATOR), "payment binds");
    }

    // ---- register happy path + event -------------------------------------

    function test_Register_RecordsAndEmits() public {
        bytes32 expectedId = reg.computeReceiptId(MODEL, PROMPT, OUTPUT, PAYMENT, PAYER, OPERATOR);

        vm.expectEmit(true, true, true, true);
        emit IProofOfThoughtRegistry.ThoughtRegistered(
            expectedId, MODEL, PAYER, OPERATOR, PROMPT, OUTPUT, PAYMENT, QUORUM, uint96(1_000_000)
        );

        bytes32 id = reg.register(MODEL, PROMPT, OUTPUT, PAYMENT, QUORUM, PAYER, OPERATOR, uint96(1_000_000));
        assertEq(id, expectedId, "returned id");
        assertTrue(reg.exists(id), "exists");
        assertEq(reg.receiptCount(), 1, "count");
        assertEq(reg.receiptAt(0), id, "enumeration");

        IProofOfThoughtRegistry.ThoughtReceipt memory r = reg.getReceipt(id);
        assertEq(r.modelId, MODEL);
        assertEq(r.promptHash, PROMPT);
        assertEq(r.outputHash, OUTPUT);
        assertEq(r.paymentHash, PAYMENT);
        assertEq(r.quorumProof, QUORUM);
        assertEq(r.payer, PAYER);
        assertEq(r.operator, OPERATOR);
        assertEq(r.cost, uint96(1_000_000));
        assertEq(r.blockNumber, uint64(block.number));
        assertEq(r.registeredAt, uint64(block.timestamp));
    }

    // ---- replay safety ----------------------------------------------------

    function test_Register_RejectsDuplicate() public {
        reg.register(MODEL, PROMPT, OUTPUT, PAYMENT, QUORUM, PAYER, OPERATOR, 1);
        bytes32 id = reg.computeReceiptId(MODEL, PROMPT, OUTPUT, PAYMENT, PAYER, OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(IProofOfThoughtRegistry.ReceiptAlreadyExists.selector, id));
        reg.register(MODEL, PROMPT, OUTPUT, PAYMENT, QUORUM, PAYER, OPERATOR, 1);
    }

    // ---- required-field guards -------------------------------------------

    function test_Register_RejectsZeroModel() public {
        vm.expectRevert(IProofOfThoughtRegistry.ZeroModelId.selector);
        reg.register(bytes32(0), PROMPT, OUTPUT, PAYMENT, QUORUM, PAYER, OPERATOR, 1);
    }

    function test_Register_RejectsZeroPayment() public {
        vm.expectRevert(IProofOfThoughtRegistry.ZeroPaymentHash.selector);
        reg.register(MODEL, PROMPT, OUTPUT, bytes32(0), QUORUM, PAYER, OPERATOR, 1);
    }

    function test_Register_RejectsZeroPayer() public {
        vm.expectRevert(IProofOfThoughtRegistry.ZeroPayer.selector);
        reg.register(MODEL, PROMPT, OUTPUT, PAYMENT, QUORUM, address(0), OPERATOR, 1);
    }

    function test_GetReceipt_RejectsUnknown() public {
        vm.expectRevert(abi.encodeWithSelector(IProofOfThoughtRegistry.UnknownReceipt.selector, bytes32(uint256(0xdead))));
        reg.getReceipt(bytes32(uint256(0xdead)));
    }

    // ---- both tiers + enumeration ----------------------------------------

    function test_Tiers_T1NoOperator_T2WithOperator() public {
        // Tier-1: deterministic in-consensus inference, no operator (operator=0).
        bytes32 t1 = reg.register(MODEL, PROMPT, OUTPUT, keccak256("pay-t1"), keccak256("det-marker"), PAYER, address(0), 100);
        // Tier-2: operator-quorum cognition, operator = quorum aggregate.
        bytes32 t2 = reg.register(MODEL, keccak256("p2"), keccak256("o2"), keccak256("pay-t2"), QUORUM, PAYER, OPERATOR, 500);

        assertTrue(t1 != t2, "distinct receipts");
        assertEq(reg.receiptCount(), 2);
        assertEq(reg.getReceipt(t1).operator, address(0), "T1 has no operator");
        assertEq(reg.getReceipt(t2).operator, OPERATOR, "T2 has operator");
        assertEq(reg.receiptAt(0), t1);
        assertEq(reg.receiptAt(1), t2);
    }

    // ---- fuzz: any distinct tuple is independently recordable + recallable -

    function testFuzz_RegisterRoundTrip(bytes32 prompt, bytes32 output, bytes32 pay, uint96 cost) public {
        vm.assume(pay != bytes32(0));
        bytes32 id = reg.register(MODEL, prompt, output, pay, QUORUM, PAYER, OPERATOR, cost);
        IProofOfThoughtRegistry.ThoughtReceipt memory r = reg.getReceipt(id);
        assertEq(r.promptHash, prompt);
        assertEq(r.outputHash, output);
        assertEq(r.paymentHash, pay);
        assertEq(r.cost, cost);
    }
}
