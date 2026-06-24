// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.31;

import { Test } from "forge-std/Test.sol";
import { DeployPars } from "../foundry-script/DeployPars.s.sol";
import { BountyV1 } from "../contracts/deployables/bounty/BountyV1.sol";
import { EscrowV1 } from "../contracts/deployables/bounty/EscrowV1.sol";
import { ReputationV1 } from "../contracts/deployables/bounty/ReputationV1.sol";
import { IBountyV1 } from "../contracts/interfaces/dao/deployables/IBountyV1.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";

// DAO masters — to assert the factory masters are real, code-bearing implementations.
import { VotesERC20V1 } from "@luxfi/standard/dao/deployables/erc20/VotesERC20V1.sol";
import { ModuleGovernorV1 } from "@luxfi/standard/dao/deployables/modules/ModuleGovernorV1.sol";
import { StrategyV1 } from "@luxfi/standard/dao/deployables/strategies/StrategyV1.sol";

/**
 * @title DeployParsLive
 * @notice e2e proof for the Pars (494949) luxdao platform deployment. It runs the EXACT
 *         DeployPars deployment logic (by inheriting the script and calling _deploy), then
 *         drives the COMPLETE two-sided work-market lifecycle against the live, wired
 *         contracts — proving the on-chain truth the pars.vote board depends on:
 *         create-DAO masters live -> post task -> claim -> deliver -> PAID on acceptance,
 *         escrow released, reputation recorded, value conserved at every step.
 *
 *  Coverage:
 *   - test_DeploysFullStack_Wired           — every factory master + work-market piece
 *                                             deployed, code-bearing, and correctly wired.
 *   - test_WorkMarket_ERC20_Conserves       — full happy path with a real MockERC20.
 *   - test_WorkMarket_Native_Conserves      — full happy path with native value.
 *   - test_WorkMarket_DisputeSplit_Conserves— dispute -> arbiter split, conservation.
 *
 *  The test contract inherits DeployPars so _deploy() runs from THIS contract's account:
 *  the CREATE-nonce prediction inside _deployWorkMarket is therefore exercised exactly as
 *  it is under `forge script` (a wrong offset reverts the deploy with a require, failing
 *  the test loudly). This makes the test a genuine proof the script's prediction holds.
 */
contract DeployParsLive is Test, DeployPars {
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
    uint64 internal constant WINDOW = 3 days;

    function setUp() public {
        // deployer = address(this): under a fork test the CREATEs originate from this
        // contract, so the BountyV1 proxy prediction must be against THIS account's
        // nonce (the script passes msg.sender, the broadcasting EOA, instead).
        // owner = this test (upgrade authority); slash treasury = address(0) so slashes
        // route to the funder (the canonical "no treasury Safe yet" Pars default).
        dep = _deploy(address(this), address(this), address(0));

        bounty = BountyV1(dep.bounty);
        escrow = EscrowV1(payable(dep.escrow));
        rep = ReputationV1(dep.reputation);
        token = new MockERC20("Pars Work Token", "PWORK", 18);
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
        assertTrue(dep.strategyMaster.code.length > 0, "strategy master has code");
        assertTrue(dep.votingWeightMaster.code.length > 0, "voting weight master has code");
        assertTrue(dep.voteTrackerMaster.code.length > 0, "vote tracker master has code");
        assertTrue(dep.proposerAdapterMaster.code.length > 0, "proposer adapter master has code");

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

        // All twelve deployed addresses are distinct (no slot collision in the deploy).
        address[12] memory all = [
            dep.safeSingleton, dep.safeFactory, dep.fallbackHandler,
            dep.votesErc20Master, dep.moduleGovernorMaster, dep.strategyMaster,
            dep.votingWeightMaster, dep.voteTrackerMaster, dep.proposerAdapterMaster,
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
        uint256 id = bounty.propose(address(token), REWARD, STAKE, reviewer, arbiter, WINDOW, "ISSUE-1");
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
        uint256 id = bounty.propose(NATIVE, REWARD, STAKE, reviewer, arbiter, WINDOW, "ISSUE-1");

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
        uint256 id = bounty.propose(NATIVE, REWARD, STAKE, reviewer, arbiter, WINDOW, "ISSUE-1");
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
