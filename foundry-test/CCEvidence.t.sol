// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {AttestationRootRegistry} from "../contracts/deployables/thinking/AttestationRootRegistry.sol";
import {CCEvidence} from "../contracts/deployables/thinking/evidence/CCEvidence.sol";
import {ComputeVerifier} from "../contracts/deployables/thinking/ComputeVerifier.sol";
import {ComputeProof, ComputeProofLib} from "../contracts/deployables/thinking/ComputeProofLib.sol";

/// @title CCEvidenceTest
/// @notice The CC (TEE) backend is STUBBED for the cert-chain math but is NOT a no-op: it still
/// enforces that an accepted attestation root vouched for the reportData. These tests prove the
/// trust decision lives on-chain even while the heavy X.509/SPDM walk is deferred to the Go
/// precompile precompile/computeattest — an un-vouched reportData, an unaccepted root, or a
/// non-voucher caller all fail.
contract CCEvidenceTest is Test {
    AttestationRootRegistry registry;
    CCEvidence cc;
    ComputeVerifier verifier;

    address constant ADMIN = address(0xA11CE);
    address constant VOUCHER = address(0x1005); // the computeattest precompile adapter
    address constant STRANGER = address(0xBAD);

    bytes32 constant ATT_ROOT = keccak256("nvidia-device-root");
    bytes32 constant RUNTIME_OK = bytes32(uint256(0x77) * _ONES);
    uint256 internal constant _ONES = 0x0101010101010101010101010101010101010101010101010101010101010101;
    bytes32 constant REPORT = keccak256("cc-report-fixture");

    function setUp() public {
        registry = new AttestationRootRegistry(ADMIN);
        cc = new CCEvidence(address(registry), ADMIN);
        verifier = new ComputeVerifier(address(registry), ADMIN);
        vm.startPrank(ADMIN);
        registry.setAttestationRoot(ATT_ROOT, true);
        registry.setRuntime(RUNTIME_OK, true);
        cc.setVoucher(VOUCHER, true);
        verifier.setBackend(1, address(cc)); // CC backend in slot 1
        vm.stopPrank();
    }

    function _evidence(bytes32 root) internal pure returns (bytes memory) {
        return abi.encode(root);
    }

    function test_Attests_OnlyAfterAcceptedRootVouches() public {
        // Before any vouch: false (not a no-op — it requires the vouch).
        assertFalse(cc.attests(REPORT, _evidence(ATT_ROOT)), "no vouch yet -> false");

        vm.prank(VOUCHER);
        cc.vouch(ATT_ROOT, REPORT);
        assertTrue(cc.attests(REPORT, _evidence(ATT_ROOT)), "vouched under accepted root -> true");
    }

    function test_Vouch_UnacceptedRoot_Rejected() public {
        bytes32 selfRoot = keccak256("self-signed-root");
        vm.prank(VOUCHER);
        vm.expectRevert(abi.encodeWithSelector(CCEvidence.RootNotAccepted.selector, selfRoot));
        cc.vouch(selfRoot, REPORT);
    }

    function test_Vouch_NonVoucher_Rejected() public {
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(CCEvidence.NotVoucher.selector, STRANGER));
        cc.vouch(ATT_ROOT, REPORT);
    }

    function test_Attests_RevokedRoot_FailsEvenAfterVouch() public {
        vm.prank(VOUCHER);
        cc.vouch(ATT_ROOT, REPORT);
        assertTrue(cc.attests(REPORT, _evidence(ATT_ROOT)), "valid before revoke");
        vm.prank(ADMIN);
        registry.revoke(ATT_ROOT);
        assertFalse(cc.attests(REPORT, _evidence(ATT_ROOT)), "revoked root -> attestation falls");
    }

    function test_Attests_WrongEvidenceLength_False() public {
        vm.prank(VOUCHER);
        cc.vouch(ATT_ROOT, REPORT);
        assertFalse(cc.attests(REPORT, hex"deadbeef"), "malformed evidence -> false");
    }

    /// @notice End-to-end through the verifier: a CC proof only passes when the binding holds AND
    /// the runtime is accepted AND the root vouched. Proves the CC slot composes with the gate.
    function test_Verifier_CCProof_FullPath() public {
        bytes32 reportData = ComputeProofLib.expectedReportData(
            3, keccak256("i"), bytes32(uint256(0x5e) * _ONES), keccak256("p"), keccak256("b"),
            address(0xCAFE), keccak256("o"), RUNTIME_OK
        );
        ComputeProof memory cp = ComputeProof({proofType: 1, reportData: reportData, evidence: _evidence(ATT_ROOT)});

        // Not vouched yet -> verifier returns false (the witness step fails).
        assertFalse(verifier.verify(cp, reportData, RUNTIME_OK), "unvouched CC proof rejected by verifier");

        vm.prank(VOUCHER);
        cc.vouch(ATT_ROOT, reportData);
        assertTrue(verifier.verify(cp, reportData, RUNTIME_OK), "vouched CC proof passes the full gate");
    }
}
