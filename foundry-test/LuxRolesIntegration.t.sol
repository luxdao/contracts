// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.31;

import "forge-std/Test.sol";

import { LuxRolesV1 } from "../contracts/roles/LuxRolesV1.sol";
import { LuxRolesAccount1ofNV1 } from "../contracts/roles/LuxRolesAccount1ofNV1.sol";
import { ERC6551Registry } from "../contracts/roles/ERC6551Registry.sol";

import { UtilityRolesManagementV1 } from "../contracts/utilities/UtilityRolesManagementV1.sol";
import { IUtilityRolesManagementV1 } from "../contracts/interfaces/dao/utilities/IUtilityRolesManagementV1.sol";
import { ISystemDeployerV1 } from "../contracts/interfaces/dao/singletons/ISystemDeployerV1.sol";
import { SystemDeployerV1 } from "../contracts/singletons/SystemDeployerV1.sol";
import { KeyValuePairsV1 } from "../contracts/singletons/KeyValuePairsV1.sol";
import { AutonomousAdminV1 } from "../contracts/deployables/autonomous-admin/AutonomousAdminV1.sol";

/// @dev Minimal Safe stand-in: executes the roles utility via delegatecall exactly as a Safe
///      module transaction would (so `address(this)` inside the utility is this Safe). It has no
///      `getWearerStatus`/`getHatStatus`, so when used as an eligibility/toggle the protocol
///      correctly falls back to stored state — matching a real Safe used as an EOA-style module.
contract MockSafe {
    function delegateExec(address to, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = to.delegatecall(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }
}

/// @dev Registry surface incl. the address-prediction view.
interface IReg {
    function createAccount(address, bytes32, uint256, address, uint256) external returns (address);
    function account(address, bytes32, uint256, address, uint256) external view returns (address);
}

/**
 * @title LuxRolesIntegration
 * @notice Fork-proof of the Lux DAO app's UNCHANGED role-creation flow against the native
 *         `LuxRolesV1` protocol: drives `UtilityRolesManagementV1.createAndDeclareTree` via a
 *         delegatecalling Safe, then asserts the full tree (top / admin / role hats) and the
 *         role's ERC-6551 token-bound sub-wallet exist and resolve.
 *
 * @dev Simulates Lux mainnet chainId 96369 and installs the canonical ERC-6551 registry at its
 *      cross-chain singleton address (0x0000…5758), so the flow exercises exactly the addresses
 *      the app hard-codes. Runs deterministically without an RPC; also passes under
 *      `--fork-url <96369-rpc>` (where it will use the already-deployed canonical registry).
 */
contract LuxRolesIntegration is Test {
    address internal constant CANONICAL_REGISTRY = 0x000000006551c19487814612e58FE06813775758;
    bytes4 internal constant MAGIC_SIGNER = 0x523e3260; // IERC6551Account.isValidSigner

    LuxRolesV1 internal roles;
    LuxRolesAccount1ofNV1 internal accountImpl;
    SystemDeployerV1 internal sysDeployer;
    KeyValuePairsV1 internal kvp;
    AutonomousAdminV1 internal autoAdminImpl;
    UtilityRolesManagementV1 internal utility;
    MockSafe internal safe;

    address internal alice = makeAddr("alice"); // the role wearer
    address internal bob = makeAddr("bob"); // a non-wearer

    function setUp() public {
        // simulate Lux mainnet.
        vm.chainId(96369);

        roles = new LuxRolesV1();
        accountImpl = new LuxRolesAccount1ofNV1();
        sysDeployer = new SystemDeployerV1();
        kvp = new KeyValuePairsV1();
        autoAdminImpl = new AutonomousAdminV1();
        utility = new UtilityRolesManagementV1();
        safe = new MockSafe();

        // install the canonical ERC-6551 registry at its singleton address (if not already there).
        if (CANONICAL_REGISTRY.code.length == 0) {
            ERC6551Registry impl = new ERC6551Registry();
            vm.etch(CANONICAL_REGISTRY, address(impl).code);
        }
    }

    function test_CreateAndDeclareTree_YieldsRoleAndSubWallet() public {
        IUtilityRolesManagementV1.HatParams[] memory hats = new IUtilityRolesManagementV1.HatParams[](1);
        hats[0] = IUtilityRolesManagementV1.HatParams({
            wearer: alice,
            details: "ipfs://role",
            imageURI: "",
            sablierStreamsParams: new IUtilityRolesManagementV1.SablierStreamParams[](0), // no streams
            termEndDateTs: 0, // untermed -> no elections module, gets an ERC-6551 sub-wallet
            maxSupply: 1,
            isMutable: true
        });

        IUtilityRolesManagementV1.CreateTreeParams memory params = IUtilityRolesManagementV1.CreateTreeParams({
            keyValuePairs: address(kvp),
            hatsProtocol: address(roles),
            erc6551Registry: CANONICAL_REGISTRY,
            hatsModuleFactory: address(0), // unused for untermed roles
            systemDeployer: address(sysDeployer),
            daoAutonomousAdminImplementation: address(autoAdminImpl),
            hatsAccountImplementation: address(accountImpl),
            hatsElectionsEligibilityImplementation: address(0), // unused for untermed roles
            topHat: IUtilityRolesManagementV1.TopHatParams({ details: "ipfs://top", imageURI: "ipfs://img" }),
            adminHat: IUtilityRolesManagementV1.AdminHatParams({
                details: "ipfs://admin", imageURI: "", isMutable: true
            }),
            hats: hats
        });

        // ---- run the app's UNCHANGED module entrypoint via a delegatecalling Safe ----
        safe.delegateExec(address(utility), abi.encodeCall(IUtilityRolesManagementV1.createAndDeclareTree, (params)));

        // ---- tree assertions ----
        assertEq(roles.lastTopHatId(), 1, "one tree created");
        uint256 topHatId = uint256(roles.lastTopHatId()) << 224;
        uint256 adminHatId = roles.buildHatId(topHatId, 1);
        uint256 roleHatId = roles.buildHatId(adminHatId, 1);

        // top hat -> the Safe
        assertTrue(roles.isWearerOfHat(address(safe), topHatId), "safe wears top hat");

        // admin hat -> the autonomous admin proxy (deployed via SystemDeployer)
        bytes32 salt = bytes32(uint256(uint160(address(safe))));
        address autoAdmin = ISystemDeployerV1(address(sysDeployer))
            .predictProxyAddress(address(autoAdminImpl), abi.encodeWithSignature("initialize()"), salt, address(safe));
        assertGt(autoAdmin.code.length, 0, "autonomous admin deployed");
        assertTrue(roles.isWearerOfHat(autoAdmin, adminHatId), "autonomous admin wears admin hat");

        // role hat -> alice
        assertTrue(roles.isWearerOfHat(alice, roleHatId), "alice wears the role");
        assertEq(roles.hatSupply(roleHatId), 1);

        // ---- ERC-6551 sub-wallet for the role ----
        address subWallet =
            IReg(CANONICAL_REGISTRY).account(address(accountImpl), salt, block.chainid, address(roles), roleHatId);
        assertGt(subWallet.code.length, 0, "role sub-wallet deployed");

        // the sub-wallet is bound to (96369, rolesProtocol, roleHatId)
        (uint256 cid, address tokenContract, uint256 tokenId) = LuxRolesAccount1ofNV1(payable(subWallet)).token();
        assertEq(cid, 96369, "chainId");
        assertEq(tokenContract, address(roles), "tokenContract == rolesProtocol");
        assertEq(tokenId, roleHatId, "tokenId == roleHatId");

        // authority tracks hat membership: the wearer is a valid 1-of-N signer, others are not.
        assertEq(LuxRolesAccount1ofNV1(payable(subWallet)).isValidSigner(alice, ""), MAGIC_SIGNER, "wearer signs");
        assertEq(LuxRolesAccount1ofNV1(payable(subWallet)).isValidSigner(bob, ""), bytes4(0), "non-wearer cannot");

        // the top hat + admin hat also received their bound accounts.
        address topWallet =
            IReg(CANONICAL_REGISTRY).account(address(accountImpl), salt, block.chainid, address(roles), topHatId);
        assertGt(topWallet.code.length, 0, "top hat sub-wallet deployed");
    }

    /// @notice The deployed sub-wallet MUST be the canonical ERC-6551 v0.3.1 minimal proxy, so
    ///         its CREATE2 address equals what the real singleton registry produces on any chain.
    ///         Verifies the ERC-1167 header/footer, the embedded implementation, and the
    ///         (salt, chainId, tokenContract, tokenId) footer tuple.
    function test_SubWallet_IsCanonicalERC6551Proxy() public {
        uint256 topHatId = roles.mintTopHat(address(this), "top", "");
        uint256 adminHatId = roles.createHat(topHatId, "admin", 1, address(this), address(this), true, "");
        uint256 roleHatId = roles.createHat(adminHatId, "role", 1, address(this), address(this), true, "");
        roles.mintHat(roleHatId, alice);

        bytes32 salt = bytes32(uint256(uint160(address(this))));
        address subWallet = IReg(CANONICAL_REGISTRY)
            .createAccount(address(accountImpl), salt, block.chainid, address(roles), roleHatId);

        bytes memory code = subWallet.code;
        assertEq(code.length, 0xad, "canonical ERC-6551 proxy runtime is 173 bytes");

        // ERC-1167 runtime header (10 bytes)
        assertEq(_slice(code, 0, 10), hex"363d3d373d3d3d363d73", "ERC-1167 header");
        // embedded implementation (20 bytes)
        assertEq(address(bytes20(_slice(code, 10, 20))), address(accountImpl), "embedded impl");
        // ERC-1167 footer (15 bytes)
        assertEq(_slice(code, 30, 15), hex"5af43d82803e903d91602b57fd5bf3", "ERC-1167 footer");
        // footer tuple: salt, chainId, tokenContract, tokenId (4 * 32 bytes at offset 45)
        (bytes32 fSalt, uint256 fChain, address fToken, uint256 fId) =
            abi.decode(_slice(code, 45, 128), (bytes32, uint256, address, uint256));
        assertEq(fSalt, salt, "footer salt");
        assertEq(fChain, block.chainid, "footer chainId");
        assertEq(fToken, address(roles), "footer tokenContract");
        assertEq(fId, roleHatId, "footer tokenId");

        // and the prediction view resolves to the same deployed address (idempotent registry).
        assertEq(
            IReg(CANONICAL_REGISTRY).account(address(accountImpl), salt, block.chainid, address(roles), roleHatId),
            subWallet,
            "account() prediction == createAccount() address"
        );
    }

    /// @notice Mirrors the real 96369 STAGE deploy: the canonical singleton is ABSENT on Lux
    ///         mainnet, so a registry is deployed at a FRESH address and wired via config. Proves
    ///         the native protocol + account compose correctly against a non-canonical registry.
    function test_FreshRegistry_Composes() public {
        ERC6551Registry freshRegistry = new ERC6551Registry();

        uint256 topHatId = roles.mintTopHat(address(this), "top", "");
        uint256 adminHatId = roles.createHat(topHatId, "admin", 1, address(this), address(this), true, "");
        uint256 roleHatId = roles.createHat(adminHatId, "role", 1, address(this), address(this), true, "");
        roles.mintHat(roleHatId, alice);

        bytes32 salt = bytes32(uint256(uint160(address(this))));
        address subWallet = IReg(address(freshRegistry))
            .createAccount(address(accountImpl), salt, block.chainid, address(roles), roleHatId);

        assertGt(subWallet.code.length, 0, "sub-wallet deployed via fresh registry");
        (uint256 cid, address tokenContract, uint256 tokenId) = LuxRolesAccount1ofNV1(payable(subWallet)).token();
        assertEq(cid, block.chainid);
        assertEq(tokenContract, address(roles));
        assertEq(tokenId, roleHatId);
        assertEq(LuxRolesAccount1ofNV1(payable(subWallet)).isValidSigner(alice, ""), MAGIC_SIGNER);
        assertEq(LuxRolesAccount1ofNV1(payable(subWallet)).isValidSigner(bob, ""), bytes4(0));

        // prediction view matches the deployed address (idempotent, config-consistent).
        assertEq(
            IReg(address(freshRegistry)).account(address(accountImpl), salt, block.chainid, address(roles), roleHatId),
            subWallet
        );
    }

    function _slice(bytes memory data, uint256 start, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i = 0; i < len;) {
            out[i] = data[start + i];
            unchecked {
                ++i;
            }
        }
    }

    /// @notice After creation, control of the sub-wallet follows the hat: revoke the wearer and
    ///         the account's signer authority disappears; grant a new wearer and it appears.
    function test_SubWallet_AuthorityFollowsHat() public {
        // build a minimal tree directly (same protocol calls the module makes) to isolate the
        // account authority behaviour.
        uint256 topHatId = roles.mintTopHat(address(this), "top", "");
        uint256 adminHatId = roles.createHat(topHatId, "admin", 1, address(this), address(this), true, "");
        uint256 roleHatId = roles.createHat(adminHatId, "role", 1, address(this), address(this), true, "");
        roles.mintHat(roleHatId, alice);

        bytes32 salt = bytes32(uint256(uint160(address(this))));
        address subWallet = IReg(CANONICAL_REGISTRY)
            .createAccount(address(accountImpl), salt, block.chainid, address(roles), roleHatId);

        assertEq(LuxRolesAccount1ofNV1(payable(subWallet)).isValidSigner(alice, ""), MAGIC_SIGNER);

        // move the role from alice to bob; authority must follow.
        roles.transferHat(roleHatId, alice, bob);
        assertEq(LuxRolesAccount1ofNV1(payable(subWallet)).isValidSigner(alice, ""), bytes4(0), "old wearer out");
        assertEq(LuxRolesAccount1ofNV1(payable(subWallet)).isValidSigner(bob, ""), MAGIC_SIGNER, "new wearer in");
    }
}
