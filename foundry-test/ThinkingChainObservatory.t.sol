// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ThinkingChainObservatory} from "../contracts/deployables/thinking/ThinkingChainObservatory.sol";
import {ProofOfThoughtRegistry} from "../contracts/deployables/thinking/ProofOfThoughtRegistry.sol";
import {AICoin} from "../contracts/deployables/thinking/AICoin.sol";
import {IProofOfThoughtRegistry} from "../contracts/deployables/thinking/interfaces/IProofOfThoughtRegistry.sol";
import {IThinkingGovernor} from "../contracts/deployables/thinking/interfaces/IThinkingGovernor.sol";
import {IAICoin} from "../contracts/deployables/thinking/interfaces/IAICoin.sol";
import {IThinkingParameters} from "../contracts/deployables/thinking/interfaces/IThinkingParameters.sol";

/// @dev Minimal ThinkingParameters stand-in: a controllable round list so the
/// observatory's recentParameterRounds can be tested without the full sortition
/// machinery (that is covered by ThinkingParameters' own 16 tests).
contract MockParameters {
    IThinkingParameters.Round[] internal _rounds;
    mapping(bytes32 => mapping(bytes32 => uint256)) internal _val;
    mapping(bytes32 => mapping(bytes32 => bool)) internal _set;

    function push(IThinkingParameters.Round memory r) external {
        _rounds.push(r);
    }

    function setValue(bytes32 spec, string calldata key, uint256 v) external {
        _val[spec][keccak256(bytes(key))] = v;
        _set[spec][keccak256(bytes(key))] = true;
    }

    function roundCount() external view returns (uint256) {
        return _rounds.length;
    }

    function getRound(uint256 id) external view returns (IThinkingParameters.Round memory) {
        return _rounds[id];
    }

    function valueOf(bytes32 spec, string calldata key) external view returns (uint256, bool) {
        return (_val[spec][keccak256(bytes(key))], _set[spec][keccak256(bytes(key))]);
    }
}

/// @dev Minimal governor stand-in exposing only the views the observatory reads
/// (taskCount, getThought, getKnob, minBond, openFee, treasury). The governor's
/// quorum mechanics are covered by its own 59 tests; here we only need a
/// controllable task list + params.
contract MockGovernor {
    IThinkingGovernor.Thought[] internal _thoughts;
    mapping(bytes32 => mapping(bytes32 => bytes32)) internal _knobs;

    uint256 public minBond = 1 ether;
    uint256 public openFee = 0.1 ether;
    address public treasury = address(0x7EA5);

    function push(IThinkingGovernor.Thought memory t) external returns (uint256 id) {
        id = _thoughts.length;
        _thoughts.push(t);
    }

    function setKnob(bytes32 spec, string calldata key, bytes32 val) external {
        _knobs[spec][keccak256(bytes(key))] = val;
    }

    function taskCount() external view returns (uint256) {
        return _thoughts.length;
    }

    function getThought(uint256 id) external view returns (IThinkingGovernor.Thought memory) {
        return _thoughts[id];
    }

    function getKnob(bytes32 spec, string calldata key) external view returns (bytes32) {
        return _knobs[spec][keccak256(bytes(key))];
    }
}

