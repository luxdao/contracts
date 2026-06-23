// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {AICoin} from "../contracts/deployables/thinking/AICoin.sol";
import {ThinkingMiner, IAICoinMintableG, IComputeProfileView} from "../contracts/deployables/thinking/ThinkingMiner.sol";
import {IThinkingGovernor} from "../contracts/deployables/thinking/interfaces/IThinkingGovernor.sol";
import {IComputeVerifier} from "../contracts/deployables/thinking/interfaces/IComputeVerifier.sol";

/// @dev Minimal governor stand-in exposing only the two views ThinkingMiner reads
/// (getThought, getVerdicts). Lets the test stage a settled thought + its verdicts.
contract MockGovernor {
    IThinkingGovernor.Thought private _t;
    IThinkingGovernor.Verdict[] private _v;

    function setThought(uint8 status, uint8 canonicalVote, uint8 agreeCount) external {
        _t.status = IThinkingGovernor.Status(status);
        _t.canonicalVote = IThinkingGovernor.Vote(canonicalVote);
        _t.agreeCount = agreeCount;
    }

    function addVerdict(address op, uint8 vote) external {
        _v.push(IThinkingGovernor.Verdict({
            operator: op,
            vote: IThinkingGovernor.Vote(vote),
            confidenceBucket: 8000,
            evidenceHash: bytes32(0),
            submittedAt: 0
        }));
    }

    function getThought(uint256) external view returns (IThinkingGovernor.Thought memory) { return _t; }
    function getVerdicts(uint256) external view returns (IThinkingGovernor.Verdict[] memory) { return _v; }
}

/// @notice Proves the unification: reaching an on-chain thinking-validator QUORUM mints the
/// AICoin subsidy to the winning group — consensus is the receipt. The same coin is minted
/// by both this governance path and the attestation path (multi-minter), jointly capped.
contract ThinkingMinerTest is Test {
    AICoin coin;
    ThinkingMiner miner;
    MockGovernor gov;

    address constant ADMIN = address(0xA11CE);
    uint256 constant REWARD = 1500 ether; // total per settled thought, split among winners
    // 5 thinking-validators (non-precompile addresses)
    address[5] V = [address(0x1001), address(0x1002), address(0x1003), address(0x1004), address(0x1005)];

    // Vote enum: Invalid=0, YES=1, NO=2, Abstain=3 ; Status: None=0, Open=1, Settled=2, Failed=3
    uint8 constant YES = 1;
    uint8 constant NO = 2;
    uint8 constant SETTLED = 2;
    uint8 constant OPEN = 1;

    function setUp() public {
        vm.warp(1_700_000_000);
        gov = new MockGovernor();
        coin = new AICoin("AI", "AI", ADMIN, address(0), 0);
        // Consensus-only path: gate UNWIRED (verifier+profile == address(0) ⇒ all tiers
        // permissive), so this suite proves the quorum→mint machinery in isolation. The C2 fix
        // (guess-without-proof does NOT mint) is proven in ComputeProofEnforcement.t.sol against a
        // miner with a wired verifier + a tier that requires a proof.
        miner = new ThinkingMiner(
            IThinkingGovernor(address(gov)),
            IAICoinMintableG(address(coin)),
            ADMIN,
            REWARD,
            IComputeVerifier(address(0)),
            IComputeProfileView(address(0))
        );
        vm.prank(ADMIN);
        coin.setMinter(address(miner), true); // authorize the governance-mining path
        vm.warp(block.timestamp + 63_072_000); // vest ~250M AI
    }

    function _quorum_3NO_2YES() internal {
        gov.setThought(SETTLED, NO, 3); // canonical NO, winning group size 3
        gov.addVerdict(V[0], NO);
        gov.addVerdict(V[1], NO);
        gov.addVerdict(V[2], NO);
        gov.addVerdict(V[3], YES); // dissenters — not the winning group
        gov.addVerdict(V[4], YES);
    }

    function test_SettledThought_RewardsWinningGroup() public {
        _quorum_3NO_2YES();
        assertTrue(miner.mineable(0), "settled w/ quorum is mineable");
        uint256 total = miner.mineSettledThought(0);
        uint256 share = REWARD / 3;
        assertEq(total, share * 3, "minted to the 3 winners");
        assertEq(coin.balanceOf(V[0]), share, "NO winner rewarded");
        assertEq(coin.balanceOf(V[1]), share);
        assertEq(coin.balanceOf(V[2]), share);
        assertEq(coin.balanceOf(V[3]), 0, "YES dissenter gets nothing");
        assertEq(coin.balanceOf(V[4]), 0);
        assertEq(coin.totalSupply(), share * 3, "supply == minted");
        assertTrue(miner.minedThought(0));
        assertTrue(!miner.mineable(0), "already mined -> not mineable");
    }

    /// @notice The reward goes to the consensus validators, never the tx submitter.
    function test_RewardsValidatorsNotCaller() public {
        _quorum_3NO_2YES();
        vm.prank(address(0xDEAD)); // a random keeper triggers the mint
        miner.mineSettledThought(0);
        assertEq(coin.balanceOf(address(0xDEAD)), 0, "caller gets nothing");
        assertGt(coin.balanceOf(V[0]), 0, "winner rewarded");
    }

    function test_Replay_Reverts() public {
        _quorum_3NO_2YES();
        miner.mineSettledThought(0);
        vm.expectRevert(abi.encodeWithSelector(ThinkingMiner.AlreadyMined.selector, uint256(0)));
        miner.mineSettledThought(0);
    }

    function test_NotSettled_Reverts() public {
        gov.setThought(OPEN, 0, 0); // still open, no quorum
        assertTrue(!miner.mineable(0));
        vm.expectRevert(abi.encodeWithSelector(ThinkingMiner.NotSettled.selector, uint256(0)));
        miner.mineSettledThought(0);
    }

    function test_RewardClampedToEmissionAllowance() public {
        _quorum_3NO_2YES();
        uint256 allowed = coin.emissionAllowance();
        vm.prank(ADMIN);
        miner.setReward(allowed + 9_000_000 ether); // ask for far more than vested
        uint256 total = miner.mineSettledThought(0);
        uint256 share = allowed / 3;
        assertEq(total, share * 3, "clamped to the vested halving allowance");
    }

    /// @notice The SAME coin is minted by both the attestation path and this governance
    /// path: authorize a second minter and both succeed under the shared cap.
    function test_MultiMinter_BothPathsShareTheCap() public {
        address attestationMiner = address(0xBEEF); // stand-in for AICoinMiner
        vm.prank(ADMIN);
        coin.setMinter(attestationMiner, true);
        assertTrue(coin.isMinter(address(miner)) && coin.isMinter(attestationMiner), "both authorized");
        _quorum_3NO_2YES();
        miner.mineSettledThought(0);
        uint256 afterGov = coin.mintedSubsidy();
        vm.prank(attestationMiner);
        coin.mintSubsidy(address(0xCAFE), 1000 ether);
        assertEq(coin.mintedSubsidy(), afterGov + 1000 ether, "both paths advance the shared mintedSubsidy");
    }
}
