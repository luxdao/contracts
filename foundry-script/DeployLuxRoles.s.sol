// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.31;

import { Script, console } from "forge-std/Script.sol";
import { LuxRolesV1 } from "../contracts/roles/LuxRolesV1.sol";
import { LuxRolesAccount1ofNV1 } from "../contracts/roles/LuxRolesAccount1ofNV1.sol";
import { ERC6551Registry } from "../contracts/roles/ERC6551Registry.sol";

/**
 * @title DeployLuxRoles
 * @notice Deploys the luxfi-native, IHats-compatible roles protocol and its ERC-6551 sub-wallet
 *         master copy — the drop-in for the Lux DAO app's `rolesProtocol` +
 *         `rolesAccount1ofNMasterCopy`. STAGE only (chain-gated; refuses mainnet 96369 unless
 *         ALLOW_MAINNET=1 is explicitly set).
 *
 * Deploys:
 *   1. LuxRolesV1              -> rolesProtocol
 *   2. LuxRolesAccount1ofNV1   -> rolesAccount1ofNMasterCopy
 *   3. ERC6551Registry         -> ONLY if the canonical singleton 0x0000…5758 is absent on-chain;
 *                                 otherwise the canonical registry is used as-is.
 *
 * Env:
 *   LUX_PRIVATE_KEY  (required)  deployer key
 *   ALLOW_MAINNET    (optional)  set to "1" to permit chainId 96369 (guard off)
 *
 * Usage (dry-run / plan):
 *   forge script contracts/script/DeployLuxRoles.s.sol:DeployLuxRoles --rpc-url <rpc>
 * Usage (broadcast):
 *   forge script contracts/script/DeployLuxRoles.s.sol:DeployLuxRoles --rpc-url <rpc> --broadcast
 */
contract DeployLuxRoles is Script {
    address internal constant CANONICAL_REGISTRY = 0x000000006551c19487814612e58FE06813775758;

    function run() external {
        // STAGE guard: refuse mainnet unless explicitly allowed.
        if (block.chainid == 96369 && !_allowMainnet()) {
            revert("REFUSE: chainId 96369 is mainnet; STAGE only. Set ALLOW_MAINNET=1 to override.");
        }

        uint256 pk = vm.envUint("LUX_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        console.log("chainId  :", block.chainid);
        console.log("deployer :", deployer);

        vm.startBroadcast(pk);

        LuxRolesV1 roles = new LuxRolesV1();
        LuxRolesAccount1ofNV1 accountImpl = new LuxRolesAccount1ofNV1();

        address registry = CANONICAL_REGISTRY;
        bool deployedRegistry;
        if (CANONICAL_REGISTRY.code.length == 0) {
            // canonical singleton not present on this chain -> deploy a compatible registry.
            registry = address(new ERC6551Registry());
            deployedRegistry = true;
        }

        vm.stopBroadcast();

        console.log("--------------------------------------------------------------");
        console.log("rolesProtocol            (LuxRolesV1)          :", address(roles));
        console.log("rolesAccount1ofNMasterCopy(LuxRolesAccount1ofN):", address(accountImpl));
        console.log("erc6551Registry                                :", registry);
        console.log(
            deployedRegistry ? "  (freshly deployed; not canonical singleton)" : "  (canonical singleton, on-chain)"
        );
        console.log("--------------------------------------------------------------");
        console.log("Frontend env for the lux.vote / zoo.vote / pars.vote rebuild:");
        console.log("  VITE_APP_LUX_ROLES_PROTOCOL=%s", _toHex(address(roles)));
        console.log("  VITE_APP_LUX_ROLES_ACCOUNT_1OFN=%s", _toHex(address(accountImpl)));
        if (deployedRegistry) {
            console.log("  VITE_APP_LUX_ERC6551_REGISTRY=%s", _toHex(registry));
        }
        console.log("--------------------------------------------------------------");
    }

    function _allowMainnet() internal view returns (bool) {
        try vm.envString("ALLOW_MAINNET") returns (string memory v) {
            return keccak256(bytes(v)) == keccak256(bytes("1"));
        } catch {
            return false;
        }
    }

    function _toHex(address a) internal pure returns (string memory) {
        return vm.toString(a);
    }
}
