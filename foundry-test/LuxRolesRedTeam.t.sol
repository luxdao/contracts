// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.31;

import "forge-std/Test.sol";
import { LuxRolesV1 } from "../contracts/roles/LuxRolesV1.sol";
import { LuxRolesAccount1ofNV1 } from "../contracts/roles/LuxRolesAccount1ofNV1.sol";
import { ERC6551Registry } from "../contracts/roles/ERC6551Registry.sol";

/// @dev eligibility module that returns a NON-standard-length payload (>64 bytes) while still
///      "intending" to revoke (eligible=false). Probes the `== 64` vs `>= 64` fallback direction.
contract OverlongEligibility {
    function getWearerStatus(address, uint256) external pure returns (bool, bool, uint256) {
        // wants to REVOKE (eligible=false) but returns 96 bytes.
        return (false, true, 0xdead);
    }
}

/// @dev eligibility module that reverts — probes fail-closed vs fail-open on module revert.
contract RevertingEligibility {
    function getWearerStatus(address, uint256) external pure returns (bool, bool) {
        revert("boom");
    }
}

/// @dev toggle module returning overlong data while intending to deactivate.
contract OverlongToggle {
    function getHatStatus(uint256) external pure returns (bool, uint256) {
        return (false, 0xdead); // wants OFF, returns 64 bytes
    }
}

/// @dev sink to receive ETH from a sub-wallet execute().
contract Sink {
    receive() external payable { }
}

