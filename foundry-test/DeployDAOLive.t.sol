// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.31;

import { Test } from "forge-std/Test.sol";
import { DeployDAO } from "../foundry-script/DeployDAO.s.sol";
import { Bounty } from "../contracts/deployables/bounty/Bounty.sol";
import { Escrow } from "../contracts/deployables/bounty/Escrow.sol";
import { Reputation } from "../contracts/deployables/bounty/Reputation.sol";
import { WorkMarketDeployer } from "../contracts/deployables/bounty/WorkMarketDeployer.sol";
import { IBounty } from "../contracts/interfaces/dao/deployables/IBounty.sol";
import { IEscrow } from "../contracts/interfaces/dao/deployables/IEscrow.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { SmokeApprover } from "../foundry-script/WorkMarketSmoke.s.sol";

// DAO masters — to assert the factory masters are real, code-bearing implementations.
import { VotesERC20V1 } from "@luxfi/standard/dao/deployables/erc20/VotesERC20V1.sol";
import { ModuleGovernorV1 } from "@luxfi/standard/dao/deployables/modules/ModuleGovernorV1.sol";
import { StrategyV1 } from "@luxfi/standard/dao/deployables/strategies/StrategyV1.sol";
import { SystemDeployerV1 } from "@luxfi/standard/dao/singletons/SystemDeployerV1.sol";

// Global Karma stack (the canonical reputation the work-market bridges into).
import { Karma } from "@luxfi/standard/governance/Karma.sol";
import { KarmaController } from "@luxfi/standard/governance/KarmaController.sol";

/**
 * @title DeployDAOLive
 * @notice e2e proof for the canonical, brand-neutral luxdao platform deployment (LP-040).
 *         It runs the EXACT DeployDAO deployment logic (by inheriting the script and calling
 *         _deploy), then drives the COMPLETE two-sided work-market lifecycle against the live,
 *         wired contracts — proving the on-chain truth every brand's vote board depends on:
 *         create-DAO masters live -> post task -> claim -> deliver -> PAID on acceptance,
 *         escrow released, reputation recorded, AND global Karma minted through the REAL
 *         Karma + KarmaController the deployer stood up and handed to the org Safe.
 *
 *  The work-market is stood up by WorkMarketDeployer, whose constructor deploys Karma +
 *  KarmaController + the 3 impls + 3 proxies, wires escrow.controller = reputation.writer =
 *  the Bounty proxy AND reputation -> KarmaController (Reputation is the sole KARMA_SOURCE,
 *  KarmaController is the sole Karma ATTESTOR), hands all governance to the org Safe, renounces
 *  its own transient authority, and VERIFIES every fact on-chain — reverting the whole deploy
 *  if anything is mis-wired.
 */
