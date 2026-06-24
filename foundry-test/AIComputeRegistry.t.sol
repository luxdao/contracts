// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {AIComputeRegistry} from "../contracts/deployables/thinking/AIComputeRegistry.sol";

/// @notice Proves the GLOBAL no-double-mint guarantee: a computation `(model, prompt, output)` can be
/// claimed — and thus subsidy-minted — exactly once across ALL Lux chains. minerA and minerB stand in
/// for the miner contracts on two different chains, both gating on the one shared registry.
contract AIComputeRegistryTest is Test {
    AIComputeRegistry reg;
    address constant DAO = address(0xDA0);
    address constant minerA = address(0xA11CE); // "chain A" miner
    address constant minerB = address(0xB0B); //   "chain B" miner

    function setUp() public {
        reg = new AIComputeRegistry(DAO);
        vm.etch(minerA, hex"00"); // miners are contracts
        vm.etch(minerB, hex"00");
        vm.startPrank(DAO);
        reg.setMiner(minerA, true);
        reg.setMiner(minerB, true);
        vm.stopPrank();
    }

    function test_ComputationKey_IsChainIndependent() public view {
        bytes32 k1 = reg.computationKey(bytes32("model"), bytes32("prompt"), bytes32("output"));
        bytes32 k2 = reg.computationKey(bytes32("model"), bytes32("prompt"), bytes32("output"));
        assertEq(k1, k2, "same (model,prompt,output) gives the same global key");
        bytes32 k3 = reg.computationKey(bytes32("model2"), bytes32("prompt"), bytes32("output"));
        assertTrue(k1 != k3, "a different model gives a different key");
    }

    // THE LOAD-BEARING TEST: chain A mints a computation; chain B cannot re-mint the same work.
    function test_FirstClaimWins_DoubleMintPreventedAcrossChains() public {
        bytes32 key = reg.computationKey(bytes32("m"), bytes32("p"), bytes32("o"));

        vm.prank(minerA);
        reg.claim(key); // chain A claims the computation
        assertTrue(reg.isClaimed(key), "claimed");
        assertEq(reg.claimedBy(key), minerA, "recorded the first claimant");

        // chain B does the SAME work and tries to mint — reverts: one computation, one mint, network-wide.
        vm.prank(minerB);
        vm.expectRevert(
            abi.encodeWithSelector(AIComputeRegistry.AlreadyClaimed.selector, key, minerA, block.chainid)
        );
        reg.claim(key);
    }

    function test_DistinctComputationsClaimIndependently() public {
        bytes32 k1 = reg.computationKey(bytes32("m1"), bytes32("p"), bytes32("o"));
        bytes32 k2 = reg.computationKey(bytes32("m2"), bytes32("p"), bytes32("o"));
        vm.prank(minerA);
        reg.claim(k1);
        vm.prank(minerB);
        reg.claim(k2); // different computation — both mint
        assertTrue(reg.isClaimed(k1) && reg.isClaimed(k2), "distinct work mints independently");
    }

    function test_OnlyAuthorizedMinerCanClaim() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(AIComputeRegistry.NotMiner.selector);
        reg.claim(bytes32("k"));
    }

    // god-key defense, consistent with the coin's mint seam: a claimer must be a contract.
    function test_MinerMustBeContract() public {
        vm.prank(DAO);
        vm.expectRevert(AIComputeRegistry.MinerMustBeContract.selector);
        reg.setMiner(address(0xE0A), true); // an EOA cannot be a claimer
    }

    function test_DeauthorizedMinerCannotClaim() public {
        vm.prank(DAO);
        reg.setMiner(minerA, false);
        vm.prank(minerA);
        vm.expectRevert(AIComputeRegistry.NotMiner.selector);
        reg.claim(bytes32("k"));
    }
}
