// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.31;

import {Script, console} from "forge-std/Script.sol";
import {BountyV1} from "../contracts/deployables/bounty/BountyV1.sol";
import {IBountyV1} from "../contracts/interfaces/dao/deployables/IBountyV1.sol";

/**
 * @dev Minimal approver used by the smoke gate so the funder != approver self-dealing
 * guard (M2) is satisfied without a second signing key. It only forwards accept() to the
 * bounty as the configured approver.
 */
contract SmokeApprover {
    function accept(BountyV1 bounty_, uint256 id_) external {
        bounty_.accept(id_);
    }
}

/**
 * @title WorkMarketSmoke
 * @notice MANDATORY post-deploy launch gate. Given a live BountyV1 (env BOUNTY_V1), it
 * runs the native lifecycle fund -> claim -> submit -> accept ON-CHAIN and asserts the
 * escrow drained and the bounty reached Paid.
 *
 * @dev Why this is the launch gate: EscrowV1 and BountyV1 guard every state-changing
 * entrypoint with OpenZeppelin ReentrancyGuardTransient, which uses EIP-1153 transient
 * storage (TSTORE/TLOAD). The local Foundry simulation runs a Cancun EVM, so it CANNOT
 * prove the remote target chain actually executes transient storage. Only a real
 * `--broadcast` whose transactions MINE SUCCESSFULLY proves TSTORE works live: if the
 * target node's EVM predates Cancun/EIP-1153, `accept` reverts on-chain and the broadcast
 * fails — failing the gate. Run this before wiring any UI to a fresh deployment:
 *
 *   BOUNTY_V1=0x... forge script foundry-script/WorkMarketSmoke.s.sol:WorkMarketSmoke \
 *     --rpc-url <chain-rpc> --private-key "$DEPLOYER_KEY" --broadcast
 *
 * The broadcasting key must hold a little native coin (reward + stake = 3e-4 coin) and
 * the run leaves ONE net-zero completed bounty on-chain as the proof.
 */
contract WorkMarketSmoke is Script {
    uint256 internal constant REWARD = 200_000 gwei; // 2e-4 native
    uint256 internal constant STAKE = 100_000 gwei; //  1e-4 native
    uint64 internal constant CLAIM_WINDOW = 1 hours;
    uint64 internal constant REVIEW_WINDOW = 1 hours;

    function run() external {
        address bountyAddr = vm.envAddress("BOUNTY_V1");
        vm.startBroadcast();
        uint256 id = _smoke(BountyV1(payable(bountyAddr)));
        vm.stopBroadcast();
        console.log("SMOKE_OK_BOUNTY_ID", id);
    }

    /**
     * @notice Drives the native happy path against `bounty` and asserts the payout.
     * @dev The broadcasting key is BOTH funder and worker (permitted); a throwaway
     * SmokeApprover is the approver so funder != approver (M2). Reverts if the payout is
     * wrong — on `--broadcast` that means the on-chain txs failed (e.g. TSTORE
     * unsupported), which fails the gate. Assertions are escrow-balance / state based so
     * they are independent of the gas the EOA pays.
     * @param bounty The deployed BountyV1 to smoke-test.
     * @return id The bounty id created for the proof.
     */
    function _smoke(BountyV1 bounty) internal returns (uint256 id) {
        SmokeApprover approver = new SmokeApprover();
        address escrowAddr = bounty.escrow();
        uint256 escrowBefore = escrowAddr.balance;

        id = bounty.propose(
            address(0),
            REWARD,
            STAKE,
            address(approver),
            address(approver),
            CLAIM_WINDOW,
            REVIEW_WINDOW,
            "smoke"
        );
        bounty.fund{value: REWARD}(id);
        bounty.claim{value: STAKE}(id);
        bounty.submit(id, "smoke-deliverable");
        approver.accept(bounty, id);

        // Proof: accept fully executed on-chain (reward + stake released, TSTORE ran) so
        // the bounty is Paid and the escrow is back to its pre-smoke balance (net zero).
        require(bounty.stateOf(id) == IBountyV1.State.Paid, "smoke: bounty not Paid (accept/TSTORE failed)");
        require(escrowAddr.balance == escrowBefore, "smoke: escrow not drained (payout failed)");
    }
}
