// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ConsensusExecutor, IThinkingValue} from "../contracts/deployables/thinking/ConsensusExecutor.sol";

/// Stand-in for ThinkingParameters: a knob's validator-decided value.
contract MockConsensus is IThinkingValue {
    mapping(bytes32 => mapping(bytes32 => uint256)) value;
    mapping(bytes32 => mapping(bytes32 => bool)) decided;

    function set(bytes32 spec, string calldata key, uint256 v) external {
        bytes32 k = keccak256(bytes(key));
        value[spec][k] = v;
        decided[spec][k] = true;
    }

    function valueOf(bytes32 spec, string calldata key) external view returns (uint256, bool) {
        bytes32 k = keccak256(bytes(key));
        return (value[spec][k], decided[spec][k]);
    }
}

/// A governed contract: any param settable ONLY by the executor (the consensus governor).
contract Governed {
    address public governor;
    bool public flag; // yes/no
    uint256 public limit; // a number
    int256 public rate; // a signed number

    constructor(address g) {
        governor = g;
    }

    modifier onlyGov() {
        require(msg.sender == governor, "not gov");
        _;
    }

    function setFlag(bool v) external onlyGov {
        flag = v;
    }

    function setLimit(uint256 v) external onlyGov {
        limit = v;
    }

    function setRate(int256 v) external onlyGov {
        rate = v;
    }
}

contract ConsensusExecutorTest is Test {
    MockConsensus consensus;
    ConsensusExecutor exec;
    Governed gov;
    bytes32 constant SPEC = bytes32("zen-coder-flash");

    function setUp() public {
        consensus = new MockConsensus();
        exec = new ConsensusExecutor(address(consensus));
        gov = new Governed(address(exec));
    }

    // a NUMBER decided by consensus is written into the target's uint param.
    function test_EnactNumber() public {
        consensus.set(SPEC, "tithe_bps", 1500);
        exec.enact(SPEC, "tithe_bps", address(gov), gov.setLimit.selector);
        assertEq(gov.limit(), 1500, "consensus number enacted");
    }

    // YES/NO: value 1 = yes, 0 = no, written into a bool param.
    function test_EnactBool_YesNo() public {
        consensus.set(SPEC, "paused", 1);
        exec.enact(SPEC, "paused", address(gov), gov.setFlag.selector);
        assertTrue(gov.flag(), "consensus YES (1) sets the flag");
        consensus.set(SPEC, "paused", 0);
        exec.enact(SPEC, "paused", address(gov), gov.setFlag.selector);
        assertFalse(gov.flag(), "consensus NO (0) clears it");
    }

    // a SIGNED number (the 32-byte word reinterpreted as int256).
    function test_EnactSignedInt() public {
        consensus.set(SPEC, "rate", uint256(int256(-42)));
        exec.enact(SPEC, "rate", address(gov), gov.setRate.selector);
        assertEq(gov.rate(), -42, "consensus signed number enacted");
    }

    function test_NotDecided_Reverts() public {
        vm.expectRevert(ConsensusExecutor.NotDecided.selector);
        exec.enact(SPEC, "undecided", address(gov), gov.setLimit.selector);
    }

    // STRUCTURED READ: query any var back, typed.
    function test_ReadStructured() public {
        consensus.set(SPEC, "tithe_bps", 777);
        exec.enact(SPEC, "tithe_bps", address(gov), gov.setLimit.selector);
        assertEq(exec.readUint(address(gov), abi.encodeWithSelector(gov.limit.selector)), 777, "readUint");
        consensus.set(SPEC, "paused", 1);
        exec.enact(SPEC, "paused", address(gov), gov.setFlag.selector);
        assertTrue(exec.readBool(address(gov), abi.encodeWithSelector(gov.flag.selector)), "readBool yes/no");
    }

    // only the executor (driven by consensus) can write the param.
    function test_TargetTrustsOnlyExecutor() public {
        vm.expectRevert(bytes("not gov"));
        gov.setLimit(999);
    }
}