contract DeployDAOLive is Test, DeployDAO {
    Deployment internal dep;

    Bounty internal bounty;
    Escrow internal escrow;
    Reputation internal rep;
    Karma internal karma;
    MockERC20 internal token;

    // Distinct actors so balance deltas are unambiguous.
    address internal daoMember = address(0xDA0); // proposer / funder (a "DAO member")
    address internal worker = address(0x9A0); //    claims + delivers
    address internal reviewer = address(0xA999); //  approver
    address internal arbiter = address(0xA981E7); // dispute resolver
    address internal stranger = address(0x57A);

    address internal constant NATIVE = address(0);
    uint256 internal constant REWARD = 10 ether;
    uint256 internal constant STAKE = 1 ether;
    uint64 internal constant WINDOW = 3 days; // claim window
    uint64 internal constant REVIEW = 3 days; // review window (liveness escape)

    function setUp() public {
        // owner = this test (the org-Safe stand-in: UUPS upgrade authority + Karma governance
        // admin); slash treasury = address(0) so slashes route to the funder. The whole market
        // + Karma stack is stood up and self-verified by the WorkMarketDeployer constructor.
        dep = _deploy(address(this), address(0));

        bounty = Bounty(dep.bounty);
        escrow = Escrow(payable(dep.escrow));
        rep = Reputation(dep.reputation);
        karma = Karma(dep.karma);
        token = new MockERC20("Work Token", "WORK", 18);
    }

    // --- reward-spec helpers -------------------------------------------------

    function _nativeReward(uint256 amount_) internal pure returns (IBounty.RewardSpec memory) {
        return IBounty.RewardSpec({ kind: IEscrow.AssetKind.Native, token: address(0), tokenId: 0, amount: amount_ });
    }

    function _erc20Reward(address token_, uint256 amount_) internal pure returns (IBounty.RewardSpec memory) {
        return IBounty.RewardSpec({ kind: IEscrow.AssetKind.ERC20, token: token_, tokenId: 0, amount: amount_ });
    }

    // ==================================================================
    // Deployment: factory masters + work-market + Karma all live and wired
    // ==================================================================

    function test_DeploysFullStack_Wired() public view {
        // (A) Safe infra + DAO module/voting masters exist and bear code.
        assertTrue(dep.safeSingleton.code.length > 0, "safe singleton has code");
        assertTrue(dep.safeFactory.code.length > 0, "safe factory has code");
        assertTrue(dep.fallbackHandler.code.length > 0, "fallback handler has code");
        assertTrue(dep.votesErc20Master.code.length > 0, "votes master has code");
        assertTrue(dep.moduleGovernorMaster.code.length > 0, "governor master has code");
        assertTrue(dep.moduleFractalMaster.code.length > 0, "fractal (sub-DAO) master has code");
        assertTrue(dep.strategyMaster.code.length > 0, "strategy master has code");
        assertTrue(dep.votingWeightMaster.code.length > 0, "voting weight master has code");
        assertTrue(dep.voteTrackerMaster.code.length > 0, "vote tracker master has code");
        assertTrue(dep.proposerAdapterMaster.code.length > 0, "proposer adapter master has code");
        assertTrue(dep.systemDeployer.code.length > 0, "system deployer has code");
        assertEq(SystemDeployerV1(dep.systemDeployer).version(), 1, "system deployer version");
        assertEq(VotesERC20V1(dep.votesErc20Master).version(), 1, "votes master version");
        assertEq(ModuleGovernorV1(dep.moduleGovernorMaster).version(), 1, "governor master version");
        assertEq(StrategyV1(dep.strategyMaster).version(), 1, "strategy master version");

        // (B) Work-market instance wired: escrow controller == bounty, rep writer == bounty.
        assertEq(bounty.escrow(), address(escrow), "bounty.escrow");
        assertEq(bounty.reputation(), address(rep), "bounty.reputation");
        assertEq(bounty.owner(), address(this), "bounty owner");
        assertEq(bounty.treasury(), address(0), "slash-to-funder");
        assertEq(escrow.controller(), address(bounty), "escrow controller is bounty");
        assertEq(rep.writer(), address(bounty), "reputation writer is bounty");
        assertEq(bounty.bountyCount(), 0, "fresh ledger");
        assertTrue(bounty.supportsInterface(type(IBounty).interfaceId), "IBounty");

        // (C) Karma stack live + wired at least privilege, deployer renounced, Safe governs.
        KarmaController controller = KarmaController(dep.karmaController);
        assertTrue(dep.karma.code.length > 0, "karma has code");
        assertTrue(dep.karmaController.code.length > 0, "karma controller has code");
        assertEq(rep.karmaController(), dep.karmaController, "reputation -> controller");
        assertEq(rep.karmaPerCompletion(), KARMA_PER_COMPLETION, "flat karma per completion");
        // Reputation is the ONLY earn source; KarmaController is the ONLY Karma attestor.
        assertTrue(controller.hasRole(controller.KARMA_SOURCE_ROLE(), address(rep)), "rep is KARMA_SOURCE");
        assertTrue(karma.hasRole(karma.ATTESTOR_ROLE(), dep.karmaController), "controller is ATTESTOR");
        // The org Safe (this test) governs; the deployer retained nothing.
        assertTrue(karma.hasRole(0x00, address(this)), "safe is karma admin");
        assertTrue(controller.hasRole(0x00, address(this)), "safe is controller admin");

        // All sixteen deployed addresses are distinct (no slot collision in the deploy).
        address[16] memory all = [
            dep.safeSingleton, dep.safeFactory, dep.fallbackHandler,
            dep.votesErc20Master, dep.moduleGovernorMaster, dep.moduleFractalMaster,
            dep.strategyMaster, dep.votingWeightMaster, dep.voteTrackerMaster,
            dep.proposerAdapterMaster, dep.systemDeployer,
            dep.bounty, dep.escrow, dep.reputation, dep.karma, dep.karmaController
        ];
        for (uint256 i = 0; i < all.length; i++) {
            assertTrue(all[i] != address(0), "no zero address");
            for (uint256 j = i + 1; j < all.length; j++) {
                assertTrue(all[i] != all[j], "addresses distinct");
            }
        }
    }

    // ==================================================================
    // Work-market e2e — ERC-20 — full conservation + Karma bridged
    // ==================================================================

    function test_WorkMarket_ERC20_Conserves() public {
        token.mint(daoMember, REWARD);
        token.mint(worker, STAKE);
        uint256 supply = token.totalSupply();

        vm.prank(daoMember);
        uint256 id = bounty.propose(_erc20Reward(address(token), REWARD), address(token), STAKE, reviewer, arbiter, WINDOW, REVIEW, "ISSUE-1");
        assertEq(uint8(bounty.stateOf(id)), uint8(IBounty.State.Open), "Open");

        vm.prank(daoMember);
        token.approve(address(escrow), REWARD);
        vm.prank(daoMember);
        bounty.fund(id);
        assertEq(token.balanceOf(address(escrow)), REWARD, "reward escrowed");
        assertEq(token.balanceOf(daoMember), 0, "member paid R");
        assertEq(uint8(bounty.stateOf(id)), uint8(IBounty.State.Funded), "Funded");

        vm.prank(worker);
        token.approve(address(escrow), STAKE);
        vm.prank(worker);
        bounty.claim(id, arbiter);
        assertEq(token.balanceOf(address(escrow)), REWARD + STAKE, "reward + stake escrowed");

        vm.prank(worker);
        bounty.submit(id, "PR-1");
        vm.prank(reviewer);
        bounty.accept(id);

        assertEq(token.balanceOf(worker), REWARD + STAKE, "worker got R + S back");
        assertEq(token.balanceOf(address(escrow)), 0, "escrow drained");
        assertEq(uint8(bounty.stateOf(id)), uint8(IBounty.State.Paid), "Paid");
        assertEq(rep.completedOf(worker), 1, "completion recorded");
        assertEq(rep.earnedOf(worker), REWARD, "earnings recorded");
        // Global Karma bridged through the REAL controller: flat award, once.
        assertEq(karma.karmaOf(worker), KARMA_PER_COMPLETION, "karma minted on completion");

        // CONSERVATION: nothing minted or burned across the whole ERC-20 lifecycle.
        assertEq(token.totalSupply(), supply, "ERC20 supply conserved");
        assertEq(
            token.balanceOf(daoMember) + token.balanceOf(worker) + token.balanceOf(address(escrow)),
            supply,
            "all tokens accounted"
        );
    }

    // ==================================================================
    // Work-market e2e — NATIVE — full conservation + Karma bridged
    // ==================================================================

    function test_WorkMarket_Native_Conserves() public {
        vm.deal(daoMember, REWARD);
        vm.deal(worker, STAKE);
        uint256 total = _sumNative();

        vm.prank(daoMember);
        uint256 id = bounty.propose(_nativeReward(REWARD), NATIVE, STAKE, reviewer, arbiter, WINDOW, REVIEW, "ISSUE-1");

        vm.prank(daoMember);
        bounty.fund{ value: REWARD }(id);
        assertEq(address(escrow).balance, REWARD, "reward escrowed");
        assertEq(daoMember.balance, 0, "member delta -R");

        vm.prank(worker);
        bounty.claim{ value: STAKE }(id, arbiter);
        assertEq(address(escrow).balance, REWARD + STAKE, "reward + stake escrowed");

        vm.prank(worker);
        bounty.submit(id, "PR-1");
        vm.prank(reviewer);
        bounty.accept(id);

        assertEq(worker.balance, REWARD + STAKE, "worker paid R + stake returned");
        assertEq(address(escrow).balance, 0, "escrow drained");
        assertEq(uint8(bounty.stateOf(id)), uint8(IBounty.State.Paid), "Paid");
        assertEq(rep.completedOf(worker), 1, "completion recorded");
        assertEq(karma.karmaOf(worker), KARMA_PER_COMPLETION, "karma minted on completion");

        // CONSERVATION: sum of every actor + escrow native balance is unchanged.
        assertEq(_sumNative(), total, "native conserved across lifecycle");
    }

    // ==================================================================
    // Work-market e2e — DISPUTE (arbiter split) — conservation + Karma
    // ==================================================================

    function test_WorkMarket_DisputeSplit_Conserves() public {
        vm.deal(daoMember, REWARD);
        vm.deal(worker, STAKE);
        uint256 total = _sumNative();

        vm.prank(daoMember);
        uint256 id = bounty.propose(_nativeReward(REWARD), NATIVE, STAKE, reviewer, arbiter, WINDOW, REVIEW, "ISSUE-1");
        vm.prank(daoMember);
        bounty.fund{ value: REWARD }(id);
        vm.prank(worker);
        bounty.claim{ value: STAKE }(id, arbiter);
        vm.prank(worker);
        bounty.submit(id, "PR-1");

        vm.prank(daoMember);
        bounty.dispute(id, "DISPUTE-1");
        assertEq(uint8(bounty.stateOf(id)), uint8(IBounty.State.Disputed), "Disputed");

        // Arbiter splits the reward 7 to worker / 3 back to the member; worker keeps stake.
        vm.prank(arbiter);
        bounty.resolveDispute(id, 7 ether, 3 ether);

        assertEq(uint8(bounty.stateOf(id)), uint8(IBounty.State.Paid), "Paid");
        assertEq(worker.balance, 7 ether + STAKE, "worker: split + stake");
        assertEq(daoMember.balance, 3 ether, "member: refunded portion");
        assertEq(address(escrow).balance, 0, "escrow drained");
        assertEq(rep.completedOf(worker), 1, "nonzero payout => completion");
        assertEq(karma.karmaOf(worker), KARMA_PER_COMPLETION, "karma minted on nonzero dispute payout");

        assertEq(_sumNative(), total, "native conserved across dispute split");
    }

    // ==================================================================
    // Karma bridge integration — once per completion through the real stack
    // ==================================================================

    function test_Karma_MintedOncePerCompletion_ThroughRealController() public {
        // Two separate completed bounties => karma minted twice, exactly the flat award each.
        _completeNativeBounty();
        assertEq(karma.karmaOf(worker), KARMA_PER_COMPLETION, "1st completion");
        _completeNativeBounty();
        assertEq(karma.karmaOf(worker), 2 * KARMA_PER_COMPLETION, "2nd completion");

        // A random address can NOT mint karma directly through the controller (only the
        // Reputation ledger holds KARMA_SOURCE_ROLE).
        KarmaController controller = KarmaController(dep.karmaController);
        vm.prank(stranger);
        vm.expectRevert();
        controller.earnKarma(worker, 1e18, bytes32("evil"));
    }

    function _completeNativeBounty() internal {
        vm.deal(daoMember, REWARD);
        vm.deal(worker, worker.balance + STAKE);
        vm.prank(daoMember);
        uint256 id = bounty.propose(_nativeReward(REWARD), NATIVE, STAKE, reviewer, arbiter, WINDOW, REVIEW, "k");
        vm.prank(daoMember);
        bounty.fund{ value: REWARD }(id);
        vm.prank(worker);
        bounty.claim{ value: STAKE }(id, arbiter);
        vm.prank(worker);
        bounty.submit(id, "k");
        vm.prank(reviewer);
        bounty.accept(id);
    }

    // ==================================================================
    // WorkMarketDeployer stands up a wired market atomically on-chain
    // ==================================================================

    function test_WorkMarketDeployer_WiresAtomically() public {
        WorkMarketDeployer wm = new WorkMarketDeployer(
            address(this), address(0), KARMA_PER_COMPLETION, address(new Escrow()), address(new Reputation()), address(new Bounty())
        );
        assertTrue(wm.bounty().code.length > 0, "bounty proxy has code");
        assertTrue(wm.escrow().code.length > 0, "escrow proxy has code");
        assertTrue(wm.reputation().code.length > 0, "reputation proxy has code");
        assertTrue(wm.karma().code.length > 0, "karma has code");
        assertTrue(wm.karmaController().code.length > 0, "karma controller has code");

        Bounty b = Bounty(wm.bounty());
        assertEq(b.escrow(), wm.escrow(), "bounty.escrow wired");
        assertEq(b.reputation(), wm.reputation(), "bounty.reputation wired");
        assertEq(Escrow(payable(wm.escrow())).controller(), wm.bounty(), "escrow controller == bounty");
        assertEq(Reputation(wm.reputation()).writer(), wm.bounty(), "reputation writer == bounty");
        assertEq(Reputation(wm.reputation()).karmaController(), wm.karmaController(), "rep -> controller");
        assertEq(b.owner(), address(this), "owner set");

        // Two independent markets get independent, non-colliding proxies + Karma stacks.
        WorkMarketDeployer wm2 = new WorkMarketDeployer(
            address(this), address(0), KARMA_PER_COMPLETION, address(new Escrow()), address(new Reputation()), address(new Bounty())
        );
        assertTrue(wm2.bounty() != wm.bounty(), "distinct bounty proxies");
        assertTrue(wm2.escrow() != wm.escrow(), "distinct escrow proxies");
        assertTrue(wm2.karma() != wm.karma(), "distinct karma instances");
    }

    // ==================================================================
    // Production chains refuse an unset treasury Safe (no EOA rug)
    // ==================================================================

    /// @dev External wrapper so the internal pure guard can be probed with expectRevert.
    function exposed_resolveOwner(
        uint256 chainId_,
        address safe_,
        address deployer_
    ) external pure returns (address, address) {
        return _resolveOwnerAndTreasury(chainId_, safe_, deployer_);
    }

    function test_ProductionChainsRequireTreasurySafe() public {
        uint256[4] memory prod = [uint256(96369), uint256(200200), uint256(36963), uint256(494949)];
        for (uint256 i = 0; i < prod.length; i++) {
            vm.expectRevert(
                bytes("DeployDAO: DAO_TREASURY_SAFE required on production chain (refusing EOA upgrade authority)")
            );
            this.exposed_resolveOwner(prod[i], address(0), address(0xBEEF));
        }
    }

    function test_TestnetAndLocalFallBackToDeployer() public view {
        (address o1, address s1) = this.exposed_resolveOwner(96368, address(0), address(0xBEEF));
        assertEq(o1, address(0xBEEF), "testnet: deployer owns");
        assertEq(s1, address(0), "testnet: slash-to-funder");
        (address o2, address s2) = this.exposed_resolveOwner(1337, address(0), address(0xBEEF));
        assertEq(o2, address(0xBEEF), "localnet: deployer owns");
        assertEq(s2, address(0), "localnet: slash-to-funder");
    }

    function test_TreasurySafeOwnsWhenSet() public view {
        address safe = address(0x5AFE);
        (address o, address s) = this.exposed_resolveOwner(96369, safe, address(0xBEEF));
        assertEq(o, safe, "prod + safe: safe owns");
        assertEq(s, safe, "prod + safe: slash-to-safe");
    }

    // ==================================================================
    // Launch-gate lifecycle (the on-chain TSTORE smoke, run locally)
    // ==================================================================

    function test_LaunchGate_NativeAcceptDrainsEscrow() public {
        SmokeApprover appr = new SmokeApprover();
        vm.deal(daoMember, REWARD);
        vm.deal(worker, STAKE);

        vm.prank(daoMember);
        uint256 id = bounty.propose(_nativeReward(REWARD), NATIVE, STAKE, address(appr), address(appr), WINDOW, REVIEW, "gate");
        uint256 escrowBaseline = address(escrow).balance;
        vm.prank(daoMember);
        bounty.fund{ value: REWARD }(id);
        vm.prank(worker);
        bounty.claim{ value: STAKE }(id, address(appr)); // arbiter defaulted to the approver
        vm.prank(worker);
        bounty.submit(id, "gate");
        appr.accept(bounty, id);

        assertEq(uint8(bounty.stateOf(id)), uint8(IBounty.State.Paid), "gate: Paid");
        assertEq(address(escrow).balance, escrowBaseline, "gate: escrow drained to baseline");
        assertEq(worker.balance, REWARD + STAKE, "gate: worker paid reward + stake");
    }

    // ==================================================================
    // helper
    // ==================================================================

    /// @dev Sum of native held by every actor + the escrow + the bounty. The work market
    /// mints/burns nothing, so this is invariant across every native lifecycle path.
    function _sumNative() internal view returns (uint256) {
        return
            daoMember.balance +
            worker.balance +
            reviewer.balance +
            arbiter.balance +
            stranger.balance +
            address(escrow).balance +
            address(bounty).balance;
    }
}
