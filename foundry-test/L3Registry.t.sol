// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {L3Registry} from "../contracts/deployables/thinking/L3Registry.sol";

/// @notice The Zoo L2 hub directory of model-zoo L3s: permissionless registration,
/// one record per chain, DAO-gated endorsement, enumeration.
contract L3RegistryTest is Test {
    L3Registry reg;
    address constant DAO = address(0xDA0);
    address constant COMMUNITY = address(0xC0);
    address constant GOV = address(0x6011);
    address constant OBS = address(0x0B5);

    function setUp() public {
        reg = new L3Registry(DAO);
    }

    function test_RegisterAndRead() public {
        vm.prank(COMMUNITY);
        bytes32 id = reg.register("Beluga", 808080, GOV, OBS, "ipfs://beluga");
        assertEq(id, reg.idOf(808080));
        L3Registry.L3 memory l = reg.get(id);
        assertEq(l.name, "Beluga");
        assertEq(l.chainId, 808080);
        assertEq(l.governor, GOV);
        assertEq(l.registrar, COMMUNITY);
        assertEq(l.endorsed, false);
        assertEq(reg.count(), 1);
        assertEq(reg.at(0), id);
        assertEq(reg.getByChainId(808080).name, "Beluga");
    }

    function test_OnePerChain() public {
        reg.register("Beluga", 808080, GOV, OBS, "");
        vm.expectRevert(abi.encodeWithSelector(L3Registry.AlreadyRegistered.selector, uint256(808080)));
        reg.register("Beluga2", 808080, GOV, OBS, "");
    }

    function test_EndorseGatedToDAO() public {
        bytes32 id = reg.register("Beluga", 808080, GOV, OBS, "");
        vm.expectRevert(L3Registry.NotZooDAO.selector);
        reg.endorse(id, true); // not the DAO
        vm.prank(DAO);
        reg.endorse(id, true);
        assertTrue(reg.get(id).endorsed);
        vm.prank(DAO);
        reg.endorse(id, false);
        assertFalse(reg.get(id).endorsed);
    }

    function test_ZeroChainIdReverts() public {
        vm.expectRevert(L3Registry.ZeroChainId.selector);
        reg.register("x", 0, GOV, OBS, "");
    }

    function test_TransferZooDAO() public {
        vm.prank(DAO);
        reg.transferZooDAO(address(0xBEEF));
        assertEq(reg.zooDAO(), address(0xBEEF));
        vm.prank(address(0xBEEF));
        bytes32 id = reg.register("Z", 1, GOV, OBS, "");
        vm.prank(address(0xBEEF));
        reg.endorse(id, true);
        assertTrue(reg.get(id).endorsed);
    }
}
