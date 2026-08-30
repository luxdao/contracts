// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";

// --- Canonical OSS Safe (v1.5.0 SafeL2 singleton) ---
import { Safe } from "@safe-global/safe-smart-account/Safe.sol";
import { SafeL2 } from "@safe-global/safe-smart-account/SafeL2.sol";
import { SafeProxyFactory } from "@safe-global/safe-smart-account/proxies/SafeProxyFactory.sol";
import { CompatibilityFallbackHandler } from "@safe-global/safe-smart-account/handler/CompatibilityFallbackHandler.sol";
import { Enum } from "@safe-global/safe-smart-account/interfaces/Enum.sol";
// Transaction.operation is typed by this repo's own vendored copy of Safe's Enum, which solc
// treats as a distinct type from the one above even though both declare { Call, DelegateCall }.
import { Enum as Op } from "../contracts/mocks/safe-smart-account/common/Enum.sol";

// --- Lux DAO Azorius/Zodiac governance stack (all real, no mocks) ---
import { ModuleGovernorV1 } from "../contracts/deployables/modules/ModuleGovernorV1.sol";
import { StrategyV1 } from "../contracts/deployables/strategies/StrategyV1.sol";
import { VotingWeightERC20V1 } from "../contracts/deployables/strategies/voting-weight/VotingWeightERC20V1.sol";
import { VoteTrackerERC20V1 } from "../contracts/deployables/strategies/vote-trackers/VoteTrackerERC20V1.sol";
import {
    ProposerAdapterERC20V1
} from "../contracts/deployables/strategies/proposer-adapters/ProposerAdapterERC20V1.sol";
import { VotesERC20V1 } from "../contracts/deployables/erc20/VotesERC20V1.sol";

import { IModuleGovernorV1 } from "../contracts/interfaces/dao/deployables/IModuleGovernorV1.sol";
import { IStrategyV1 } from "../contracts/interfaces/dao/deployables/IStrategyV1.sol";
import { IVotingTypes } from "../contracts/interfaces/dao/deployables/IVotingTypes.sol";
import { IVotesERC20V1 } from "../contracts/interfaces/dao/deployables/IVotesERC20V1.sol";
import { Transaction } from "../contracts/interfaces/dao/Module.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Records the caller of its function. Used to *prove* the inner call's
/// `msg.sender` is the Safe (i.e. the proposal really executed THROUGH the Safe).
contract CallRecorder {
    address public lastCaller;
    uint256 public lastValue;

    function record() external payable {
        lastCaller = msg.sender;
        lastValue = msg.value;
    }
}