/// @notice Proves the observatory batches thinking-chain state for the DAO
/// dashboard: lifecycle tallies, newest-first thought/receipt pages, knob reads.
contract ThinkingChainObservatoryTest is Test {
    ProofOfThoughtRegistry reg;
    MockGovernor gov;
    ThinkingChainObservatory obs;
    AICoin coin;
    MockParameters params;

    bytes32 constant SPEC = keccak256("zen/thinking-governor/model-spec/v1");
    address constant PAYER = address(0xA11CE);
    address constant OPERATOR = address(0x09E7A7);

    function setUp() public {
        vm.warp(1_700_000_000);
        reg = new ProofOfThoughtRegistry(address(this)); // test is admin
        reg.setRecorder(address(this), true); // ...and records receipts directly
        gov = new MockGovernor();
        // the test contract is the coin's minter, so it can mine in test_Economics
        coin = new AICoin("AI", "AI", address(this), address(this), 0);
        params = new MockParameters();
        obs = new ThinkingChainObservatory(IThinkingGovernor(address(gov)), reg, IAICoin(address(coin)), IThinkingParameters(address(params)));
    }

    // ---- value-deciding governance is visible from the single surface ----------

    function test_RecentParameterRounds_NewestFirst() public {
        params.push(_round("beluga.tithe.bps", 0, 2000, IThinkingParameters.Status.Settled, 1500));
        params.push(_round("aivm.fee.floor", 1, 1000, IThinkingParameters.Status.Open, 0));
        ThinkingChainObservatory.ParameterRoundView[] memory v = obs.recentParameterRounds(10);
        assertEq(v.length, 2, "both rounds");
        assertEq(v[0].roundId, 1, "newest first");
        assertEq(v[0].knobKey, "aivm.fee.floor");
        assertEq(uint8(v[0].status), uint8(IThinkingParameters.Status.Open));
        assertEq(v[1].knobKey, "beluga.tithe.bps");
        assertEq(uint8(v[1].status), uint8(IThinkingParameters.Status.Settled));
        assertEq(v[1].canonicalValue, 1500, "decided median visible on-chain");
        // and the live decided value passthrough
        params.setValue(SPEC, "beluga.tithe.bps", 1500);
        (uint256 val, bool decided) = obs.parameterValue(SPEC, "beluga.tithe.bps");
        assertEq(val, 1500);
        assertTrue(decided);
    }

    function test_RecentParameterRounds_EmptyWhenNoParameters() public {
        ThinkingChainObservatory o2 = new ThinkingChainObservatory(IThinkingGovernor(address(gov)), reg, IAICoin(address(coin)), IThinkingParameters(address(0)));
        assertEq(o2.recentParameterRounds(10).length, 0, "no parameters -> empty (degrades cleanly)");
        (uint256 val, bool decided) = o2.parameterValue(SPEC, "x");
        assertEq(val, 0);
        assertFalse(decided);
    }

    function _round(string memory knob, uint256 lo, uint256 hi, IThinkingParameters.Status status, uint256 canonical)
        internal
        pure
        returns (IThinkingParameters.Round memory r)
    {
        r.modelSpecHash = SPEC;
        r.knobKey = knob;
        r.lo = lo;
        r.hi = hi;
        r.n = 5;
        r.threshold = 3;
        r.status = status;
        r.submissionCount = status == IThinkingParameters.Status.Settled ? 5 : 2;
        r.canonicalValue = canonical;
    }

    function _thought(IThinkingGovernor.Status s, string memory knobKey, IThinkingGovernor.Vote v, uint16 bucket)
        internal
        pure
        returns (IThinkingGovernor.Thought memory t)
    {
        t.modelSpecHash = SPEC;
        t.promptHash = keccak256(bytes(knobKey));
        t.n = 5;
        t.threshold = 3;
        t.status = s;
        t.submissionCount = s == IThinkingGovernor.Status.Open ? 1 : 5;
        t.knobKey = knobKey;
        t.canonicalVote = v;
        t.canonicalBucket = bucket;
        t.agreeCount = s == IThinkingGovernor.Status.Settled ? 4 : 0;
    }

    function _registerReceipt(bytes32 salt) internal returns (bytes32 id) {
        id = reg.register(
            SPEC, salt, keccak256(abi.encode("out", salt)), keccak256(abi.encode("pay", salt)), bytes32(0), PAYER, OPERATOR, 1
        );
    }

    function test_Overview_TalliesLifecycleAndVolume() public {
        gov.push(_thought(IThinkingGovernor.Status.Open, "aivm.quorum.threshold", IThinkingGovernor.Vote.Invalid, 0));
        gov.push(_thought(IThinkingGovernor.Status.Settled, "aivm.quorum.n", IThinkingGovernor.Vote.Yes, 8000));
        gov.push(_thought(IThinkingGovernor.Status.Settled, "aivm.min.bond", IThinkingGovernor.Vote.No, 6000));
        gov.push(_thought(IThinkingGovernor.Status.Failed, "aivm.reward", IThinkingGovernor.Vote.Invalid, 0));

        _registerReceipt(keccak256("r1"));
        _registerReceipt(keccak256("r2"));

        ThinkingChainObservatory.Overview memory o = obs.overview();
        assertEq(o.taskCount, 4, "taskCount");
        assertEq(o.openCount, 1, "open");
        assertEq(o.settledCount, 2, "settled");
        assertEq(o.failedCount, 1, "failed");
        assertEq(o.thoughtReceipts, 2, "PoT receipts");
        assertEq(o.minBond, 1 ether, "minBond");
        assertEq(o.openFee, 0.1 ether, "openFee");
        assertEq(o.treasury, address(0x7EA5), "treasury");
    }

    function test_Overview_EmptyNetwork() public view {
        ThinkingChainObservatory.Overview memory o = obs.overview();
        assertEq(o.taskCount, 0);
        assertEq(o.settledCount, 0);
        assertEq(o.thoughtReceipts, 0);
    }

    /// @notice The observatory makes the chain's Bitcoin-shaped economics visible:
    /// 1B cap, halving epoch, schedule-vested unlock, mined, burned, supply.
    function test_Economics_SeesIssuanceBehavior() public {
        uint256 MAX = coin.MAX_SUBSIDY();
        uint256 PERIOD = coin.HALVING_PERIOD();

        ThinkingChainObservatory.Economics memory e0 = obs.economics();
        assertEq(e0.coin, address(coin), "coin address visible");
        assertEq(e0.hardCap, MAX, "1B cap visible");
        assertEq(e0.epoch, 0);
        assertEq(e0.minted, 0);
        assertEq(e0.circulating, 0);
        assertEq(e0.burned, 0);
        assertEq(e0.remaining, MAX);

        // halfway into epoch 0 -> MAX/4 unlocked; mine 1000 AI, burn 250 AI
        vm.warp(coin.GENESIS() + PERIOD / 2);
        coin.mintSubsidy(OPERATOR, 1000 ether);
        vm.prank(OPERATOR);
        coin.burn(250 ether);

        ThinkingChainObservatory.Economics memory e = obs.economics();
        assertEq(e.epoch, 0, "still epoch 0");
        assertEq(e.epochSubsidy, MAX / 2, "E_0 = MAX/2");
        assertEq(e.unlocked, MAX / 4, "mid-epoch-0 unlocked = MAX/4");
        assertEq(e.minted, 1000 ether, "mined");
        assertEq(e.circulating, 750 ether, "supply after burn");
        assertEq(e.burned, 250 ether, "burned = minted - circulating");
        assertEq(e.remaining, MAX - 1000 ether, "remaining subsidy");
    }

    function test_Economics_CoinlessChainDegradesToZero() public {
        ThinkingChainObservatory obs2 =
            new ThinkingChainObservatory(IThinkingGovernor(address(gov)), reg, IAICoin(address(0)), IThinkingParameters(address(0)));
        ThinkingChainObservatory.Economics memory e = obs2.economics();
        assertEq(e.coin, address(0), "no coin");
        assertEq(e.hardCap, 0);
        assertEq(e.minted, 0);
        assertEq(e.remaining, 0);
    }

    function test_RecentThoughts_NewestFirstAndTruncates() public {
        gov.push(_thought(IThinkingGovernor.Status.Settled, "k0", IThinkingGovernor.Vote.Yes, 1000));
        gov.push(_thought(IThinkingGovernor.Status.Settled, "k1", IThinkingGovernor.Vote.Yes, 2000));
        gov.push(_thought(IThinkingGovernor.Status.Open, "k2", IThinkingGovernor.Vote.Invalid, 0));

        // ask for 2 of 3 → newest first: task 2 then task 1
        ThinkingChainObservatory.ThoughtView[] memory v = obs.recentThoughts(2);
        assertEq(v.length, 2, "truncated to 2");
        assertEq(v[0].taskId, 2, "newest first");
        assertEq(v[0].knobKey, "k2");
        assertEq(uint8(v[0].status), uint8(IThinkingGovernor.Status.Open));
        assertEq(v[1].taskId, 1, "second newest");
        assertEq(v[1].canonicalBucket, 2000);

        // ask for more than exist → clamps to 3
        ThinkingChainObservatory.ThoughtView[] memory all = obs.recentThoughts(100);
        assertEq(all.length, 3, "clamped to taskCount");
        assertEq(all[2].taskId, 0, "oldest last");
    }

    function test_RecentReceipts_NewestFirstAndTruncates() public {
        bytes32 id0 = _registerReceipt(keccak256("a"));
        bytes32 id1 = _registerReceipt(keccak256("b"));
        bytes32 id2 = _registerReceipt(keccak256("c"));

        IProofOfThoughtRegistry.ThoughtReceipt[] memory r = obs.recentReceipts(2);
        assertEq(r.length, 2, "truncated");
        // newest first: c then b
        assertEq(r[0].promptHash, keccak256("c"), "newest receipt first");
        assertEq(r[1].promptHash, keccak256("b"), "second newest");
        assertEq(r[0].payer, PAYER);
        assertEq(r[0].operator, OPERATOR);

        IProofOfThoughtRegistry.ThoughtReceipt[] memory all = obs.recentReceipts(100);
        assertEq(all.length, 3, "clamped to receiptCount");
        assertEq(all[2].promptHash, keccak256("a"), "oldest last");

        // sanity: ids are distinct and recorded
        assertTrue(reg.exists(id0) && reg.exists(id1) && reg.exists(id2));
    }

    function test_Knob_Passthrough() public {
        gov.setKnob(SPEC, "aivm.quorum.threshold", bytes32(uint256(3)));
        assertEq(obs.knob(SPEC, "aivm.quorum.threshold"), bytes32(uint256(3)), "live knob value");
        assertEq(obs.knob(SPEC, "unset.key"), bytes32(0), "unset knob = 0");
    }
}
