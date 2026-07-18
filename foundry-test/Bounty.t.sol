// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {WorkMarketDeployer} from "../contracts/deployables/bounty/WorkMarketDeployer.sol";
import {Bounty} from "../contracts/deployables/bounty/Bounty.sol";
import {Escrow} from "../contracts/deployables/bounty/Escrow.sol";
import {Reputation} from "../contracts/deployables/bounty/Reputation.sol";
import {IBounty} from "../contracts/interfaces/dao/deployables/IBounty.sol";
import {IEscrow} from "../contracts/interfaces/dao/deployables/IEscrow.sol";
import {IReputation} from "../contracts/interfaces/dao/deployables/IReputation.sol";
import {MockERC721} from "../contracts/mocks/MockERC721.sol";
import {MockERC1155} from "../contracts/mocks/MockERC1155.sol";
import {MockBlocklistERC20} from "../contracts/mocks/MockBlocklistERC20.sol";
import {MockMalformedERC20} from "../contracts/mocks/MockMalformedERC20.sol";
import {MockRevertBalanceOfERC20} from "../contracts/mocks/MockRevertBalanceOfERC20.sol";
import {Karma} from "@luxfi/standard/governance/Karma.sol";
import {KarmaController} from "@luxfi/standard/governance/KarmaController.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