/// @title GovSafeModule — Governor module with the Safe as executor (Azorius/Zodiac)
/// @notice Proves the full local lifecycle: a 1/1 canonical OSS Safe enables the Lux DAO
/// `ModuleGovernorV1` as a Zodiac module; a passed token-weighted proposal then moves the
/// Safe's own ETH and ERC20 treasury to a recipient via `execTransactionFromModule`.
contract GovSafeModuleTest is Test {
    // Safe infra
    SafeL2 internal singleton;
    SafeProxyFactory internal factory;
    CompatibilityFallbackHandler internal handler;
    Safe internal safe;

    // DAO stack
    VotesERC20V1 internal token;
    ProposerAdapterERC20V1 internal proposerAdapter;
    VotingWeightERC20V1 internal votingWeight;
    VoteTrackerERC20V1 internal voteTracker;
    StrategyV1 internal strategy;
    ModuleGovernorV1 internal governor;

    CallRecorder internal recorder;

    // Actors
    address internal ownerEOA; // sole Safe owner (1/1)
    uint256 internal ownerPk;
    address internal voter; // holds + delegates voting power
    address internal recipient; // treasury disbursement target

    // Config
    uint256 internal constant VOTER_SUPPLY = 1_000_000e18;
    uint256 internal constant SAFE_SUPPLY = 500_000e18; // ERC20 held by the Safe treasury
    uint256 internal constant MAX_SUPPLY = 10_000_000e18;
    uint256 internal constant QUORUM = 100_000e18;
    uint256 internal constant BASIS = 500_000; // 50% (denominator 1e6); strict > means >50% passes
    uint32 internal constant VOTING_PERIOD = 3600;
    uint32 internal constant TIMELOCK = 3600;
    uint32 internal constant EXEC_PERIOD = 3600;
    uint256 internal constant START = 1_000_000;
    uint256 internal constant SAFE_ETH = 5 ether;
    uint256 internal constant ETH_GRANT = 1 ether;

    address internal constant SENTINEL_MODULES = address(0x1);

    function setUp() public {
        vm.warp(START);

        (ownerEOA, ownerPk) = makeAddrAndKey("safeOwner");
        voter = makeAddr("voter");
        recipient = makeAddr("recipient");
        recorder = new CallRecorder();

        _deploySafe();
        _deployDaoStack();
        _enableModuleViaSignedSafeTx();

        // Fund the Safe treasury (ETH). ERC20 treasury was allocated at token genesis.
        vm.deal(address(safe), SAFE_ETH);
    }

    // ======================================================================
    // STEP 1 — canonical 1/1 Safe
    // ======================================================================

    function _deploySafe() internal {
        singleton = new SafeL2();
        factory = new SafeProxyFactory();
        handler = new CompatibilityFallbackHandler();

        address[] memory owners = new address[](1);
        owners[0] = ownerEOA;

        bytes memory setupData = abi.encodeCall(
            Safe.setup, (owners, 1, address(0), "", address(handler), address(0), 0, payable(address(0)))
        );

        safe = Safe(payable(address(factory.createProxyWithNonce(address(singleton), setupData, 0))));

        assertEq(safe.getThreshold(), 1, "threshold");
        assertTrue(safe.isOwner(ownerEOA), "owner");
        assertEq(safe.getOwners().length, 1, "1/1");
    }

    // ======================================================================
    // STEP 2 — Votes token + strategy + Governor module behind proxies
    // ======================================================================

    function _deployDaoStack() internal {
        // Votes token: genesis-allocate voting power to `voter` and ERC20 treasury to the Safe.
        IVotesERC20V1.Metadata memory md = IVotesERC20V1.Metadata({ name: "Lux DAO", symbol: "LUXDAO" });
        IVotesERC20V1.Allocation[] memory allocs = new IVotesERC20V1.Allocation[](2);
        allocs[0] = IVotesERC20V1.Allocation({ to: voter, amount: VOTER_SUPPLY });
        allocs[1] = IVotesERC20V1.Allocation({ to: address(safe), amount: SAFE_SUPPLY });
        token = VotesERC20V1(
            _proxy(
                address(new VotesERC20V1()),
                abi.encodeCall(VotesERC20V1.initialize, (md, allocs, ownerEOA, false, MAX_SUPPLY))
            )
        );

        // Activate the voter's voting power (ERC20Votes requires explicit delegation).
        vm.prank(voter);
        token.delegate(voter);

        // Proposer gate: must hold delegated voting power to submit.
        proposerAdapter = ProposerAdapterERC20V1(
            _proxy(
                address(new ProposerAdapterERC20V1()),
                abi.encodeCall(ProposerAdapterERC20V1.initialize, (address(token), 1))
            )
        );

        // Voting weight = delegated balance * 1.
        votingWeight = VotingWeightERC20V1(
            _proxy(
                address(new VotingWeightERC20V1()), abi.encodeCall(VotingWeightERC20V1.initialize, (address(token), 1))
            )
        );

        // Strategy (phase 1): voting params + proposer adapters. No light-account factory.
        address[] memory adapters = new address[](1);
        adapters[0] = address(proposerAdapter);
        strategy = StrategyV1(
            _proxy(
                address(new StrategyV1()),
                abi.encodeCall(StrategyV1.initialize, (VOTING_PERIOD, QUORUM, BASIS, adapters, address(0)))
            )
        );

        // Vote tracker authorizes the strategy as its sole recorder.
        address[] memory callers = new address[](1);
        callers[0] = address(strategy);
        voteTracker = VoteTrackerERC20V1(
            _proxy(address(new VoteTrackerERC20V1()), abi.encodeCall(VoteTrackerERC20V1.initialize, (callers)))
        );

        // Governor module: Safe is BOTH avatar and target → "Safe as executor".
        // owner = ownerEOA (module admin), avatar = target = Safe.
        bytes memory govParams =
            abi.encode(ownerEOA, address(safe), address(safe), address(strategy), TIMELOCK, EXEC_PERIOD);
        governor = ModuleGovernorV1(
            _proxy(address(new ModuleGovernorV1()), abi.encodeWithSignature("setUp(bytes)", govParams))
        );

        // Strategy (phase 2): bind governor as strategy admin + wire voting configs.
        IVotingTypes.VotingConfig[] memory configs = new IVotingTypes.VotingConfig[](1);
        configs[0] =
            IVotingTypes.VotingConfig({ votingWeight: address(votingWeight), voteTracker: address(voteTracker) });
        strategy.initialize2(address(governor), configs);

        assertEq(governor.avatar(), address(safe), "avatar");
        assertEq(governor.target(), address(safe), "target");
        assertEq(governor.strategy(), address(strategy), "strategy");
        assertEq(strategy.strategyAdmin(), address(governor), "strategyAdmin");
    }

    // ======================================================================
    // STEP 3 — enable the module by EXECUTING a signed Safe transaction
    // ======================================================================

    function _enableModuleViaSignedSafeTx() internal {
        bytes memory data = abi.encodeWithSignature("enableModule(address)", address(governor));
        _execSafe(address(safe), 0, data);
        assertTrue(safe.isModuleEnabled(address(governor)), "module enabled");
    }

    /// @dev Build, sign (owner EOA), and execute a real Safe transaction (1/1 ECDSA).
    function _execSafe(address to, uint256 value, bytes memory data) internal {
        uint256 nonce = safe.nonce();
        bytes32 txHash =
            safe.getTransactionHash(to, value, data, Enum.Operation.Call, 0, 0, 0, address(0), address(0), nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, txHash);
        bytes memory sig = abi.encodePacked(r, s, v);
        safe.execTransaction(to, value, data, Enum.Operation.Call, 0, 0, 0, address(0), payable(address(0)), sig);
    }

    function _proxy(address impl, bytes memory data) internal returns (address) {
        return address(new ERC1967Proxy(impl, data));
    }

    // ======================================================================
    // TESTS
    // ======================================================================

    /// The module is really enabled on the Safe (and points back at the Safe).
    function test_ModuleEnabledOnSafe() public view {
        assertTrue(safe.isModuleEnabled(address(governor)));
        (address[] memory mods,) = safe.getModulesPaginated(SENTINEL_MODULES, 10);
        assertEq(mods.length, 1);
        assertEq(mods[0], address(governor));
        // Safe ownership is untouched by enabling the module.
        assertEq(safe.getOwners()[0], ownerEOA);
        assertEq(safe.getThreshold(), 1);
    }

    /// STEP 4 — full lifecycle: a passed proposal makes the SAFE disburse its own
    /// ETH + ERC20 treasury, and the recorded inner caller is the Safe itself.
    function test_FullLifecycle_SafeAsExecutor() public {
        // --- submit ---
        // NB: absolute warps only. With via_ir the optimizer CSE-caches `block.timestamp`
        // across the `vm.warp` cheatcode, so `block.timestamp + n` reads are unreliable here.
        vm.warp(START + 100);
        uint32 pid = governor.totalProposalCount();

        Transaction[] memory txs = new Transaction[](3);
        txs[0] = Transaction({ to: recipient, value: ETH_GRANT, data: "", operation: Op.Operation.Call });
        txs[1] = Transaction({
            to: address(token),
            value: 0,
            data: abi.encodeCall(IERC20.transfer, (recipient, SAFE_SUPPLY)),
            operation: Op.Operation.Call
        });
        txs[2] = Transaction({
            to: address(recorder), value: 0, data: abi.encodeWithSignature("record()"), operation: Op.Operation.Call
        });

        vm.prank(voter);
        governor.submitProposal(txs, "treasury disbursement", address(proposerAdapter), "");
        assertEq(uint8(governor.proposalState(pid)), uint8(IModuleGovernorV1.ProposalState.ACTIVE));

        // --- vote YES (within voting window; getPastVotes needs start < now) ---
        vm.warp(START + 200);
        _castYes(pid);

        // --- advance past voting end + timelock → EXECUTABLE ---
        (, uint48 end) = strategy.getVotingTimestamps(pid);
        vm.warp(uint256(end) + TIMELOCK + 1);
        assertEq(uint8(governor.proposalState(pid)), uint8(IModuleGovernorV1.ProposalState.EXECUTABLE));

        uint256 safeEthBefore = address(safe).balance;

        // --- execute (anyone may execute a passed proposal) ---
        governor.executeProposal(pid, txs);

        // --- proof: Safe-as-executor ---
        assertEq(uint8(governor.proposalState(pid)), uint8(IModuleGovernorV1.ProposalState.EXECUTED), "executed");
        // ETH moved out of the Safe to the recipient.
        assertEq(recipient.balance, ETH_GRANT, "recipient ETH");
        assertEq(address(safe).balance, safeEthBefore - ETH_GRANT, "safe ETH debited");
        // ERC20 treasury moved out of the Safe to the recipient.
        assertEq(token.balanceOf(recipient), SAFE_SUPPLY, "recipient ERC20");
        assertEq(token.balanceOf(address(safe)), 0, "safe ERC20 drained");
        // The inner call's msg.sender WAS the Safe → execution went through the Safe.
        assertEq(recorder.lastCaller(), address(safe), "inner caller == Safe");
        // Governor itself never custodied the assets.
        assertEq(address(governor).balance, 0, "governor holds no ETH");
        assertEq(token.balanceOf(address(governor)), 0, "governor holds no ERC20");
    }

    /// A passed proposal cannot execute while still in timelock.
    function test_PrematureExecution_Reverts() public {
        vm.warp(START + 100);
        uint32 pid = governor.totalProposalCount();
        Transaction[] memory txs = _ethTx();

        vm.prank(voter);
        governor.submitProposal(txs, "x", address(proposerAdapter), "");
        vm.warp(START + 200);
        _castYes(pid);

        // Past voting end but inside timelock → TIMELOCKED, not yet executable.
        (, uint48 end) = strategy.getVotingTimestamps(pid);
        vm.warp(uint256(end) + 1);
        assertEq(uint8(governor.proposalState(pid)), uint8(IModuleGovernorV1.ProposalState.TIMELOCKED));

        vm.expectRevert(IModuleGovernorV1.ProposalNotExecutable.selector);
        governor.executeProposal(pid, txs);
        // Safe treasury untouched.
        assertEq(address(safe).balance, SAFE_ETH);
    }

    /// A proposal that never reaches quorum FAILS and cannot disburse the treasury.
    function test_FailedProposal_NoQuorum_Reverts() public {
        vm.warp(START + 100);
        uint32 pid = governor.totalProposalCount();
        Transaction[] memory txs = _ethTx();

        vm.prank(voter);
        governor.submitProposal(txs, "x", address(proposerAdapter), "");

        // No votes cast → quorum unmet → FAILED once voting closes.
        (, uint48 end) = strategy.getVotingTimestamps(pid);
        vm.warp(uint256(end) + 1);
        assertEq(uint8(governor.proposalState(pid)), uint8(IModuleGovernorV1.ProposalState.FAILED));

        vm.expectRevert(IModuleGovernorV1.ProposalNotExecutable.selector);
        governor.executeProposal(pid, txs);
        assertEq(address(safe).balance, SAFE_ETH);
    }

    /// Only the Safe owner can produce a valid signature to enable a module.
    function test_EnableModule_BadSignature_Reverts() public {
        ModuleGovernorV1 rogue = ModuleGovernorV1(
            _proxy(
                address(new ModuleGovernorV1()),
                abi.encodeWithSignature(
                    "setUp(bytes)",
                    abi.encode(ownerEOA, address(safe), address(safe), address(strategy), TIMELOCK, EXEC_PERIOD)
                )
            )
        );
        bytes memory data = abi.encodeWithSignature("enableModule(address)", address(rogue));
        uint256 nonce = safe.nonce();
        bytes32 txHash = safe.getTransactionHash(
            address(safe), 0, data, Enum.Operation.Call, 0, 0, 0, address(0), address(0), nonce
        );
        // Sign with a NON-owner key.
        (, uint256 strangerPk) = makeAddrAndKey("stranger");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(strangerPk, txHash);
        bytes memory sig = abi.encodePacked(r, s, v);
        vm.expectRevert(); // GS026: invalid owner provided
        safe.execTransaction(address(safe), 0, data, Enum.Operation.Call, 0, 0, 0, address(0), payable(address(0)), sig);
        assertFalse(safe.isModuleEnabled(address(rogue)));
    }

    // ----- helpers -----

    function _castYes(uint32 pid) internal {
        IVotingTypes.VotingConfigVoteData[] memory vd = new IVotingTypes.VotingConfigVoteData[](1);
        vd[0] = IVotingTypes.VotingConfigVoteData({ configIndex: 0, voteData: "" });
        vm.prank(voter);
        strategy.castVote(pid, uint8(IStrategyV1.VoteType.YES), vd, 0);
    }

    function _ethTx() internal view returns (Transaction[] memory txs) {
        txs = new Transaction[](1);
        txs[0] = Transaction({ to: recipient, value: ETH_GRANT, data: "", operation: Op.Operation.Call });
    }
}
