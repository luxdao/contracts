// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.31;

import "forge-std/Test.sol";
import { LuxRolesV1 } from "../contracts/roles/LuxRolesV1.sol";

/// @dev Configurable eligibility module: getWearerStatus(address,uint256) -> (eligible, standing).
contract MockEligibility {
    bool public eligible = true;
    bool public standing = true;

    function set(bool _e, bool _s) external {
        eligible = _e;
        standing = _s;
    }

    function getWearerStatus(address, uint256) external view returns (bool, bool) {
        return (eligible, standing);
    }
}

/// @dev Configurable toggle module: getHatStatus(uint256) -> active.
contract MockToggle {
    bool public active = true;

    function set(bool _a) external {
        active = _a;
    }

    function getHatStatus(uint256) external view returns (bool) {
        return active;
    }
}

contract LuxRolesTest is Test {
    LuxRolesV1 internal roles;

    address internal org = makeAddr("org"); // top hat wearer / tree root admin
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal mallory = makeAddr("mallory");

    uint256 internal topHatId;

    function setUp() public {
        roles = new LuxRolesV1();
        // permissionless: anyone may mint a top hat to a target; org becomes the tree root.
        topHatId = roles.mintTopHat(org, "ipfs://top", "ipfs://img");
    }

    /*//////////////////////////////////////////////////////////////
                              ID ARITHMETIC
    //////////////////////////////////////////////////////////////*/

    function test_TopHat_Layout() public view {
        assertEq(topHatId, uint256(1) << 224, "topHatId == domain<<224");
        assertEq(roles.lastTopHatId(), 1);
        assertEq(roles.getTopHatDomain(topHatId), 1);
        assertTrue(roles.isTopHat(topHatId));
        assertTrue(roles.isLocalTopHat(topHatId));
        assertEq(roles.getLocalHatLevel(topHatId), 0);
        assertEq(roles.getHatLevel(topHatId), 0);
        assertTrue(roles.isValidHatId(topHatId));
        assertTrue(roles.isWearerOfHat(org, topHatId));
        assertEq(roles.balanceOf(org, topHatId), 1);
    }

    function test_BuildHatId_And_Levels() public view {
        uint256 child = roles.buildHatId(topHatId, 1);
        assertEq(child, topHatId | (uint256(1) << 208), "level-1 slot");
        assertEq(roles.getLocalHatLevel(child), 1);
        assertEq(roles.getAdminAtLevel(child, 0), topHatId, "admin@0 == top");
        assertEq(roles.getAdminAtLocalLevel(child, 1), child);
        assertTrue(roles.isValidHatId(child));

        uint256 grand = roles.buildHatId(child, 1);
        assertEq(roles.getLocalHatLevel(grand), 2);
        assertEq(roles.getAdminAtLevel(grand, 0), topHatId);
        assertEq(roles.getAdminAtLevel(grand, 1), child);
    }

    function test_InvalidHatId_Gap() public view {
        // domain + a level-2 slot but empty level-1 slot => structurally invalid.
        uint256 gap = topHatId | (uint256(7) << 192);
        assertFalse(roles.isValidHatId(gap));
    }

    /*//////////////////////////////////////////////////////////////
                          CREATE AUTHORIZATION
    //////////////////////////////////////////////////////////////*/

    function _createAdminHat() internal returns (uint256 adminHatId) {
        vm.prank(org);
        adminHatId = roles.createHat(topHatId, "admin", 1, org, org, true, "");
    }

    function test_CreateHat_ByAdmin() public {
        uint256 adminHatId = _createAdminHat();
        assertEq(roles.getNextId(topHatId), roles.buildHatId(topHatId, 2), "lastHatId incremented");
        assertEq(roles.getAdminAtLevel(adminHatId, 0), topHatId);
        (, uint32 maxSupply,,,,,, bool mutable_,) = roles.viewHat(adminHatId);
        assertEq(maxSupply, 1);
        assertTrue(mutable_);
    }

    function test_CreateHat_NonAdmin_Reverts() public {
        // mallory wears nothing; cannot create under the top hat.
        uint256 predicted = roles.getNextId(topHatId);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSignature("NotAdmin(address,uint256)", mallory, predicted));
        roles.createHat(topHatId, "x", 1, org, org, true, "");
    }

    function test_CreateHat_ZeroModules_Revert() public {
        vm.startPrank(org);
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        roles.createHat(topHatId, "x", 1, address(0), org, true, "");
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        roles.createHat(topHatId, "x", 1, org, address(0), true, "");
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                MINTING
    //////////////////////////////////////////////////////////////*/

    function test_MintHat_Wears_And_ReturnsBool() public {
        uint256 adminHatId = _createAdminHat();
        vm.prank(org);
        uint256 roleId = roles.createHat(adminHatId, "role", 1, org, org, true, "");
        vm.prank(org);
        bool ok = roles.mintHat(roleId, alice);
        assertTrue(ok, "mintHat returns true");
        assertTrue(roles.isWearerOfHat(alice, roleId));
        assertEq(roles.hatSupply(roleId), 1);
    }

    function test_MintHat_MaxSupply() public {
        uint256 adminHatId = _createAdminHat();
        vm.prank(org);
        uint256 roleId = roles.createHat(adminHatId, "role", 1, org, org, true, "");
        vm.prank(org);
        roles.mintHat(roleId, alice);
        vm.prank(org);
        vm.expectRevert(abi.encodeWithSignature("AllHatsWorn(uint256)", roleId));
        roles.mintHat(roleId, bob);
    }

    function test_MintHat_AlreadyWearing() public {
        uint256 adminHatId = _createAdminHat();
        vm.prank(org);
        uint256 roleId = roles.createHat(adminHatId, "role", 2, org, org, true, "");
        vm.prank(org);
        roles.mintHat(roleId, alice);
        vm.prank(org);
        vm.expectRevert(abi.encodeWithSignature("AlreadyWearingHat(address,uint256)", alice, roleId));
        roles.mintHat(roleId, alice);
    }

    function test_MintHat_NonAdmin_Reverts() public {
        uint256 adminHatId = _createAdminHat();
        vm.prank(org);
        uint256 roleId = roles.createHat(adminHatId, "role", 1, org, org, true, "");
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSignature("NotAdmin(address,uint256)", mallory, roleId));
        roles.mintHat(roleId, mallory);
    }

    /*//////////////////////////////////////////////////////////////
                       PRIVILEGE ESCALATION GUARDS
    //////////////////////////////////////////////////////////////*/

    /// @notice A wearer of a leaf role must NOT be admin of a sibling, the admin hat, or the top hat,
    ///         and must be unable to create/mint anywhere it does not wear an ancestor.
    function test_NoEscalation_LeafWearer() public {
        // admin hat with room for 2 wearers, so the escalation attempt reaches the admin check
        // rather than short-circuiting on max supply.
        vm.prank(org);
        uint256 adminHatId = roles.createHat(topHatId, "admin", 2, org, org, true, "");
        // admin hat worn by alice (a manager)
        vm.prank(org);
        roles.mintHat(adminHatId, alice);

        // alice (admin-hat wearer) creates a role and mints it to bob
        vm.prank(alice);
        uint256 roleId = roles.createHat(adminHatId, "role", 1, org, org, true, "");
        vm.prank(alice);
        roles.mintHat(roleId, bob);

        // bob wears only the leaf role.
        assertTrue(roles.isWearerOfHat(bob, roleId));
        // bob is NOT admin of the admin hat, the top hat, or itself's parent.
        assertFalse(roles.isAdminOfHat(bob, adminHatId), "leaf !admin of adminHat");
        assertFalse(roles.isAdminOfHat(bob, topHatId), "leaf !admin of topHat");

        // bob cannot create a sibling under the admin hat.
        uint256 predicted = roles.getNextId(adminHatId);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("NotAdmin(address,uint256)", bob, predicted));
        roles.createHat(adminHatId, "evil", 1, org, org, true, "");

        // bob cannot mint himself the admin hat.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("NotAdmin(address,uint256)", bob, adminHatId));
        roles.mintHat(adminHatId, bob);

        // but the admin-hat wearer (alice) IS admin of the leaf; the top hat wearer (org) is admin of all.
        assertTrue(roles.isAdminOfHat(alice, roleId));
        assertTrue(roles.isAdminOfHat(org, roleId));
        assertTrue(roles.isAdminOfHat(org, adminHatId));
    }

    /*//////////////////////////////////////////////////////////////
                       ELIGIBILITY / TOGGLE GATING
    //////////////////////////////////////////////////////////////*/

    function test_EligibilityModule_GatesWearing() public {
        MockEligibility elig = new MockEligibility();
        uint256 adminHatId = _createAdminHat();
        vm.prank(org);
        uint256 roleId = roles.createHat(adminHatId, "role", 1, address(elig), org, true, "");
        vm.prank(org);
        roles.mintHat(roleId, alice);
        assertTrue(roles.isWearerOfHat(alice, roleId));

        // module reports ineligible -> dynamic balance drops to 0 without any burn tx.
        elig.set(false, true);
        assertEq(roles.balanceOf(alice, roleId), 0, "ineligible => balance 0");
        assertFalse(roles.isWearerOfHat(alice, roleId));

        // bad standing likewise removes eligibility.
        elig.set(true, false);
        assertFalse(roles.isEligible(alice, roleId));
        assertFalse(roles.isInGoodStanding(alice, roleId));

        elig.set(true, true);
        assertTrue(roles.isWearerOfHat(alice, roleId));
    }

    function test_MintHat_IneligibleReverts() public {
        MockEligibility elig = new MockEligibility();
        elig.set(false, true);
        uint256 adminHatId = _createAdminHat();
        vm.prank(org);
        uint256 roleId = roles.createHat(adminHatId, "role", 1, address(elig), org, true, "");
        vm.prank(org);
        vm.expectRevert(abi.encodeWithSignature("NotEligible()"));
        roles.mintHat(roleId, alice);
    }

    function test_ToggleModule_GatesActive() public {
        MockToggle toggle = new MockToggle();
        uint256 adminHatId = _createAdminHat();
        vm.prank(org);
        uint256 roleId = roles.createHat(adminHatId, "role", 1, org, address(toggle), true, "");
        vm.prank(org);
        roles.mintHat(roleId, alice);
        assertTrue(roles.isActive(roleId));
        assertTrue(roles.isWearerOfHat(alice, roleId));

        toggle.set(false);
        assertFalse(roles.isActive(roleId), "toggle off => inactive");
        assertEq(roles.balanceOf(alice, roleId), 0, "inactive => balance 0");
    }

    function test_SetHatStatus_OnlyToggle() public {
        uint256 adminHatId = _createAdminHat();
        // toggle is an EOA (org) -> stored status governs; only org (the toggle) may flip it.
        vm.prank(org);
        uint256 roleId = roles.createHat(adminHatId, "role", 1, org, org, true, "");

        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSignature("NotHatsToggle()"));
        roles.setHatStatus(roleId, false);

        vm.prank(org);
        roles.setHatStatus(roleId, false);
        assertFalse(roles.isActive(roleId));
    }

    function test_CheckHatWearerStatus_BurnsIneligible() public {
        MockEligibility elig = new MockEligibility();
        uint256 adminHatId = _createAdminHat();
        vm.prank(org);
        uint256 roleId = roles.createHat(adminHatId, "role", 1, address(elig), org, true, "");
        vm.prank(org);
        roles.mintHat(roleId, alice);
        assertEq(roles.hatSupply(roleId), 1);

        elig.set(false, true);
        roles.checkHatWearerStatus(roleId, alice);
        assertEq(roles.hatSupply(roleId), 0, "revoked => supply decremented");
        assertFalse(roles.isWearerOfHat(alice, roleId));
    }

    function test_CheckHatWearerStatus_NoModuleReverts() public {
        uint256 adminHatId = _createAdminHat();
        // eligibility is an EOA (org) with no getWearerStatus -> cannot drive a status refresh.
        vm.prank(org);
        uint256 roleId = roles.createHat(adminHatId, "role", 1, org, org, true, "");
        vm.expectRevert(abi.encodeWithSignature("NotHatsEligibility()"));
        roles.checkHatWearerStatus(roleId, alice);
    }

    /*//////////////////////////////////////////////////////////////
                         TRANSFER / RENOUNCE
    //////////////////////////////////////////////////////////////*/

    function test_TransferRole_EqualsTransferHat_AdminGated() public {
        uint256 adminHatId = _createAdminHat();
        vm.prank(org);
        uint256 roleId = roles.createHat(adminHatId, "role", 1, org, org, true, "");
        vm.prank(org);
        roles.mintHat(roleId, alice);

        // non-admin cannot transfer.
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSignature("NotAdmin(address,uint256)", mallory, roleId));
        roles.transferRole(roleId, alice, bob);

        // admin moves the role via the app's `transferRole` alias.
        vm.prank(org);
        roles.transferRole(roleId, alice, bob);
        assertFalse(roles.isWearerOfHat(alice, roleId));
        assertTrue(roles.isWearerOfHat(bob, roleId));

        // and back via the canonical `transferHat` (identical semantics).
        vm.prank(org);
        roles.transferHat(roleId, bob, alice);
        assertTrue(roles.isWearerOfHat(alice, roleId));
    }

    function test_TransferHat_ImmutableReverts() public {
        uint256 adminHatId = _createAdminHat();
        vm.prank(org);
        uint256 roleId = roles.createHat(
            adminHatId,
            "role",
            1,
            org,
            org,
            false,
            /*immutable*/
            ""
        );
        vm.prank(org);
        roles.mintHat(roleId, alice);
        vm.prank(org);
        vm.expectRevert(abi.encodeWithSignature("Immutable()"));
        roles.transferHat(roleId, alice, bob);
    }

    function test_RenounceHat() public {
        uint256 adminHatId = _createAdminHat();
        vm.prank(org);
        uint256 roleId = roles.createHat(adminHatId, "role", 1, org, org, true, "");
        vm.prank(org);
        roles.mintHat(roleId, alice);
        vm.prank(alice);
        roles.renounceHat(roleId);
        assertFalse(roles.isWearerOfHat(alice, roleId));
        assertEq(roles.hatSupply(roleId), 0);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN MUTATORS
    //////////////////////////////////////////////////////////////*/

    function test_MakeImmutable_Then_MutateReverts() public {
        uint256 adminHatId = _createAdminHat();
        vm.prank(org);
        uint256 roleId = roles.createHat(adminHatId, "role", 1, org, org, true, "");
        vm.prank(org);
        roles.makeHatImmutable(roleId);
        vm.prank(org);
        vm.expectRevert(abi.encodeWithSignature("Immutable()"));
        roles.changeHatMaxSupply(roleId, 5);
    }

    function test_ChangeMaxSupply_TooLow() public {
        uint256 adminHatId = _createAdminHat();
        vm.prank(org);
        uint256 roleId = roles.createHat(adminHatId, "role", 2, org, org, true, "");
        vm.prank(org);
        roles.mintHat(roleId, alice);
        vm.prank(org);
        roles.mintHat(roleId, bob);
        vm.prank(org);
        vm.expectRevert(abi.encodeWithSignature("NewMaxSupplyTooLow()"));
        roles.changeHatMaxSupply(roleId, 1);
    }

    function test_ChangeEligibility_ByAdmin() public {
        MockEligibility elig = new MockEligibility();
        uint256 adminHatId = _createAdminHat();
        vm.prank(org);
        uint256 roleId = roles.createHat(adminHatId, "role", 1, org, org, true, "");
        vm.prank(org);
        roles.changeHatEligibility(roleId, address(elig));
        assertEq(roles.getHatEligibilityModule(roleId), address(elig));
        // non-admin cannot.
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSignature("NotAdmin(address,uint256)", mallory, roleId));
        roles.changeHatEligibility(roleId, org);
    }

    /*//////////////////////////////////////////////////////////////
                              SOULBOUND
    //////////////////////////////////////////////////////////////*/

    function test_Soulbound_TransfersRevert() public {
        vm.prank(org);
        vm.expectRevert(abi.encodeWithSignature("Soulbound()"));
        roles.safeTransferFrom(org, alice, topHatId, 1, "");

        vm.prank(org);
        vm.expectRevert(abi.encodeWithSignature("Soulbound()"));
        roles.setApprovalForAll(alice, true);

        assertFalse(roles.isApprovedForAll(org, alice));
    }

    function test_SupportsInterface() public view {
        assertTrue(roles.supportsInterface(0xd9b67a26), "ERC1155");
        assertTrue(roles.supportsInterface(0x0e89341c), "ERC1155 metadata");
        assertTrue(roles.supportsInterface(0x01ffc9a7), "ERC165");
    }

    /*//////////////////////////////////////////////////////////////
                              TOP HAT XFER
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                          TREE LINKING (CONSENT)
    //////////////////////////////////////////////////////////////*/

    function test_Link_RequiresMutualConsent_NoEscalation() public {
        // two independent trees.
        uint256 topA = topHatId; // worn by org
        address orgB = makeAddr("orgB");
        uint256 topB = roles.mintTopHat(orgB, "topB", "");
        uint32 domainA = roles.getTopHatDomain(topA);

        // a stranger cannot request linking someone else's tree.
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSignature("NotAdmin(address,uint256)", mallory, topA));
        roles.requestLinkTopHatToTree(domainA, topB);

        // approving without an outstanding request fails, even by the destination admin.
        vm.prank(orgB);
        vm.expectRevert(abi.encodeWithSignature("LinkageNotRequested()"));
        roles.approveLinkTopHatToTree(domainA, topB, orgB, orgB, "", "");

        // the offering side (org, wearer of topA) requests the link.
        vm.prank(org);
        roles.requestLinkTopHatToTree(domainA, topB);

        // a non-admin of the destination cannot approve.
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSignature("NotAdmin(address,uint256)", mallory, topB));
        roles.approveLinkTopHatToTree(domainA, topB, orgB, orgB, "", "");

        // the destination admin (orgB) accepts.
        vm.prank(orgB);
        roles.approveLinkTopHatToTree(domainA, topB, orgB, orgB, "", "");

        // now orgB (destination admin) governs the grafted tree...
        assertEq(roles.linkedTreeAdmins(topA), topB);
        assertTrue(roles.isAdminOfHat(orgB, topA), "orgB admin of linked tree");
        assertEq(roles.getHatLevel(topA), 1, "linked tophat sits one level below topB");
        // ...and orgA no longer unilaterally admins the tree it voluntarily subordinated.
        assertFalse(roles.isAdminOfHat(org, topA), "org subordinated by its own consent");

        // unlink restores standalone status (orgA still wears topA).
        vm.prank(orgB);
        roles.unlinkTopHatFromTree(domainA, org);
        assertEq(roles.linkedTreeAdmins(topA), 0);
        assertTrue(roles.isTopHat(topA));
        assertTrue(roles.isAdminOfHat(org, topA), "org regains admin after unlink");
    }

    function test_Link_NoCircular() public {
        // topA worn by org; topB worn by org.
        uint256 topA = topHatId;
        uint256 topB = roles.mintTopHat(org, "topB", "");
        uint32 domainA = roles.getTopHatDomain(topA);
        uint32 domainB = roles.getTopHatDomain(topB);

        // link A under B (org admins both).
        vm.prank(org);
        roles.requestLinkTopHatToTree(domainA, topB);
        vm.prank(org);
        roles.approveLinkTopHatToTree(domainA, topB, org, org, "", "");

        // now attempt to link B under A -> would create a cycle -> reverts.
        vm.prank(org);
        roles.requestLinkTopHatToTree(domainB, topA);
        vm.prank(org);
        vm.expectRevert(abi.encodeWithSignature("CircularLinkage()"));
        roles.approveLinkTopHatToTree(domainB, topA, org, org, "", "");
    }

    function test_TopHat_Transferable_ByWearerOnly() public {
        // top hats are immutable yet transferable; only the top hat wearer is its admin.
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSignature("NotAdmin(address,uint256)", mallory, topHatId));
        roles.transferHat(topHatId, org, alice);

        vm.prank(org);
        roles.transferHat(topHatId, org, alice);
        assertTrue(roles.isWearerOfHat(alice, topHatId));
        assertFalse(roles.isWearerOfHat(org, topHatId));
    }
}
