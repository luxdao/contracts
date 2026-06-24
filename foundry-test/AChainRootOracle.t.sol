// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {AChainRootOracle, IMLDSAVerify} from "../contracts/deployables/thinking/AChainRootOracle.sol";

/// Test double for the ML-DSA precompile: a signature is "valid" iff its first byte is 0x01. The
/// real precompile does the actual post-quantum verification (tested in precompile/mldsa); here we
/// exercise the oracle's trustless QUORUM logic.
contract MockMLDSA is IMLDSAVerify {
    function verify(bytes calldata, bytes calldata, bytes calldata sig) external pure returns (bool) {
        return sig.length > 0 && sig[0] == 0x01;
    }
}

contract AChainRootOracleTest is Test {
    AChainRootOracle oracle;
    MockMLDSA mock;
    address constant DAO = address(0xDA0);
    bytes[] keys; // 4 validator pubkeys, ascending by keccak

    bytes constant OK = hex"01"; // a "valid" ML-DSA signature (per the mock)
    bytes constant BAD = hex"00"; // an "invalid" one

    function setUp() public {
        mock = new MockMLDSA();
        oracle = new AChainRootOracle(address(mock), DAO);
        keys = _sortedKeys(4);
        vm.startPrank(DAO);
        for (uint256 i; i < keys.length; i++) {
            oracle.setValidator(keys[i], true);
        }
        oracle.setThreshold(3); // 3-of-4 quorum
        vm.stopPrank();
    }

    // THE TRUSTLESS RELAY: a quorum of validator ML-DSA signatures anchors a root — anyone may call.
    function test_QuorumMet_PermissionlessAnchor() public {
        (bytes[] memory pk, bytes[] memory sg) = _signers(3, true);
        vm.prank(address(0xBEEF)); // a RANDOM relayer — permissionless
        oracle.anchorRoot(bytes32("root-1"), 1, pk, sg);
        assertTrue(oracle.isKnownRoot(bytes32("root-1")), "a validator-quorum-signed root is accepted");
        assertEq(oracle.latestHeight(), 1);
    }

    function test_QuorumNotMet_Rejected() public {
        (bytes[] memory pk, bytes[] memory sg) = _signers(2, true); // only 2 < threshold 3
        vm.expectRevert(abi.encodeWithSelector(AChainRootOracle.QuorumNotMet.selector, 2, 3));
        oracle.anchorRoot(bytes32("root"), 1, pk, sg);
    }

    function test_InvalidSignatureNotCounted() public {
        // 3 registered validators sign, but one signature is invalid → only 2 count → quorum fails.
        bytes[] memory pk = new bytes[](3);
        bytes[] memory sg = new bytes[](3);
        (pk[0], pk[1], pk[2]) = (keys[0], keys[1], keys[2]);
        (sg[0], sg[1], sg[2]) = (OK, BAD, OK);
        vm.expectRevert(abi.encodeWithSelector(AChainRootOracle.QuorumNotMet.selector, 2, 3));
        oracle.anchorRoot(bytes32("root"), 1, pk, sg);
    }

    function test_NonValidatorRejected() public {
        bytes[] memory pk = new bytes[](1);
        bytes[] memory sg = new bytes[](1);
        pk[0] = abi.encodePacked("not-a-validator");
        sg[0] = OK;
        vm.expectRevert(abi.encodeWithSelector(AChainRootOracle.NotValidator.selector, keccak256(pk[0])));
        oracle.anchorRoot(bytes32("root"), 1, pk, sg);
    }

    function test_NonAscendingSignersRejected() public {
        // same validators but out of ascending-keccak order → rejected (anti double-count).
        bytes[] memory pk = new bytes[](3);
        bytes[] memory sg = new bytes[](3);
        (pk[0], pk[1], pk[2]) = (keys[2], keys[1], keys[0]); // descending
        (sg[0], sg[1], sg[2]) = (OK, OK, OK);
        vm.expectRevert(AChainRootOracle.SignersNotAscending.selector);
        oracle.anchorRoot(bytes32("root"), 1, pk, sg);
    }

    function test_DuplicateSignerRejected() public {
        bytes[] memory pk = new bytes[](3);
        bytes[] memory sg = new bytes[](3);
        (pk[0], pk[1], pk[2]) = (keys[0], keys[0], keys[1]); // key0 twice
        (sg[0], sg[1], sg[2]) = (OK, OK, OK);
        vm.expectRevert(AChainRootOracle.SignersNotAscending.selector);
        oracle.anchorRoot(bytes32("root"), 1, pk, sg);
    }

    function test_StaleHeightRejected() public {
        (bytes[] memory pk, bytes[] memory sg) = _signers(3, true);
        oracle.anchorRoot(bytes32("root-1"), 5, pk, sg);
        vm.expectRevert(abi.encodeWithSelector(AChainRootOracle.StaleHeight.selector, uint64(5), uint64(5)));
        oracle.anchorRoot(bytes32("root-2"), 5, pk, sg); // not newer
    }

    // ---- helpers -------------------------------------------------------------

    function _signers(uint256 k, bool valid) internal view returns (bytes[] memory pk, bytes[] memory sg) {
        pk = new bytes[](k);
        sg = new bytes[](k);
        for (uint256 i; i < k; i++) {
            pk[i] = keys[i];
            sg[i] = valid ? OK : BAD;
        }
    }

    function _sortedKeys(uint256 n) internal pure returns (bytes[] memory ks) {
        ks = new bytes[](n);
        for (uint256 i; i < n; i++) {
            ks[i] = abi.encodePacked("achain-validator-", i);
        }
        for (uint256 i; i < n; i++) {
            for (uint256 j; j + 1 < n; j++) {
                if (keccak256(ks[j]) > keccak256(ks[j + 1])) {
                    (ks[j], ks[j + 1]) = (ks[j + 1], ks[j]);
                }
            }
        }
    }
}
