// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.31;

import { Test } from "forge-std/Test.sol";
import { DeployDAO } from "../foundry-script/DeployDAO.s.sol";
import { BountyV1 } from "../contracts/deployables/bounty/BountyV1.sol";
import { EscrowV1 } from "../contracts/deployables/bounty/EscrowV1.sol";
import { ReputationV1 } from "../contracts/deployables/bounty/ReputationV1.sol";
import { WorkMarketDeployer } from "../contracts/deployables/bounty/WorkMarketDeployer.sol";
import { IBountyV1 } from "../contracts/interfaces/dao/deployables/IBountyV1.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { SmokeApprover } from "../foundry-script/WorkMarketSmoke.s.sol";

// DAO masters — to assert the factory masters are real, code-bearing implementations.
import { VotesERC20V1 } from "@luxfi/standard/dao/deployables/erc20/VotesERC20V1.sol";
import { ModuleGovernorV1 } from "@luxfi/standard/dao/deployables/modules/ModuleGovernorV1.sol";
import { StrategyV1 } from "@luxfi/standard/dao/deployables/strategies/StrategyV1.sol";
import { SystemDeployerV1 } from "@luxfi/standard/dao/singletons/SystemDeployerV1.sol";

/**
 * @title DeployDAOLive
 * @notice e2e proof for the canonical, brand-neutral luxdao platform deployment (LP-040).
 *         It runs the EXACT DeployDAO deployment logic (by inheriting the script and
 *         calling _deploy), then drives the COMPLETE two-sided work-market lifecycle
 *         against the live, wired contracts — proving the on-chain truth every brand's
 *         vote board depends on: create-DAO masters live -> post task -> claim -> deliver
 *         -> PAID on acceptance, escrow released, reputation recorded, value conserved.
 *
 *  This is the same deployment that ships to Lux (96368/96369), Zoo (200200), Hanzo
 *  (36963) and every future brand — no brand in bytecode, only the chain it runs on.
 *
 *  Coverage:
 *   - test_DeploysFullStack_Wired           — every factory master (incl. ModuleFractalV1
 *                                             sub-DAO primitive + SystemDeployerV1 create
 *                                             orchestrator) + work-market piece deployed,
 *                                             code-bearing, and correctly wired.
 *   - test_WorkMarket_ERC20_Conserves       — full happy path with a real MockERC20.
 *   - test_WorkMarket_Native_Conserves      — full happy path with native value.
 *   - test_WorkMarket_DisputeSplit_Conserves— dispute -> arbiter split, conservation.
 *
 *  The test contract inherits DeployDAO so _deploy() runs the IDENTICAL logic the script
 *  broadcasts. The work-market is stood up by WorkMarketDeployer, whose constructor deploys
 *  the 3 impls + 3 proxies, wires escrow.controller = reputation.writer = the BountyV1
 *  proxy, and VERIFIES that wiring on-chain — reverting the whole deploy if anything is
 *  mis-wired. No EOA-nonce prediction is trusted (M1), so this test is a genuine proof the
 *  atomic wiring holds. M1/M3/M4 fixes are exercised by their dedicated tests below.
 */