contract LuxRolesRedTeam is Test {
    address internal constant CANONICAL_REGISTRY = 0x000000006551c19487814612e58FE06813775758;
    bytes4 internal constant MAGIC_SIGNER = 0x523e3260;
    bytes4 internal constant MAGIC_1271 = 0x1626ba7e;

    LuxRolesV1 internal roles;
    LuxRolesAccount1ofNV1 internal accountImpl;

    address internal org = makeAddr("org");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal mallory = makeAddr("mallory");

    uint256 internal topHatId;
    uint256 internal adminHatId; // level 1, worn by alice
    uint256 internal roleHatId; // level 2, worn by bob (the leaf)

    function setUp() public {
        roles = new LuxRolesV1();
        accountImpl = new LuxRolesAccount1ofNV1();

        topHatId = roles.mintTopHat(org, "top", "");
        vm.prank(org);
        adminHatId = roles.createHat(topHatId, "admin", 2, org, org, true, "");
        vm.prank(org);
        roles.mintHat(adminHatId, alice);
        vm.prank(alice);
        roleHatId = roles.createHat(adminHatId, "role", 2, org, org, true, "");
        vm.prank(alice);
        roles.mintHat(roleHatId, bob);

        if (CANONICAL_REGISTRY.code.length == 0) {
            ERC6551Registry impl = new ERC6551Registry();
            vm.etch(CANONICAL_REGISTRY, address(impl).code);
        }
    }

    /*//////////////////////////////////////////////////////////////
        VECTOR 2 — level-math ancestor spoof via crafted/gap ids
    //////////////////////////////////////////////////////////////*/

    /// @notice bob (leaf) cannot become admin of itself, its parent, a sibling, or the top —
    ///         not via honest ids and not via malformed "gap" ids.
    function test_V2_LeafCannotSpoofAncestorViaCraftedIds() public {
        // honest hierarchy checks
        assertFalse(roles.isAdminOfHat(bob, roleHatId), "leaf !admin of own hat");
        assertFalse(roles.isAdminOfHat(bob, adminHatId), "leaf !admin of parent");
        assertFalse(roles.isAdminOfHat(bob, topHatId), "leaf !admin of top");

        uint32 domain = roles.getTopHatDomain(topHatId);

        // craft a family of malformed / gap ids and assert bob is admin of NONE.
        uint256[] memory crafted = new uint256[](6);
        crafted[0] = uint256(domain) << 224 | (uint256(9) << 192); // gap: level-2 slot set, level-1 empty
        crafted[1] = uint256(domain) << 224 | (uint256(0xFFFF) << 208) | (uint256(0xFFFF) << 192); // dense sibling path
        crafted[2] = roleHatId | (uint256(1) << 176); // a *descendant* of bob's own hat (bob SHOULD admin this)
        crafted[3] = adminHatId | (uint256(7) << 176); // gap under admin (not bob's)
        crafted[4] = uint256(domain) << 224; // the top hat itself
        crafted[5] = adminHatId | (uint256(2) << 192); // sibling-of-role under admin

        for (uint256 i = 0; i < crafted.length; i++) {
            bool isAdmin = roles.isAdminOfHat(bob, crafted[i]);
            if (i == 2) {
                // the ONE case that is genuinely below bob's hat: legitimate authority.
                assertTrue(isAdmin, "bob admins true descendants of its own hat");
            } else {
                assertFalse(isAdmin, "bob must NOT admin non-descendant crafted id");
            }
        }

        // and the mutators enforce it: bob cannot create a sibling under the admin hat.
        uint256 predicted = roles.getNextId(adminHatId);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("NotAdmin(address,uint256)", bob, predicted));
        roles.createHat(adminHatId, "evil", 1, org, org, true, "");

        // bob cannot mint the admin hat to itself.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("NotAdmin(address,uint256)", bob, adminHatId));
        roles.mintHat(adminHatId, bob);

        // bob cannot transfer the admin hat (steal it) even to itself.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("NotAdmin(address,uint256)", bob, adminHatId));
        roles.transferHat(adminHatId, alice, bob);
    }

    /*//////////////////////////////////////////////////////////////
        VECTOR 1 — cross-tree link theft / unilateral grafting
    //////////////////////////////////////////////////////////////*/

    function test_V1_CannotGraftVictimTreeWithoutConsent() public {
        // mallory owns her own tree.
        uint256 topM = roles.mintTopHat(mallory, "topM", "");
        uint32 domainM = roles.getTopHatDomain(topM);
        uint32 domainVictim = roles.getTopHatDomain(topHatId);

        // (a) mallory cannot REQUEST linking the victim's tree (she doesn't admin it).
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSignature("NotAdmin(address,uint256)", mallory, topHatId));
        roles.requestLinkTopHatToTree(domainVictim, topM);

        // (b) mallory requests linking HER tree under the victim's admin hat (allowed: she admins topM)...
        vm.prank(mallory);
        roles.requestLinkTopHatToTree(domainM, adminHatId);
        // ...but she cannot APPROVE it (she doesn't admin the victim's adminHat), so no link forms.
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSignature("NotAdmin(address,uint256)", mallory, adminHatId));
        roles.approveLinkTopHatToTree(domainM, adminHatId, mallory, mallory, "", "");
        assertEq(roles.linkedTreeAdmins(topM), 0, "no link without destination consent");

        // (c) approval requires BOTH destination-admin AND a matching outstanding request.
        //     org DOES admin its own adminHat, but no tree has requested linking under it here,
        //     so approving a fresh org-owned tree under adminHat fails the request-match guard.
        uint256 topX = roles.mintTopHat(org, "topX", "");
        uint32 domainX = roles.getTopHatDomain(topX);
        vm.prank(org);
        vm.expectRevert(abi.encodeWithSignature("LinkageNotRequested()"));
        roles.approveLinkTopHatToTree(domainX, adminHatId, org, org, "", "");

        // victim retains sole admin of its tree throughout.
        assertTrue(roles.isAdminOfHat(org, adminHatId));
        assertFalse(roles.isAdminOfHat(mallory, adminHatId));
        assertFalse(roles.isAdminOfHat(mallory, roleHatId));
    }

    /*//////////////////////////////////////////////////////////////
        VECTOR 3 — malicious module forcing the stored-state fallback
    //////////////////////////////////////////////////////////////*/

    /// @notice Blue fix #2 (>=64 parity with upstream Hats): a module that returns EXTRA bytes
    ///         while signalling revoke (eligible=false) is now HONORED, not ignored via fallback.
    ///         (Updated from the pre-fix `== 64` characterization, which failed open.)
    function test_V3_OverlongModuleReturn_Honored_RevokeApplied() public {
        OverlongEligibility elig = new OverlongEligibility(); // returns (false,true,0xdead) = 96 bytes
        vm.prank(org);
        uint256 hid = roles.createHat(adminHatId, "termed", 1, address(elig), org, true, "");

        // the >=64 path decodes the first 64 bytes and honors the revoke: ineligible.
        assertFalse(roles.isEligible(alice, hid), "overlong revoke honored -> ineligible");

        // minting an ineligible wearer now reverts (revoke is not silently ignored).
        vm.prank(org);
        vm.expectRevert(abi.encodeWithSignature("NotEligible()"));
        roles.mintHat(hid, alice);

        // permissionless enforcement now accepts the >=64 return (no NotHatsEligibility length revert).
        roles.checkHatWearerStatus(hid, alice); // must not revert on the length check
    }

    function test_V3_RevertingModule_FailsOpen() public {
        RevertingEligibility elig = new RevertingEligibility();
        vm.prank(org);
        uint256 hid = roles.createHat(adminHatId, "rev", 1, address(elig), org, true, "");
        vm.prank(org);
        roles.mintHat(hid, alice);
        // reverting module -> fallback -> eligible (fail-open, matches Hats).
        assertTrue(roles.isEligible(alice, hid));
    }

    function test_V3_OverlongToggle_Honored_Deactivates() public {
        OverlongToggle tog = new OverlongToggle(); // returns (false,0xdead) = 64 bytes, intends OFF
        vm.prank(org);
        uint256 hid = roles.createHat(adminHatId, "tog", 1, org, address(tog), true, "");
        // Blue fix #2 (>=32 parity): the overlong toggle return is decoded and OFF is honored.
        assertFalse(roles.isActive(hid), "overlong toggle OFF honored -> inactive");
    }

    /*//////////////////////////////////////////////////////////////
        VECTOR 4 — ERC-6551 account authority / ERC-1271
    //////////////////////////////////////////////////////////////*/

    function _deployAccount(uint256 hatId) internal returns (LuxRolesAccount1ofNV1 acct) {
        bytes32 salt = bytes32(uint256(0xA11CE));
        (bool ok, bytes memory ret) = CANONICAL_REGISTRY.call(
            abi.encodeWithSignature(
                "createAccount(address,bytes32,uint256,address,uint256)",
                address(accountImpl),
                salt,
                block.chainid,
                address(roles),
                hatId
            )
        );
        require(ok, "createAccount");
        acct = LuxRolesAccount1ofNV1(payable(abi.decode(ret, (address))));
    }

    function test_V4_1271_NonWearerAndMalleabilityRejected() public {
        LuxRolesAccount1ofNV1 acct = _deployAccount(roleHatId);

        // a real key that is NOT a wearer.
        uint256 pkStranger = 0xBEEF;
        bytes32 hash = keccak256("authorize sub-wallet action");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pkStranger, hash);
        bytes memory sig = abi.encodePacked(r, s, v);
        assertEq(acct.isValidSignature(hash, sig), bytes4(0), "non-wearer signature rejected");

        // a wearer key: mint the role to that key's address, then it signs.
        uint256 pkWearer = 0xC0FFEE;
        address wearerAddr = vm.addr(pkWearer);
        vm.prank(alice); // alice admins roleHat (wears adminHat)
        roles.mintHat(roleHatId, wearerAddr);
        (v, r, s) = vm.sign(pkWearer, hash);
        sig = abi.encodePacked(r, s, v);
        assertEq(acct.isValidSignature(hash, sig), MAGIC_1271, "wearer signature accepted");

        // malleability: flip s to high-half; OZ tryRecover must reject (no magic).
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 sHigh = bytes32(n - uint256(s));
        uint8 vFlip = v == 27 ? 28 : 27;
        bytes memory malleable = abi.encodePacked(r, sHigh, vFlip);
        assertEq(acct.isValidSignature(hash, malleable), bytes4(0), "malleable high-s rejected");

        // empty signature -> rejected (no accidental address(0) acceptance).
        assertEq(acct.isValidSignature(hash, ""), bytes4(0), "empty sig rejected");

        // now revoke the wearer; its previously-valid signature must stop validating (live check).
        vm.prank(alice);
        roles.transferHat(roleHatId, wearerAddr, mallory); // move hat away from wearerAddr
        (v, r, s) = vm.sign(pkWearer, hash);
        sig = abi.encodePacked(r, s, v);
        assertEq(acct.isValidSignature(hash, sig), bytes4(0), "revoked wearer signature no longer valid");
    }

    function test_V4_Execute_OnlyWearer_And_RevokedLosesControl() public {
        LuxRolesAccount1ofNV1 acct = _deployAccount(roleHatId);
        Sink sink = new Sink();
        vm.deal(address(acct), 10 ether);

        // non-wearer cannot execute.
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSignature("NotAuthorized()"));
        acct.execute(address(sink), 1 ether, "", 0);

        // wearer (bob) can move funds.
        uint256 before = address(sink).balance;
        vm.prank(bob);
        acct.execute(address(sink), 1 ether, "", 0);
        assertEq(address(sink).balance, before + 1 ether, "wearer moved funds");
        assertEq(acct.state(), 1, "state bumped");

        // unsupported operation (CREATE=2) fails closed.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("InvalidOperation()"));
        acct.execute(address(sink), 0, "", 2);

        // revoke bob (move the role); bob can no longer execute, new wearer can.
        vm.prank(alice);
        roles.transferHat(roleHatId, bob, alice); // alice is eligible (org module -> fallback true)
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("NotAuthorized()"));
        acct.execute(address(sink), 1 ether, "", 0);

        vm.prank(alice);
        acct.execute(address(sink), 1 ether, "", 0);
        assertEq(address(sink).balance, before + 2 ether, "new wearer controls funds");
    }

    /*//////////////////////////////////////////////////////////////
        NEW FINDING — lastHatId (uint16) wrap: getNextId collides with the admin id
    //////////////////////////////////////////////////////////////*/

    /// @notice buildHatId(_admin, 0) == _admin. getNextId computes `lastHatId + 1` UNCHECKED, so
    ///         once an admin has 65535 children lastHatId+1 wraps to 0 and getNextId returns the
    ///         admin's OWN id. createHat then overwrites the admin hat's struct instead of
    ///         reverting (upstream Hats reverts MaxHatsInLevelReached). PoC uses vm.store to set
    ///         lastHatId = 0xFFFF (reaching it organically needs 65535 admin-authorized txns).
    /// @dev    INVERTED after Blue's fix: LuxRolesV1.getNextId now reverts MaxHatsInLevelReached
    ///         at the uint16 ceiling, so the child index can never wrap to 0 and alias the admin.
    ///         (Original RED PoC asserted the pre-fix overwrite; this asserts the guard.)
    function test_NEW_LastHatIdWrap_GuardedByMaxHatsInLevelReached() public {
        // pure-arithmetic root cause is unchanged: child index 0 still aliases the parent id...
        assertEq(roles.buildHatId(adminHatId, 0), adminHatId, "buildHatId(_,0) aliases admin");

        // ...so drive lastHatId to the uint16 ceiling and prove the guard fires instead of wrapping.
        // locate _hats[adminHatId] packed slot: base+3 packs toggle|maxSupply|supply|lastHatId|..
        // (toggle=bits0-159, maxSupply=160-191, supply=192-223, lastHatId=224-239).
        bytes32 base = keccak256(abi.encode(adminHatId, uint256(2))); // _hats is storage slot 2
        bytes32 packedSlot = bytes32(uint256(base) + 3);
        uint256 packed = uint256(vm.load(address(roles), packedSlot));
        // self-validate the slot/offset: bits 160..191 == maxSupply (2 from setUp).
        assertEq(uint32(packed >> 160), uint32(2), "layout sanity: maxSupply @bit160 == 2");

        // set lastHatId (bits 224..239) to 0xFFFF, preserving the rest.
        uint256 cleared = packed & ~(uint256(0xFFFF) << 224);
        vm.store(address(roles), packedSlot, bytes32(cleared | (uint256(0xFFFF) << 224)));

        // getNextId now fails closed rather than returning the admin's own id.
        vm.expectRevert(abi.encodeWithSignature("MaxHatsInLevelReached()"));
        roles.getNextId(adminHatId);

        // and createHat fails closed rather than overwriting the admin hat's struct.
        (, uint32 msBefore,, address eligBefore,,,,,) = roles.viewHat(adminHatId);
        assertEq(msBefore, 2);
        vm.prank(org); // org admins adminHat (wears top)
        vm.expectRevert(abi.encodeWithSignature("MaxHatsInLevelReached()"));
        roles.createHat(adminHatId, "OVERWRITTEN", 999, mallory, mallory, true, "");

        // the admin hat's own state is intact — no aliasing corruption.
        (, uint32 msAfter,, address eligAfter,,,,,) = roles.viewHat(adminHatId);
        assertEq(msAfter, msBefore, "admin hat maxSupply unchanged");
        assertEq(eligAfter, eligBefore, "admin hat eligibility unchanged");
    }

    /*//////////////////////////////////////////////////////////////
        VECTOR 5 — soulbound completeness
    //////////////////////////////////////////////////////////////*/

    function test_V5_AllTransferAndApprovePathsRevert() public {
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("Soulbound()"));
        roles.safeTransferFrom(bob, mallory, roleHatId, 1, "");

        uint256[] memory ids = new uint256[](1);
        ids[0] = roleHatId;
        uint256[] memory vals = new uint256[](1);
        vals[0] = 1;
        vm.expectRevert(abi.encodeWithSignature("Soulbound()"));
        roles.safeBatchTransferFrom(bob, mallory, ids, vals, "");

        vm.expectRevert(abi.encodeWithSignature("Soulbound()"));
        roles.setApprovalForAll(mallory, true);
        vm.stopPrank();

        assertFalse(roles.isApprovedForAll(bob, mallory));
    }
}
