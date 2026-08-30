// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Lux Industries Inc
pragma solidity ^0.8.31;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { PublicSaleV1 } from "../contracts/deployables/public-sale/PublicSaleV1.sol";
import { IPublicSaleV1 } from "../contracts/interfaces/dao/deployables/IPublicSaleV1.sol";
import { KYCVerifierV1 } from "../contracts/services/kyc/KYCVerifierV1.sol";
import { IKYCVerifierV1 } from "../contracts/interfaces/dao/services/IKYCVerifierV1.sol";

contract Coin is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) { }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// @title PublicSaleTest
/// @notice The raise, driven.
///
/// This is the only contract in the tree that takes money for an offering —
/// commitments in the chain's own coin or an ERC20, sale tokens escrowed up
/// front, settlement, refunds, a protocol fee — and it had no test of any kind.
/// Neither did `KYCVerifierV1`, which is the single gate standing in front of
/// it. 2,592 tests in this repo and none of them touched the till.
///
/// What is asserted here is the part an issuer is choosing between when they
/// pick a raise size. $5M and $75M are the Reg CF and Reg A+ Tier 2 rungs, and
/// on this contract the rung is `maximumTotalCommitment` — a number in the
/// initializer, enforced on every commitment. So the cap is asserted at both
/// rungs, at the boundary rather than somewhere safely inside it.
///
/// Note what this sale is NOT: it never reads the securities register. No
/// identity, no claims, no jurisdiction, no holding period — its whole notion
/// of eligibility is one signed attestation from an off-chain verifier. That is
/// the right shape for a raise in an asset that is not a security, and it is
/// not the Reg CF or Reg A+ path, which needs the register to be the thing
/// enforcing eligibility. Nothing in this repository connects the two.
contract PublicSaleTest is Test {
    bytes32 constant TYPEHASH =
        keccak256("VerificationData(address operator,address account,uint48 signatureExpiration,uint256 nonce)");

    uint256 constant PRECISION = 1e18;
    uint256 constant FIVE_MILLION = 5_000_000e18;
    uint256 constant SEVENTY_FIVE_MILLION = 75_000_000e18;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address proceeds = makeAddr("proceeds");
    address protocol = makeAddr("protocol");
    address buyer = makeAddr("buyer");

    uint256 verifierKey = 0xA11CE;
    address verifierAddr;

    Coin usd;
    Coin paper;
    KYCVerifierV1 kyc;
    PublicSaleV1 sale;

    function setUp() public {
        verifierAddr = vm.addr(verifierKey);
        usd = new Coin("Dollar", "USD");
        paper = new Coin("Paper", "PAPR");
        kyc = new KYCVerifierV1(owner, verifierAddr);
    }

    /// A sale whose cap is the rung being tested.
    function _open(uint256 cap) internal {
        paper.mint(treasury, (cap * PRECISION) / PRECISION);
        PublicSaleV1 impl = new PublicSaleV1();

        vm.prank(treasury);
        paper.approve(vm.computeCreateAddress(address(this), vm.getNonce(address(this))), type(uint256).max);

        sale = PublicSaleV1(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(
                        PublicSaleV1.initialize,
                        (IPublicSaleV1.InitializerParams({
                                saleStartTimestamp: uint48(block.timestamp + 1),
                                saleEndTimestamp: uint48(block.timestamp + 30 days),
                                owner: owner,
                                saleTokenHolder: treasury,
                                commitmentToken: address(usd),
                                saleToken: address(paper),
                                kycVerifier: address(kyc),
                                saleProceedsReceiver: proceeds,
                                protocolFeeReceiver: protocol,
                                minimumCommitment: 1e18,
                                maximumCommitment: type(uint256).max,
                                minimumTotalCommitment: 1e18,
                                maximumTotalCommitment: cap,
                                saleTokenPrice: PRECISION,
                                decreaseCommitmentFee: 0,
                                protocolFee: 0
                            }))
                    )
                )
            )
        );
        vm.warp(block.timestamp + 2);
    }

    /// The verifier's attestation for one commitment. The nonce moves every
    /// time it is spent, so a signature is good for exactly one.
    function _attest(address who) internal view returns (bytes memory, uint48) {
        uint48 expiry = uint48(block.timestamp + 1 hours);
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01", _domain(), keccak256(abi.encode(TYPEHASH, address(sale), who, expiry, kyc.nonce(who)))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(verifierKey, digest);
        return (abi.encodePacked(r, s, v), expiry);
    }

    function _domain() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("KYCVerifier"),
                keccak256("1"),
                block.chainid,
                address(kyc)
            )
        );
    }

    function _commit(address who, uint256 amount) internal {
        usd.mint(who, amount);
        (bytes memory sig, uint48 expiry) = _attest(who);
        vm.startPrank(who);
        usd.approve(address(sale), amount);
        sale.increaseCommitmentERC20(amount, sig, expiry);
        vm.stopPrank();
    }

    /// A rung, at its edge, refused two different ways — which is the part
    /// worth knowing and the part I got wrong first.
    ///
    /// A commitment that would overshoot the cap is refused as
    /// `MaximumTotalCommitment`. A commitment that fills it EXACTLY is
    /// accepted, and closes the sale: `saleState` reads the cap, so the sale
    /// stops being ACTIVE the moment it is met, and the next buyer is turned
    /// away as `SaleNotActive` rather than by the cap check, which never runs.
    /// Both are correct. They are different refusals and an integrator
    /// rendering one message for "sale full" will show the wrong one half the
    /// time.
    function _rung(uint256 cap) internal {
        _open(cap);

        // Up to one dollar short of the rung.
        _commit(buyer, cap - 1e18);
        assertEq(sale.totalCommitments(), cap - 1e18);

        // Two dollars would overshoot it.
        address over = makeAddr("over");
        usd.mint(over, 2e18);
        (bytes memory sig, uint48 expiry) = _attest(over);
        vm.startPrank(over);
        usd.approve(address(sale), 2e18);
        vm.expectRevert(IPublicSaleV1.MaximumTotalCommitment.selector);
        sale.increaseCommitmentERC20(2e18, sig, expiry);
        vm.stopPrank();

        // One fills it exactly, and closes it.
        _commit(over, 1e18);
        assertEq(sale.totalCommitments(), cap, "the rung is reachable to the dollar");
        assertTrue(sale.saleState() != IPublicSaleV1.SaleState.ACTIVE, "a filled sale is no longer active");

        // So the next buyer meets a closed sale, not a full one.
        address late = makeAddr("late");
        usd.mint(late, 1e18);
        (bytes memory lateSig, uint48 lateExpiry) = _attest(late);
        vm.startPrank(late);
        usd.approve(address(sale), 1e18);
        vm.expectRevert(IPublicSaleV1.SaleNotActive.selector);
        sale.increaseCommitmentERC20(1e18, lateSig, lateExpiry);
        vm.stopPrank();
    }

    /// The $75M rung — Reg A+ Tier 2's ceiling, if the paper is a security.
    function test_theSeventyFiveMillionCapHoldsAtTheEdge() public {
        _rung(SEVENTY_FIVE_MILLION);
    }

    /// And the $5M rung — Reg CF's. The same machine with a smaller number,
    /// which is the point: a rung is configuration here, not a code path.
    function test_theFiveMillionCapHoldsAtTheEdge() public {
        _rung(FIVE_MILLION);
    }

    /// The gate is the whole eligibility story here, so it has to be real.
    function test_anUnattestedBuyerIsRefused() public {
        _open(FIVE_MILLION);

        usd.mint(buyer, 100e18);
        // Signed by somebody who is not the verifier.
        uint48 expiry = uint48(block.timestamp + 1 hours);
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01", _domain(), keccak256(abi.encode(TYPEHASH, address(sale), buyer, expiry, kyc.nonce(buyer)))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBAD, digest);

        vm.startPrank(buyer);
        usd.approve(address(sale), 100e18);
        vm.expectRevert(IKYCVerifierV1.InvalidSignature.selector);
        sale.increaseCommitmentERC20(100e18, abi.encodePacked(r, s, v), expiry);
        vm.stopPrank();
    }

    /// An attestation is good for one commitment. Replaying it is refused,
    /// because the nonce moved when it was spent.
    function test_anAttestationCannotBeSpentTwice() public {
        _open(FIVE_MILLION);

        usd.mint(buyer, 200e18);
        (bytes memory sig, uint48 expiry) = _attest(buyer);
        vm.startPrank(buyer);
        usd.approve(address(sale), 200e18);
        sale.increaseCommitmentERC20(100e18, sig, expiry);
        vm.expectRevert(IKYCVerifierV1.InvalidSignature.selector);
        sale.increaseCommitmentERC20(100e18, sig, expiry);
        vm.stopPrank();
    }

    /// The paper is escrowed when the sale opens, so a raise that fills cannot
    /// find the issuer has nothing to deliver.
    function test_thePaperIsEscrowedBeforeAnyoneCommits() public {
        _open(SEVENTY_FIVE_MILLION);
        assertEq(paper.balanceOf(address(sale)), SEVENTY_FIVE_MILLION, "the whole raise is already covered");
        assertEq(paper.balanceOf(treasury), 0);
    }
}