/// @dev A contract worker that can claim/submit and TOGGLE whether it can receive assets. With
/// `accepting=false` every inbound transfer (native / ERC-721 / ERC-1155) reverts, so a payout to
/// it must be CREDITED by the escrow (never brick the settlement). Flipping `accepting=true` lets it
/// withdraw the credit — proving pull-payment recovery for a formerly-unable recipient.
contract ToggleReceiver is IERC721Receiver, IERC1155Receiver {
    Bounty public immutable bounty;
    IEscrow public immutable escrow;
    bool public accepting;

    constructor(Bounty bounty_, IEscrow escrow_) {
        bounty = bounty_;
        escrow = escrow_;
    }

    function setAccepting(bool v) external {
        accepting = v;
    }

    function doClaim(uint256 id, address arb) external payable {
        bounty.claim{value: msg.value}(id, arb);
    }

    function doSubmit(uint256 id, string calldata ref) external {
        bounty.submit(id, ref);
    }

    function withdrawCredit(IEscrow.AssetKind kind, address token, uint256 tokenId) external {
        escrow.withdraw(kind, token, tokenId);
    }

    receive() external payable {
        require(accepting, "no receive");
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        require(accepting, "no 721");
        return IERC721Receiver.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external view returns (bytes4) {
        require(accepting, "no 1155");
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}

/// @dev A contract worker that receives an NFT reward and, on the safeTransfer callback,
/// tries to re-enter accept(). The nonReentrant guard + terminal state must block it.
contract ReentrantNftWorker is IERC721Receiver {
    Bounty public immutable bounty;
    uint256 public bountyId;
    bool public tried;

    constructor(Bounty bounty_) {
        bounty = bounty_;
    }

    function doClaim(uint256 id) external payable {
        bountyId = id;
        bounty.claim{value: msg.value}(id, bounty.bounties(id).arbiter);
    }

    function doSubmit(uint256 id, string calldata ref) external {
        bounty.submit(id, ref);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (!tried) {
            tried = true;
            try bounty.accept(bountyId) {} catch {}
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}

/// @notice Full-lifecycle proofs for the canonical Bounty focused on the additive surface:
/// ERC-721 / ERC-1155 rewards (custody, accept, cancel, reclaim, indivisible dispute),
/// reentrancy on the NFT payout callback, and the money-path invariant that a Karma-bridge
/// failure can NEVER block a worker's payout. Native/ERC-20 parity + conservation is proven
/// end-to-end in DeployDAOLive.t.sol.
contract BountyTest is Test {
    Bounty internal bounty;
    Escrow internal escrow;
    Reputation internal rep;
    Karma internal karma;
    KarmaController internal controller;

    MockERC721 internal nft;
    MockERC1155 internal multi;

    address internal funder = address(0xF4DE7);
    address internal worker = address(0x9A0);
    address internal approver = address(0xA999);
    address internal arbiter = address(0xA981E7);
    address internal stranger = address(0x57A);

    uint256 internal constant STAKE = 1 ether;
    uint256 internal constant TID = 42;
    uint64 internal constant WINDOW = 3 days;
    uint64 internal constant REVIEW = 3 days;
    uint256 internal karmaPer;

    function setUp() public {
        // The test is the org-Safe stand-in: owner of the market + Karma governance admin.
        WorkMarketDeployer wm = new WorkMarketDeployer(
            address(this), address(0), 10e18, address(new Escrow()), address(new Reputation()), address(new Bounty())
        );
        bounty = Bounty(wm.bounty());
        escrow = Escrow(payable(wm.escrow()));
        rep = Reputation(wm.reputation());
        karma = Karma(wm.karma());
        controller = KarmaController(wm.karmaController());
        karmaPer = rep.karmaPerCompletion();

        nft = new MockERC721();
        multi = new MockERC1155();
    }

    // --- reward-spec helpers ---

    function _nftReward(uint256 tokenId_) internal view returns (IBounty.RewardSpec memory) {
        return IBounty.RewardSpec({kind: IEscrow.AssetKind.ERC721, token: address(nft), tokenId: tokenId_, amount: 1});
    }

    function _multiReward(uint256 id_, uint256 qty_) internal view returns (IBounty.RewardSpec memory) {
        return IBounty.RewardSpec({kind: IEscrow.AssetKind.ERC1155, token: address(multi), tokenId: id_, amount: qty_});
    }

    /// @dev propose an ERC-721 reward (native stake), fund it (funder must own+approve NFT).
    function _proposeAndFundNft(uint256 tokenId_) internal returns (uint256 id) {
        nft.mintToken(funder, tokenId_);
        vm.startPrank(funder);
        nft.setApprovalForAll(address(escrow), true);
        id = bounty.propose(_nftReward(tokenId_), address(0), STAKE, approver, arbiter, WINDOW, REVIEW, "nft-issue");
        bounty.fund(id);
        vm.stopPrank();
    }

    // =====================================================================
    // ERC-721 reward — full happy path
    // =====================================================================

    function test_ERC721_Lifecycle_AcceptPaysWorker() public {
        uint256 id = _proposeAndFundNft(TID);
        // Escrow custodies the NFT once funded.
        assertEq(nft.ownerOf(TID), address(escrow), "escrow custodies reward NFT");
        assertEq(uint8(bounty.stateOf(id)), uint8(IBounty.State.Funded), "Funded");

        vm.deal(worker, STAKE);
        vm.prank(worker);
        bounty.claim{value: STAKE}(id, arbiter);
        vm.prank(worker);
        bounty.submit(id, "delivered");
        vm.prank(approver);
        bounty.accept(id);

        // NFT to worker, stake returned, completion + karma recorded.
        assertEq(nft.ownerOf(TID), worker, "worker received the NFT reward");
        assertEq(worker.balance, STAKE, "stake returned");
        assertEq(uint8(bounty.stateOf(id)), uint8(IBounty.State.Paid), "Paid");
        assertEq(rep.completedOf(worker), 1, "completion recorded");
        assertEq(karma.karmaOf(worker), karmaPer, "karma minted for NFT completion");
    }

    function test_ERC721_FinalizeAfterReviewWindow_PaysWorker() public {
        uint256 id = _proposeAndFundNft(TID);
        vm.deal(worker, STAKE);
        vm.prank(worker);
        bounty.claim{value: STAKE}(id, arbiter);
        vm.prank(worker);
        bounty.submit(id, "delivered");

        // Approver silent past the review window: anyone finalizes to the worker.
        vm.warp(block.timestamp + REVIEW + 1);
        vm.prank(stranger);
        bounty.finalize(id);
        assertEq(nft.ownerOf(TID), worker, "worker got the NFT via finalize");
        assertEq(uint8(bounty.stateOf(id)), uint8(IBounty.State.Paid), "Paid");
    }

    // =====================================================================
    // ERC-721 reward — cancel + reclaim return/keep the NFT correctly
    // =====================================================================

    function test_ERC721_Cancel_ReturnsNftToFunder() public {
        uint256 id = _proposeAndFundNft(TID);
        vm.prank(funder);
        bounty.cancel(id);
        assertEq(nft.ownerOf(TID), funder, "NFT refunded to funder on cancel");
        assertEq(uint8(bounty.stateOf(id)), uint8(IBounty.State.Cancelled), "Cancelled");
    }

    function test_ERC721_Reclaim_SlashesStake_NftStaysEscrowed() public {
        uint256 id = _proposeAndFundNft(TID);
        vm.deal(worker, STAKE);
        vm.prank(worker);
        bounty.claim{value: STAKE}(id, arbiter);

        // Worker misses the claim deadline; anyone reclaims: stake slashed to funder, the NFT
        // reward stays in escrow, bounty re-opens to Funded for a new worker.
        vm.warp(block.timestamp + WINDOW + 1);
        uint256 funderBefore = funder.balance;
        vm.prank(stranger);
        bounty.reclaim(id);
        assertEq(funder.balance, funderBefore + STAKE, "stake slashed to funder");
        assertEq(nft.ownerOf(TID), address(escrow), "reward NFT still escrowed");
        assertEq(uint8(bounty.stateOf(id)), uint8(IBounty.State.Funded), "re-Funded");

        // A fresh worker can now claim + complete, and receives the same NFT.
        address worker2 = address(0x2222);
        vm.deal(worker2, STAKE);
        vm.prank(worker2);
        bounty.claim{value: STAKE}(id, arbiter);
        vm.prank(worker2);
        bounty.submit(id, "delivered");
        vm.prank(approver);
        bounty.accept(id);
        assertEq(nft.ownerOf(TID), worker2, "second worker got the NFT");
    }

    // =====================================================================
    // ERC-721 reward — dispute is WINNER-TAKES-ALL (indivisible)
    // =====================================================================

    function test_ERC721_Dispute_WholeToWorker() public {
        uint256 id = _driveToDisputed_Nft(TID);
        // workerAmount == full reward (1) => worker gets the whole NFT; keeps stake.
        vm.prank(arbiter);
        bounty.resolveDispute(id, 1, 0);
        assertEq(nft.ownerOf(TID), worker, "worker awarded whole NFT");
        assertEq(worker.balance, STAKE, "stake returned");
        assertEq(rep.completedOf(worker), 1, "completion recorded");
    }

    function test_ERC721_Dispute_WholeToFunder() public {
        uint256 id = _driveToDisputed_Nft(TID);
        // workerAmount == 0 => funder keeps the whole NFT. H2 floor: the DELIVERED worker's stake is
        // ALWAYS returned (never slashed by dispute), so a Sybil funder+arbiter cannot rob the stake.
        uint256 funderBefore = funder.balance;
        vm.prank(arbiter);
        bounty.resolveDispute(id, 0, 1);
        assertEq(nft.ownerOf(TID), funder, "funder keeps the NFT");
        assertEq(worker.balance, STAKE, "delivered worker's stake returned (never slashed by dispute)");
        assertEq(funder.balance, funderBefore, "funder does NOT get the worker's stake");
        (, uint64 disputesLost, ) = rep.reputationOf(worker);
        assertEq(disputesLost, 1, "dispute loss recorded");
    }

    function test_ERC721_Dispute_FractionalReverts() public {
        // An ERC-1155 reward of quantity 4: a strict-fractional split (1/3) is indivisible.
        multi.mint(funder, TID, 4);
        vm.startPrank(funder);
        multi.setApprovalForAll(address(escrow), true);
        uint256 id = bounty.propose(_multiReward(TID, 4), address(0), STAKE, approver, arbiter, WINDOW, REVIEW, "m");
        bounty.fund(id);
        vm.stopPrank();
        vm.deal(worker, STAKE);
        vm.prank(worker);
        bounty.claim{value: STAKE}(id, arbiter);
        vm.prank(worker);
        bounty.submit(id, "d");
        vm.prank(funder);
        bounty.dispute(id, "r");

        // 1 + 3 == reward(4) so the SplitMismatch guard passes, but 1 is neither 0 nor 4 =>
        // NftRewardIndivisible.
        vm.prank(arbiter);
        vm.expectRevert(abi.encodeWithSelector(IBounty.NftRewardIndivisible.selector, id, 4, 1));
        bounty.resolveDispute(id, 1, 3);

        // The whole-to-worker award (4/0) is allowed.
        vm.prank(arbiter);
        bounty.resolveDispute(id, 4, 0);
        assertEq(multi.balanceOf(worker, TID), 4, "worker got the whole quantity");
    }

    // =====================================================================
    // ERC-1155 reward — quantity happy path
    // =====================================================================

    function test_ERC1155_Lifecycle_AcceptPaysQuantity() public {
        multi.mint(funder, TID, 5);
        vm.startPrank(funder);
        multi.setApprovalForAll(address(escrow), true);
        uint256 id = bounty.propose(_multiReward(TID, 5), address(0), STAKE, approver, arbiter, WINDOW, REVIEW, "m");
        bounty.fund(id);
        vm.stopPrank();
        assertEq(multi.balanceOf(address(escrow), TID), 5, "escrow custodies quantity");

        vm.deal(worker, STAKE);
        vm.prank(worker);
        bounty.claim{value: STAKE}(id, arbiter);
        vm.prank(worker);
        bounty.submit(id, "d");
        vm.prank(approver);
        bounty.accept(id);
        assertEq(multi.balanceOf(worker, TID), 5, "worker got the whole quantity");
        assertEq(worker.balance, STAKE, "stake returned");
    }

    // =====================================================================
    // Reentrancy on the NFT payout callback cannot double-pay
    // =====================================================================

    function test_ERC721_ReentrantWorkerCannotDoublePay() public {
        ReentrantNftWorker w = new ReentrantNftWorker(bounty);
        nft.mintToken(funder, TID);
        vm.startPrank(funder);
        nft.setApprovalForAll(address(escrow), true);
        uint256 id = bounty.propose(_nftReward(TID), address(0), STAKE, approver, arbiter, WINDOW, REVIEW, "n");
        bounty.fund(id);
        vm.stopPrank();

        vm.deal(address(w), STAKE);
        w.doClaim{value: STAKE}(id);
        w.doSubmit(id, "d");

        vm.prank(approver);
        bounty.accept(id);

        assertTrue(w.tried(), "worker attempted reentry on NFT receipt");
        assertEq(nft.ownerOf(TID), address(w), "worker got the NFT exactly once");
        assertEq(uint8(bounty.stateOf(id)), uint8(IBounty.State.Paid), "Paid once");
        assertEq(rep.completedOf(address(w)), 1, "exactly one completion");
    }

    // =====================================================================
    // MONEY-PATH INVARIANT: a Karma-bridge failure NEVER blocks the payout
    // =====================================================================

    function test_KarmaFailure_DoesNotBlockPayout() public {
        // Revoke the reputation ledger's KARMA_SOURCE role: earnKarma will now revert inside
        // the bridge. accept() must STILL pay the worker (best-effort bridge, try/catch).
        controller.revokeRole(controller.KARMA_SOURCE_ROLE(), address(rep));

        uint256 id = _proposeAndFundNft(TID);
        vm.deal(worker, STAKE);
        vm.prank(worker);
        bounty.claim{value: STAKE}(id, arbiter);
        vm.prank(worker);
        bounty.submit(id, "d");

        vm.prank(approver);
        bounty.accept(id); // must NOT revert despite the karma failure

        // Worker fully paid; local completion recorded; global karma NOT minted (bridge failed).
        assertEq(nft.ownerOf(TID), worker, "worker paid the NFT despite karma failure");
        assertEq(worker.balance, STAKE, "stake returned despite karma failure");
        assertEq(uint8(bounty.stateOf(id)), uint8(IBounty.State.Paid), "Paid");
        assertEq(rep.completedOf(worker), 1, "local completion still recorded");
        assertEq(karma.karmaOf(worker), 0, "global karma not minted (bridge failed, caught)");
    }

    // =====================================================================
    // propose() validation: reward-spec consistency + anti-self-dealing
    // =====================================================================

    function test_Propose_RejectsBadRewardSpecs() public {
        // ERC-721 with amount != 1.
        IBounty.RewardSpec memory bad721 =
            IBounty.RewardSpec({kind: IEscrow.AssetKind.ERC721, token: address(nft), tokenId: TID, amount: 2});
        vm.prank(funder);
        vm.expectRevert(IBounty.RewardAssetInvalid.selector);
        bounty.propose(bad721, address(0), STAKE, approver, arbiter, WINDOW, REVIEW, "x");

        // ERC-20 reward with a nonzero tokenId.
        IBounty.RewardSpec memory badErc20 =
            IBounty.RewardSpec({kind: IEscrow.AssetKind.ERC20, token: address(nft), tokenId: 1, amount: 5});
        vm.prank(funder);
        vm.expectRevert(IBounty.RewardAssetInvalid.selector);
        bounty.propose(badErc20, address(0), STAKE, approver, arbiter, WINDOW, REVIEW, "x");

        // Native reward with a nonzero token.
        IBounty.RewardSpec memory badNative =
            IBounty.RewardSpec({kind: IEscrow.AssetKind.Native, token: address(nft), tokenId: 0, amount: 5});
        vm.prank(funder);
        vm.expectRevert(IBounty.RewardAssetInvalid.selector);
        bounty.propose(badNative, address(0), STAKE, approver, arbiter, WINDOW, REVIEW, "x");
    }

    function test_Propose_AntiSelfDealing() public {
        // funder == approver is forbidden.
        IBounty.RewardSpec memory r = _nftReward(TID);
        vm.prank(funder);
        vm.expectRevert(IBounty.ApproverIsFunder.selector);
        bounty.propose(r, address(0), STAKE, funder, arbiter, WINDOW, REVIEW, "x");

        // funder == effective arbiter is forbidden.
        vm.prank(funder);
        vm.expectRevert(IBounty.ArbiterIsFunder.selector);
        bounty.propose(r, address(0), STAKE, approver, funder, WINDOW, REVIEW, "x");
    }

    // =====================================================================
    // H1 — a reverting / non-receiver reward+stake recipient NEVER bricks settlement
    // (the escrow credits on failure; the recipient withdraws / the funder recovers)
    // =====================================================================

    function test_NonReceiverWorker_NativeReward_CreditsThenPaysOnRetry() public {
        ToggleReceiver w = new ToggleReceiver(bounty, escrow); // accepting=false: cannot receive
        IBounty.RewardSpec memory reward =
            IBounty.RewardSpec({kind: IEscrow.AssetKind.Native, token: address(0), tokenId: 0, amount: 5 ether});
        vm.prank(funder);
        uint256 id = bounty.propose(reward, address(0), STAKE, approver, arbiter, WINDOW, REVIEW, "n");
        vm.deal(funder, 5 ether);
        vm.prank(funder);
        bounty.fund{value: 5 ether}(id);
        // Fund the CALLER so the worker contract forwards the stake and nets zero (it cannot receive).
        vm.deal(address(this), STAKE);
        w.doClaim{value: STAKE}(id, arbiter);
        w.doSubmit(id, "d");

        // Worker cannot receive native — accept must STILL settle (credit-on-failure, not revert).
        vm.prank(approver);
        bounty.accept(id);
        assertEq(uint8(bounty.stateOf(id)), uint8(IBounty.State.Paid), "settled despite non-receiver worker");
        assertEq(address(w).balance, 0, "worker got nothing yet");
        assertEq(
            escrow.creditOf(address(w), IEscrow.AssetKind.Native, address(0), 0),
            5 ether + STAKE,
            "reward + stake both credited"
        );

        // Worker fixes its receiver and pulls the credit.
        w.setAccepting(true);
        w.withdrawCredit(IEscrow.AssetKind.Native, address(0), 0);
        assertEq(address(w).balance, 5 ether + STAKE, "withdrew reward + stake");
    }

    function test_NonReceiverWorker_ERC721Reward_FunderRecoversAfterGrace() public {
        ToggleReceiver w = new ToggleReceiver(bounty, escrow);
        nft.mintToken(funder, TID);
        vm.startPrank(funder);
        nft.setApprovalForAll(address(escrow), true);
        uint256 id = bounty.propose(_nftReward(TID), address(0), STAKE, approver, arbiter, WINDOW, REVIEW, "n");
        bounty.fund(id);
        vm.stopPrank();
        vm.deal(address(w), STAKE);
        w.doClaim{value: STAKE}(id, arbiter);
        w.doSubmit(id, "d");

        vm.prank(approver);
        bounty.accept(id); // worker cannot receive the NFT -> credited, NFT stays escrowed
        assertEq(uint8(bounty.stateOf(id)), uint8(IBounty.State.Paid), "settled");
        assertEq(nft.ownerOf(TID), address(escrow), "reward NFT still escrowed (credited)");
        assertEq(escrow.creditOf(address(w), IEscrow.AssetKind.ERC721, address(nft), TID), 1, "reward NFT credited");

        // Funder cannot recover before the grace elapses.
        vm.prank(funder);
        vm.expectRevert();
        bounty.recoverReward(id);

        // After grace, the funder recovers the reward the worker provably cannot receive.
        vm.warp(block.timestamp + 30 days + 1);
        vm.prank(funder);
        bounty.recoverReward(id);
        assertEq(escrow.creditOf(address(w), IEscrow.AssetKind.ERC721, address(nft), TID), 0, "worker credit cleared");
        assertEq(escrow.creditOf(funder, IEscrow.AssetKind.ERC721, address(nft), TID), 1, "funder credited the NFT");
        vm.prank(funder);
        escrow.withdraw(IEscrow.AssetKind.ERC721, address(nft), TID);
        assertEq(nft.ownerOf(TID), funder, "funder recovered the NFT");
    }

    function test_NonReceiverWorker_ERC1155Reward_CreditsThenPaysOnRetry() public {
        ToggleReceiver w = new ToggleReceiver(bounty, escrow);
        multi.mint(funder, TID, 7);
        vm.startPrank(funder);
        multi.setApprovalForAll(address(escrow), true);
        uint256 id = bounty.propose(_multiReward(TID, 7), address(0), STAKE, approver, arbiter, WINDOW, REVIEW, "m");
        bounty.fund(id);
        vm.stopPrank();
        vm.deal(address(w), STAKE);
        w.doClaim{value: STAKE}(id, arbiter);
        w.doSubmit(id, "d");

        vm.prank(approver);
        bounty.accept(id); // worker cannot receive ERC-1155 -> credited
        assertEq(uint8(bounty.stateOf(id)), uint8(IBounty.State.Paid), "settled despite non-receiver worker");
        assertEq(escrow.creditOf(address(w), IEscrow.AssetKind.ERC1155, address(multi), TID), 7, "quantity credited");

        w.setAccepting(true);
        w.withdrawCredit(IEscrow.AssetKind.ERC1155, address(multi), TID);
        assertEq(multi.balanceOf(address(w), TID), 7, "withdrew the ERC-1155 quantity");
    }

    // M1 — a blocklist/pausable ERC-20 that reverts on transfer-OUT is credited, not a brick.
    function test_BlocklistERC20Reward_CreditsWorker() public {
        MockBlocklistERC20 blk = new MockBlocklistERC20();
        blk.mint(funder, 100e18);
        blk.setBlocked(worker, true); // worker cannot RECEIVE the token (passes the inbound check)
        vm.startPrank(funder);
        blk.approve(address(escrow), 100e18);
        IBounty.RewardSpec memory reward =
            IBounty.RewardSpec({kind: IEscrow.AssetKind.ERC20, token: address(blk), tokenId: 0, amount: 100e18});
        uint256 id = bounty.propose(reward, address(0), STAKE, approver, arbiter, WINDOW, REVIEW, "b");
        bounty.fund(id);
        vm.stopPrank();
        vm.deal(worker, STAKE);
        vm.prank(worker);
        bounty.claim{value: STAKE}(id, arbiter);
        vm.prank(worker);
        bounty.submit(id, "d");

        vm.prank(approver);
        bounty.accept(id); // reward transfer-OUT to the blocked worker reverts -> credited
        assertEq(uint8(bounty.stateOf(id)), uint8(IBounty.State.Paid), "settled despite blocklisted worker");
        assertEq(blk.balanceOf(worker), 0, "worker not paid the token yet");
        assertEq(escrow.creditOf(worker, IEscrow.AssetKind.ERC20, address(blk), 0), 100e18, "reward credited");
        assertEq(worker.balance, STAKE, "native stake returned normally");

        // Unblock + withdraw.
        blk.setBlocked(worker, false);
        vm.prank(worker);
        escrow.withdraw(IEscrow.AssetKind.ERC20, address(blk), 0);
        assertEq(blk.balanceOf(worker), 100e18, "worker withdrew reward after unblock");
    }

    function test_RecoverReward_RevertsIfRewardWasDelivered() public {
        // Happy path (worker CAN receive) => reward delivered, not credited => recovery rejected.
        uint256 id = _proposeAndFundNft(TID);
        vm.deal(worker, STAKE);
        vm.prank(worker);
        bounty.claim{value: STAKE}(id, arbiter);
        vm.prank(worker);
        bounty.submit(id, "d");
        vm.prank(approver);
        bounty.accept(id);
        vm.warp(block.timestamp + 30 days + 1);
        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(IBounty.RewardNotCredited.selector, id));
        bounty.recoverReward(id);
    }

    // =====================================================================
    // H2 — a Sybil (funder-controlled 2nd address) arbiter cannot rob a delivering worker
    // =====================================================================

    function test_SybilArbiter_CannotRobDeliveringWorkerStake() public {
        // The funder controls a SECOND address and sets it as the arbiter — bypassing the naive
        // same-address funder!=arbiter guard. It then denies the reward and tries to grab the stake.
        address funderSybil = address(0xF00D);
        nft.mintToken(funder, TID);
        vm.startPrank(funder);
        nft.setApprovalForAll(address(escrow), true);
        uint256 id = bounty.propose(_nftReward(TID), address(0), STAKE, approver, funderSybil, WINDOW, REVIEW, "sybil");
        bounty.fund(id);
        vm.stopPrank();

        vm.deal(worker, STAKE);
        vm.prank(worker);
        bounty.claim{value: STAKE}(id, funderSybil); // worker sees + acknowledges the arbiter
        vm.prank(worker);
        bounty.submit(id, "delivered");
        vm.prank(funder);
        bounty.dispute(id, "bogus");

        // The Sybil arbiter denies the reward (workerAmount = 0). The H2 floor makes stake theft impossible.
        vm.prank(funderSybil);
        bounty.resolveDispute(id, 0, 1);
        assertEq(worker.balance, STAKE, "worker's staked CAPITAL is safe (H2 floor: stake never slashed by dispute)");
        assertEq(nft.ownerOf(TID), funder, "funder only keeps its OWN reward (non-payment, not theft)");
    }

    function test_Claim_RequiresArbiterAcknowledgement() public {
        uint256 id = _proposeAndFundNft(TID);
        vm.deal(worker, STAKE);
        // Acknowledging the WRONG arbiter reverts — a worker never stakes blind to who arbitrates.
        vm.prank(worker);
        vm.expectRevert(abi.encodeWithSelector(IBounty.ArbiterMismatch.selector, id, address(0xBAD), arbiter));
        bounty.claim{value: STAKE}(id, address(0xBAD));
    }

    // M2 — windows below the floor are rejected (anti stake-slash-before-submit).
    function test_Propose_RejectsTinyWindows() public {
        IBounty.RewardSpec memory r = _nftReward(TID);
        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(IBounty.WindowTooShort.selector, uint64(1), uint64(1 hours)));
        bounty.propose(r, address(0), STAKE, approver, arbiter, 1, REVIEW, "x");
        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(IBounty.WindowTooShort.selector, uint64(0), uint64(1 hours)));
        bounty.propose(r, address(0), STAKE, approver, arbiter, WINDOW, 0, "x");
    }

    // =====================================================================
    // H-1 (2nd pass) — recoverReward is BOUNDED to the reward; it can never sweep the
    // worker's stake (colliding native key) or another funder's reward (shared asset key)
    // =====================================================================

    function test_RecoverReward_BoundedToReward_StakeNotSwept() public {
        // Native reward + native stake collide on the credit key (Native,0,0); a non-receiver worker
        // credits BOTH there. Recovery must move ONLY the reward; the stake stays the worker's.
        ToggleReceiver w = new ToggleReceiver(bounty, escrow);
        IBounty.RewardSpec memory reward =
            IBounty.RewardSpec({kind: IEscrow.AssetKind.Native, token: address(0), tokenId: 0, amount: 5 ether});
        vm.prank(funder);
        uint256 id = bounty.propose(reward, address(0), STAKE, approver, arbiter, WINDOW, REVIEW, "n");
        vm.deal(funder, 5 ether);
        vm.prank(funder);
        bounty.fund{value: 5 ether}(id);
        vm.deal(address(this), STAKE);
        w.doClaim{value: STAKE}(id, arbiter);
        w.doSubmit(id, "d");
        vm.prank(approver);
        bounty.accept(id);
        // Reward + stake are credited TOGETHER under the one native key.
        assertEq(
            escrow.creditOf(address(w), IEscrow.AssetKind.Native, address(0), 0),
            5 ether + STAKE,
            "reward + stake credited under the same native key"
        );

        // After grace the funder recovers EXACTLY the reward.
        vm.warp(block.timestamp + 30 days + 1);
        vm.prank(funder);
        bounty.recoverReward(id);
        assertEq(
            escrow.creditOf(address(w), IEscrow.AssetKind.Native, address(0), 0),
            STAKE,
            "stake NOT swept - preserved for the worker (H2 floor holds in the credit path)"
        );
        assertEq(escrow.creditOf(funder, IEscrow.AssetKind.Native, address(0), 0), 5 ether, "funder got exactly the reward");

        // The worker (now able) withdraws its preserved stake.
        w.setAccepting(true);
        w.withdrawCredit(IEscrow.AssetKind.Native, address(0), 0);
        assertEq(address(w).balance, STAKE, "worker withdrew its stake");

        // A second recovery is rejected (already recovered).
        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(IBounty.RewardNotCredited.selector, id));
        bounty.recoverReward(id);
    }

    function test_RecoverReward_NoCrossFunderTheft() public {
        // Two funders, one worker, one fungible reward asset -> both rewards aggregate under the same
        // credit key. Each funder must recover ONLY their own bounty's reward.
        MockBlocklistERC20 blk = new MockBlocklistERC20();
        address funderB = address(0xB0B);
        blk.mint(funder, 5e18);
        blk.mint(funderB, 3e18);
        blk.setBlocked(worker, true); // worker cannot receive -> credited

        vm.startPrank(funder);
        blk.approve(address(escrow), 5e18);
        uint256 idA = bounty.propose(
            IBounty.RewardSpec({kind: IEscrow.AssetKind.ERC20, token: address(blk), tokenId: 0, amount: 5e18}),
            address(0), STAKE, approver, arbiter, WINDOW, REVIEW, "A"
        );
        bounty.fund(idA);
        vm.stopPrank();

        vm.startPrank(funderB);
        blk.approve(address(escrow), 3e18);
        uint256 idB = bounty.propose(
            IBounty.RewardSpec({kind: IEscrow.AssetKind.ERC20, token: address(blk), tokenId: 0, amount: 3e18}),
            address(0), STAKE, approver, arbiter, WINDOW, REVIEW, "B"
        );
        bounty.fund(idB);
        vm.stopPrank();

        vm.deal(worker, 2 * STAKE);
        vm.startPrank(worker);
        bounty.claim{value: STAKE}(idA, arbiter);
        bounty.submit(idA, "d");
        bounty.claim{value: STAKE}(idB, arbiter);
        bounty.submit(idB, "d");
        vm.stopPrank();
        vm.startPrank(approver);
        bounty.accept(idA);
        bounty.accept(idB);
        vm.stopPrank();
        assertEq(escrow.creditOf(worker, IEscrow.AssetKind.ERC20, address(blk), 0), 8e18, "both rewards aggregated");

        vm.warp(block.timestamp + 30 days + 1);
        // Funder A recovers -> EXACTLY its own 5, never B's 3.
        vm.prank(funder);
        bounty.recoverReward(idA);
        assertEq(escrow.creditOf(funder, IEscrow.AssetKind.ERC20, address(blk), 0), 5e18, "A recovered exactly its reward");
        assertEq(escrow.creditOf(worker, IEscrow.AssetKind.ERC20, address(blk), 0), 3e18, "B's reward still the worker's");
        // A is not B's funder — cannot recover B.
        vm.prank(funder);
        vm.expectRevert(IBounty.OnlyFunder.selector);
        bounty.recoverReward(idB);
        // B recovers its own.
        vm.prank(funderB);
        bounty.recoverReward(idB);
        assertEq(escrow.creditOf(funderB, IEscrow.AssetKind.ERC20, address(blk), 0), 3e18, "B recovered its own reward");
    }

    // M-1 (2nd pass) — a malformed-ERC20-return on transfer-OUT must not brick the settlement.
    function test_MalformedERC20Reward_DoesNotBrick_DeliversToWorker() public {
        MockMalformedERC20 mal = new MockMalformedERC20();
        mal.mint(funder, 100e18);
        vm.startPrank(funder);
        mal.approve(address(escrow), 100e18);
        uint256 id = bounty.propose(
            IBounty.RewardSpec({kind: IEscrow.AssetKind.ERC20, token: address(mal), tokenId: 0, amount: 100e18}),
            address(0), STAKE, approver, arbiter, WINDOW, REVIEW, "mal"
        );
        bounty.fund(id);
        vm.stopPrank();
        vm.deal(worker, STAKE);
        vm.prank(worker);
        bounty.claim{value: STAKE}(id, arbiter);
        vm.prank(worker);
        bounty.submit(id, "d");

        // transfer() MOVES the tokens but returns a non-boolean word — a strict abi.decode(bool) would
        // revert+bubble and brick accept. The balance-delta check delivers it instead.
        vm.prank(approver);
        bounty.accept(id);
        assertEq(uint8(bounty.stateOf(id)), uint8(IBounty.State.Paid), "settled - malformed return did NOT brick");
        assertEq(mal.balanceOf(worker), 100e18, "worker paid the reward (delivered)");
        assertEq(escrow.creditOf(worker, IEscrow.AssetKind.ERC20, address(mal), 0), 0, "NOT credited (no double-pay)");
    }

    // R3-M1 (3rd pass) — a reward token whose balanceOf REVERTS must not brick the settlement
    // (the settlement path reads balanceOf via staticcall -> credit, never bubble).
    function test_RevertingBalanceOfReward_DoesNotBrick_Accept() public {
        (uint256 id, MockRevertBalanceOfERC20 tok) = _fundRevertBalToken();
        vm.deal(worker, STAKE);
        vm.prank(worker);
        bounty.claim{value: STAKE}(id, arbiter);
        vm.prank(worker);
        bounty.submit(id, "d");

        tok.setBroken(true); // balanceOf + transfer now revert

        // accept() must NOT bubble the reverting balanceOf — it credits the reward and settles.
        vm.prank(approver);
        bounty.accept(id);
        assertEq(uint8(bounty.stateOf(id)), uint8(IBounty.State.Paid), "accept settled despite reverting balanceOf");
        assertEq(worker.balance, STAKE, "stake returned (not locked)");

        // Reward was credited (transfer failed under `broken`); once healthy, the worker withdraws.
        tok.setBroken(false);
        assertEq(escrow.creditOf(worker, IEscrow.AssetKind.ERC20, address(tok), 0), 100e18, "reward credited");
        vm.prank(worker);
        escrow.withdraw(IEscrow.AssetKind.ERC20, address(tok), 0);
        assertEq(tok.balanceOf(worker), 100e18, "worker withdrew reward after token healed");
    }

    function test_RevertingBalanceOfReward_DoesNotBrick_Finalize() public {
        (uint256 id, MockRevertBalanceOfERC20 tok) = _fundRevertBalToken();
        vm.deal(worker, STAKE);
        vm.prank(worker);
        bounty.claim{value: STAKE}(id, arbiter);
        vm.prank(worker);
        bounty.submit(id, "d");

        tok.setBroken(true);
        vm.warp(block.timestamp + REVIEW + 1);
        // Permissionless finalize must also not brick.
        vm.prank(stranger);
        bounty.finalize(id);
        assertEq(uint8(bounty.stateOf(id)), uint8(IBounty.State.Paid), "finalize settled despite reverting balanceOf");
        assertEq(worker.balance, STAKE, "stake returned via finalize (not locked)");
    }

    function _fundRevertBalToken() internal returns (uint256 id, MockRevertBalanceOfERC20 tok) {
        tok = new MockRevertBalanceOfERC20();
        tok.mint(funder, 100e18);
        vm.startPrank(funder);
        tok.approve(address(escrow), 100e18);
        id = bounty.propose(
            IBounty.RewardSpec({kind: IEscrow.AssetKind.ERC20, token: address(tok), tokenId: 0, amount: 100e18}),
            address(0), STAKE, approver, arbiter, WINDOW, REVIEW, "rvb"
        );
        bounty.fund(id); // deposits while healthy
        vm.stopPrank();
    }

    // --- drive an NFT bounty to Disputed ---
    function _driveToDisputed_Nft(uint256 tokenId_) internal returns (uint256 id) {
        id = _proposeAndFundNft(tokenId_);
        vm.deal(worker, STAKE);
        vm.prank(worker);
        bounty.claim{value: STAKE}(id, arbiter);
        vm.prank(worker);
        bounty.submit(id, "d");
        vm.prank(funder);
        bounty.dispute(id, "r");
    }
}
