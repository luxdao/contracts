// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.31;
import "forge-std/Test.sol";
import { LuxRolesV1 } from "../contracts/roles/LuxRolesV1.sol";

contract ProbeSlot is Test {
    LuxRolesV1 roles;

    function test_probe() public {
        roles = new LuxRolesV1();
        address org = makeAddr("org");
        uint256 top = roles.mintTopHat(org, "top", "");
        vm.prank(org);
        uint256 admin = roles.createHat(top, "admin", 2, org, org, true, "");
        vm.prank(org);
        roles.mintHat(admin, makeAddr("alice"));
        bytes32 base = keccak256(abi.encode(admin, uint256(2)));
        for (uint256 i = 0; i < 7; i++) {
            uint256 v = uint256(vm.load(address(roles), bytes32(uint256(base) + i)));
            emit log_named_uint(string(abi.encodePacked("offset ", vm.toString(i))), v);
        }
    }
}