contract DeployDAOLive is Test, DeployDAO {
    Deployment internal dep;

    BountyV1 internal bounty;
    EscrowV1 internal escrow;
    ReputationV1 internal rep;
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
        // owner = this test (UUPS upgrade authority); slash treasury = address(0) so
        // slashes route to the funder (the canonical "no treasury Safe yet" default).
        // The work-market wiring no longer depends on the deployer's EOA nonce: the
        // WorkMarketDeployer constructor deploys + verifies escrow.controller ==
        // reputation.writer == the BountyV1 proxy ON-CHAIN (reverting the deploy if
        // wrong), so this test drives the same atomic, self-verifying path the script
        // broadcasts.
        dep = _deploy(address(this), address(0));

        bounty = BountyV1(dep.bounty);
        escrow = EscrowV1(payable(dep.escrow));
        rep = ReputationV1(dep.reputation);
        token = new MockERC20("Work Token", "WORK", 18);
    }

    // ==================================================================
    // Deployment: factory masters + work-market all live and wired
    // ==================================================================

    function test_DeploysFullStack_Wired() public view {
        // (A) Safe infra masters exist and bear code.
        assertTrue(dep.safeSingleton.code.length > 0, "safe singleton has code");
        assertTrue(dep.safeFactory.code.length > 0, "safe factory has code");
        assertTrue(dep.fallbackHandler.code.length > 0, "fallback handler has code");

        // (A) DAO module + voting masters exist and bear code (real master copies).
        assertTrue(dep.votesErc20Master.code.length > 0, "votes master has code");
        assertTrue(dep.moduleGovernorMaster.code.length > 0, "governor master has code");
        assertTrue(dep.moduleFractalMaster.code.length > 0, "fractal (sub-DAO) master has code");
        assertTrue(dep.strategyMaster.code.length > 0, "strategy master has code");
        assertTrue(dep.votingWeightMaster.code.length > 0, "voting weight master has code");
        assertTrue(dep.voteTrackerMaster.code.length > 0, "vote tracker master has code");
        assertTrue(dep.proposerAdapterMaster.code.length > 0, "proposer adapter master has code");

        // (A) Create-a-DAO orchestrator exists, bears code, and is the real impl.
        assertTrue(dep.systemDeployer.code.length > 0, "system deployer has code");
        assertEq(SystemDeployerV1(dep.systemDeployer).version(), 1, "system deployer version");

        // A master copy must report its version (proves it is the real impl, init-disabled).
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
        assertTrue(bounty.supportsInterface(type(IBountyV1).interfaceId), "IBountyV1");

        // All fourteen deployed addresses are distinct (no slot collision in the deploy).
        address[14] memory all = [
            dep.safeSingleton, dep.safeFactory, dep.fallbackHandler,
            dep.votesErc20Master, dep.moduleGovernorMaster, dep.moduleFractalMaster,
            dep.strategyMaster, dep.votingWeightMaster, dep.voteTrackerMaster,
            dep.proposerAdapterMaster, dep.systemDeployer,
            dep.bounty, dep.escrow, dep.reputation
        ];
        for (uint256 i = 0; i < all.length; i++) {
            assertTrue(all[i] != address(0), "no zero address");
            for (uint256 j = i + 1; j < all.length; j++) {
                assertTrue(all[i] != all[j], "addresses distinct");
            }
        }
    }

    // ==================================================================
    // Work-market e2e — ERC-20 — full conservation
    //   create-DAO member posts -> worker claims -> delivers -> reviewer PAYS
    // ==================================================================

    function test_WorkMarket_ERC20_Conserves() public {
        token.mint(daoMember, REWARD);
        token.mint(worker, STAKE);
        uint256 supply = token.totalSupply();

        // 1. A DAO member proposes a bounty (reward R, stake S, approver = reviewer).
        vm.prank(daoMember);
        uint256 id = bounty.propose(address(token), REWARD, STAKE, reviewer, arbiter, WINDOW, REVIEW, "ISSUE-1");
        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Open), "Open");

        // 2. Member funds it: escrow holds R; member spent exactly R.
        vm.prank(daoMember);
        token.approve(address(escrow), REWARD);
        vm.prank(daoMember);
        bounty.fund(id);
        assertEq(token.balanceOf(address(escrow)), REWARD, "reward escrowed");
        assertEq(token.balanceOf(daoMember), 0, "member paid R");
        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Funded), "Funded");

        // 3. A DIFFERENT address (worker) claims by staking S: escrow holds R + S.
        vm.prank(worker);
        token.approve(address(escrow), STAKE);
        vm.prank(worker);
        bounty.claim(id);
        assertEq(token.balanceOf(address(escrow)), REWARD + STAKE, "reward + stake escrowed");
        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Claimed), "Claimed");

        // 4. Worker submits the deliverable.
        vm.prank(worker);
        bounty.submit(id, "PR-1");
        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Submitted), "Submitted");

        // 5. Reviewer accepts -> atomic payout.
        vm.prank(reviewer);
        bounty.accept(id);

        // Worker received reward + stake back; escrow drained; reputation credited.
        assertEq(token.balanceOf(worker), REWARD + STAKE, "worker got R + S back");
        assertEq(token.balanceOf(address(escrow)), 0, "escrow drained");
        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Paid), "Paid");
        assertEq(rep.completedOf(worker), 1, "completion recorded");
        assertEq(rep.earnedOf(worker), REWARD, "earnings recorded");

        // CONSERVATION: nothing minted or burned across the whole lifecycle.
        assertEq(token.totalSupply(), supply, "ERC20 supply conserved");
        assertEq(
            token.balanceOf(daoMember) + token.balanceOf(worker) + token.balanceOf(address(escrow)),
            supply,
            "all tokens accounted (member + worker + escrow == supply)"
        );
    }

    // ==================================================================
    // Work-market e2e — NATIVE — full conservation
    // ==================================================================

    function test_WorkMarket_Native_Conserves() public {
        vm.deal(daoMember, REWARD);
        vm.deal(worker, STAKE);
        uint256 total = _sumNative();

        vm.prank(daoMember);
        uint256 id = bounty.propose(NATIVE, REWARD, STAKE, reviewer, arbiter, WINDOW, REVIEW, "ISSUE-1");

        // Fund: escrow += R, member -= R.
        vm.prank(daoMember);
        bounty.fund{ value: REWARD }(id);
        assertEq(address(escrow).balance, REWARD, "reward escrowed");
        assertEq(daoMember.balance, 0, "member delta -R");

        // Claim by a different address: escrow += S.
        vm.prank(worker);
        bounty.claim{ value: STAKE }(id);
        assertEq(address(escrow).balance, REWARD + STAKE, "reward + stake escrowed");

        vm.prank(worker);
        bounty.submit(id, "PR-1");

        // Accept -> PAID.
        vm.prank(reviewer);
        bounty.accept(id);

        assertEq(worker.balance, REWARD + STAKE, "worker paid R + stake returned");
        assertEq(address(escrow).balance, 0, "escrow drained");
        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Paid), "Paid");
        assertEq(rep.completedOf(worker), 1, "completion recorded");
        assertEq(rep.earnedOf(worker), REWARD, "earnings recorded");

        // CONSERVATION: sum of every actor + escrow native balance is unchanged.
        assertEq(_sumNative(), total, "native conserved across lifecycle");
    }

    // ==================================================================
    // Work-market e2e — DISPUTE (arbiter split) — full conservation
    // ==================================================================

    function test_WorkMarket_DisputeSplit_Conserves() public {
        vm.deal(daoMember, REWARD);
        vm.deal(worker, STAKE);
        uint256 total = _sumNative();

        // Drive to Submitted.
        vm.prank(daoMember);
        uint256 id = bounty.propose(NATIVE, REWARD, STAKE, reviewer, arbiter, WINDOW, REVIEW, "ISSUE-1");
        vm.prank(daoMember);
        bounty.fund{ value: REWARD }(id);
        vm.prank(worker);
        bounty.claim{ value: STAKE }(id);
        vm.prank(worker);
        bounty.submit(id, "PR-1");

        // Member disputes the submission.
        vm.prank(daoMember);
        bounty.dispute(id, "DISPUTE-1");
        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Disputed), "Disputed");

        // Arbiter splits the reward 7 to worker / 3 back to the member; worker keeps stake.
        vm.prank(arbiter);
        bounty.resolveDispute(id, 7 ether, 3 ether, true);

        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Paid), "Paid");
        assertEq(worker.balance, 7 ether + STAKE, "worker: split + stake");
        assertEq(daoMember.balance, 3 ether, "member: refunded portion");
        assertEq(address(escrow).balance, 0, "escrow drained");
        assertEq(rep.completedOf(worker), 1, "nonzero payout => completion");

        // CONSERVATION across the dispute split.
        assertEq(_sumNative(), total, "native conserved across dispute split");
    }

    // ==================================================================
    // M1 -- WorkMarketDeployer stands up a wired market atomically on-chain
    // ==================================================================

    function test_M1_WorkMarketDeployer_WiresAtomically() public {
        // A standalone WorkMarketDeployer produces a fully wired, code-bearing market and
        // its on-chain require()s pass (a wrong prediction would have reverted the ctor).
        WorkMarketDeployer wm = new WorkMarketDeployer(address(this), address(0));
        assertTrue(wm.bounty().code.length > 0, "bounty proxy has code");
        assertTrue(wm.escrow().code.length > 0, "escrow proxy has code");
        assertTrue(wm.reputation().code.length > 0, "reputation proxy has code");

        BountyV1 b = BountyV1(wm.bounty());
        assertEq(b.escrow(), wm.escrow(), "bounty.escrow wired");
        assertEq(b.reputation(), wm.reputation(), "bounty.reputation wired");
        assertEq(EscrowV1(payable(wm.escrow())).controller(), wm.bounty(), "escrow controller == bounty");
        assertEq(ReputationV1(wm.reputation()).writer(), wm.bounty(), "reputation writer == bounty");
        assertEq(b.owner(), address(this), "owner set");

        // Two independent markets get independent, non-colliding proxies.
        WorkMarketDeployer wm2 = new WorkMarketDeployer(address(this), address(0));
        assertTrue(wm2.bounty() != wm.bounty(), "distinct bounty proxies");
        assertTrue(wm2.escrow() != wm.escrow(), "distinct escrow proxies");
    }

    // ==================================================================
    // M3 -- production chains refuse an unset treasury Safe (no EOA rug)
    // ==================================================================

    /// @dev External wrapper so the internal pure guard can be probed with expectRevert.
    function exposed_resolveOwner(
        uint256 chainId_,
        address safe_,
        address deployer_
    ) external pure returns (address, address) {
        return _resolveOwnerAndTreasury(chainId_, safe_, deployer_);
    }

    function test_M3_ProductionChainsRequireTreasurySafe() public {
        uint256[4] memory prod = [uint256(96369), uint256(200200), uint256(36963), uint256(494949)];
        for (uint256 i = 0; i < prod.length; i++) {
            vm.expectRevert(
                bytes("DeployDAO: DAO_TREASURY_SAFE required on production chain (refusing EOA upgrade authority)")
            );
            this.exposed_resolveOwner(prod[i], address(0), address(0xBEEF));
        }
    }

    function test_M3_TestnetAndLocalFallBackToDeployer() public {
        // Lux testnet (96368) and localnet (1337) fall back to the deployer, slash-to-funder.
        (address o1, address s1) = this.exposed_resolveOwner(96368, address(0), address(0xBEEF));
        assertEq(o1, address(0xBEEF), "testnet: deployer owns");
        assertEq(s1, address(0), "testnet: slash-to-funder");
        (address o2, address s2) = this.exposed_resolveOwner(1337, address(0), address(0xBEEF));
        assertEq(o2, address(0xBEEF), "localnet: deployer owns");
        assertEq(s2, address(0), "localnet: slash-to-funder");
    }

    function test_M3_TreasurySafeOwnsWhenSet() public {
        // With a Safe set, even a production chain is fine: the Safe owns + receives slashes.
        address safe = address(0x5AFE);
        (address o, address s) = this.exposed_resolveOwner(96369, safe, address(0xBEEF));
        assertEq(o, safe, "prod + safe: safe owns");
        assertEq(s, safe, "prod + safe: slash-to-safe");
    }

    // ==================================================================
    // M4 -- launch-gate lifecycle (the on-chain TSTORE smoke, run locally)
    // ==================================================================

    /// @dev Exercises the SAME fund -> claim -> submit -> accept the on-chain launch gate
    /// (WorkMarketSmoke) runs, using its SmokeApprover, and asserts the escrow drains and
    /// the bounty reaches Paid. Locally this proves the gate's logic and that the
    /// TSTORE-guarded payout path executes under Cancun; on --broadcast the same sequence
    /// against a live node proves EIP-1153 transient storage works on that chain.
    function test_M4_LaunchGate_NativeAcceptDrainsEscrow() public {
        SmokeApprover appr = new SmokeApprover();
        vm.deal(daoMember, REWARD);
        vm.deal(worker, STAKE);

        vm.prank(daoMember);
        uint256 id = bounty.propose(NATIVE, REWARD, STAKE, address(appr), address(appr), WINDOW, REVIEW, "gate");
        uint256 escrowBaseline = address(escrow).balance;
        vm.prank(daoMember);
        bounty.fund{ value: REWARD }(id);
        vm.prank(worker);
        bounty.claim{ value: STAKE }(id);
        vm.prank(worker);
        bounty.submit(id, "gate");
        appr.accept(bounty, id);

        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Paid), "gate: Paid");
        assertEq(address(escrow).balance, escrowBaseline, "gate: escrow drained to baseline");
        assertEq(worker.balance, REWARD + STAKE, "gate: worker paid reward + stake");
    }

    // ==================================================================
    // helper
    // ==================================================================

    /// @dev Sum of native held by every actor + the escrow + the bounty. The work
    /// market mints/burns nothing, so this is invariant across every lifecycle path.
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
