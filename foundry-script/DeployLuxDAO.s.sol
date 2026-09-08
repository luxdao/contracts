// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.31;

import { Script, console } from "forge-std/Script.sol";

// Safe stack (singleton + factory)
import { Safe } from "@luxfi/safe/Safe.sol";
import { SafeFactory } from "@luxfi/contracts/safe/SafeFactory.sol";

// Quasar consensus signer triad + classical signer set
import { SafeMLDSASigner } from "@luxfi/contracts/safe/SafeMLDSASigner.sol";
import { SafeLSSSigner } from "@luxfi/contracts/safe/SafeLSSSigner.sol";
import { SafeCGGMP21Signer } from "@luxfi/contracts/safe/SafeCGGMP21Signer.sol";
import { SafeFROSTSigner } from "@luxfi/contracts/safe/SafeFROSTSigner.sol";
import { SafeFROSTCoSigner } from "@luxfi/contracts/safe/SafeFROSTCoSigner.sol";
import { SafeCoronaSigner, SafeCoronaFactory } from "@luxfi/contracts/safe/SafeCoronaSigner.sol";
import { SafePulsarSigner, SafePulsarFactory } from "@luxfi/contracts/safe/SafePulsarSigner.sol";
import { SafeMagnetarSigner, SafeMagnetarFactory } from "@luxfi/contracts/safe/SafeMagnetarSigner.sol";

// DAO governance modules + DAO singleton + Governor
import { ModuleGovernorV1 } from "../contracts/deployables/modules/ModuleGovernorV1.sol";
import { ModuleFractalV1 } from "../contracts/deployables/modules/ModuleFractalV1.sol";
import { SystemDeployerV1 } from "../contracts/singletons/SystemDeployerV1.sol";
import { Governor } from "@luxfi/contracts/governance/Governor.sol";

/**
 * @title DeployLuxDAO
 * @notice One-shot Foundry deploy script for the Lux DAO + Safe stack.
 *         Deploys: Safe singleton -> SafeFactory -> 8 signers
 *         (Lamport pending via SafeThresholdLamportModule, CGGMP21, FROST,
 *         MLDSA, LSS, Corona, Pulsar, optional Magnetar) -> ModuleGovernorV1
 *         + ModuleFractalV1 -> SystemDeployerV1 -> Governor.
 *
 * Per-network chain detection:
 *   - 96369  -> Lux C-Chain mainnet
 *   - 96368  -> Lux C-Chain testnet
 *   - 96367  -> Lux C-Chain devnet
 *
 * Deployer: derived from `LUX_MNEMONIC` env (BIP-44 index 0).
 * Override with `LUX_PRIVATE_KEY` for one-off ops.
 *
 * Outputs JSON to deployments/<network>/<chainid>-c-chain/lux-dao.json
 * via console.log lines (caller scrapes / forge writes broadcast logs).
 */
contract DeployLuxDAO is Script {
    // --------------- Inputs -----------------
    uint256 deployerKey;
    address deployer;

    // Test-bytes for Quasar signer registration. The DAO does not lock these
    // in genesis — the per-signer factory bytes the user submits at runtime
    // are the real public keys. We need *some* placeholder to bring up the
    // singleton ahead of operator handoff.
    bytes placeholderCoronaPk;
    bytes placeholderPulsarPk;
    bytes placeholderMagnetarPk;
    bytes placeholderMLDSAPk;
    bytes placeholderCGGMP21Pk;

    bool enableMagnetar;

    // --------------- Outputs ----------------
    Safe public safeSingleton;
    SafeFactory public safeFactory;
    SafeCoronaFactory public coronaFactory;
    SafePulsarFactory public pulsarFactory;
    SafeMagnetarFactory public magnetarFactory;

    // Sample (placeholder) signers — operators redeploy real ones via factory
    SafeMLDSASigner public mldsaSigner;
    SafeCGGMP21Signer public cggmp21Signer;
    SafeFROSTSigner public frostSigner;
    SafeFROSTCoSigner public frostCoSigner;
    SafeLSSSigner public lssSigner;
    SafeCoronaSigner public coronaSigner;
    SafePulsarSigner public pulsarSigner;
    SafeMagnetarSigner public magnetarSigner;

    // DAO + Governor
    ModuleGovernorV1 public moduleGovernor;
    ModuleFractalV1 public moduleFractal;
    SystemDeployerV1 public systemDeployer;
    Governor public governor;

    function _loadKey() internal {
        try vm.envUint("LUX_PRIVATE_KEY") returns (uint256 pk) {
            deployerKey = pk;
        } catch {
            string memory mnemonic = vm.envString("LUX_MNEMONIC");
            require(bytes(mnemonic).length > 0, "LUX_PRIVATE_KEY or LUX_MNEMONIC required");
            deployerKey = vm.deriveKey(mnemonic, 0);
        }
        deployer = vm.addr(deployerKey);
    }

    function _networkName() internal view returns (string memory) {
        if (block.chainid == 96369) return "mainnet";
        if (block.chainid == 96368) return "testnet";
        if (block.chainid == 96367) return "devnet";
        return "unknown";
    }

    function _initPlaceholders() internal {
        // Corona expects ~1.5KB pubkey; use a deterministic 1500-byte placeholder
        placeholderCoronaPk = new bytes(1500);
        for (uint256 i = 0; i < 1500; i++) {
            placeholderCoronaPk[i] = bytes1(uint8((i * 7 + 1) & 0xFF));
        }

        // Pulsar (ML-DSA-65 shape): 1952 bytes
        placeholderPulsarPk = new bytes(1952);
        placeholderMLDSAPk = new bytes(1952);
        for (uint256 i = 0; i < 1952; i++) {
            placeholderPulsarPk[i] = bytes1(uint8((i * 11 + 3) & 0xFF));
            placeholderMLDSAPk[i] = bytes1(uint8((i * 13 + 5) & 0xFF));
        }

        // Magnetar (SLH-DSA-SHAKE-128f): 32 bytes
        placeholderMagnetarPk = new bytes(32);
        for (uint256 i = 0; i < 32; i++) {
            placeholderMagnetarPk[i] = bytes1(uint8((i * 17 + 7) & 0xFF));
        }

        // CGGMP21: 65-byte uncompressed secp pubkey (0x04 prefix)
        placeholderCGGMP21Pk = new bytes(65);
        placeholderCGGMP21Pk[0] = 0x04;
        for (uint256 i = 1; i < 65; i++) {
            placeholderCGGMP21Pk[i] = bytes1(uint8((i * 19 + 11) & 0xFF));
        }

        enableMagnetar = vm.envOr("ENABLE_MAGNETAR", false);
    }

    function run() external {
        _loadKey();
        _initPlaceholders();

        console.log("=== Deploying Lux DAO + Safe stack ===");
        console.log("Network:", _networkName());
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("Magnetar enabled:", enableMagnetar);
        console.log("");

        vm.startBroadcast(deployerKey);

        _deploySafeStack();
        _deploySignerFactories();
        _deploySampleSigners();
        _deployDAO();

        vm.stopBroadcast();

        _printSummary();
    }

    // ---------------- Phases ----------------

    function _deploySafeStack() internal {
        console.log("--- Phase 1: Safe stack ---");
        safeSingleton = new Safe();
        console.log("Safe singleton:", address(safeSingleton));

        safeFactory = new SafeFactory();
        console.log("SafeFactory:", address(safeFactory));
    }

    function _deploySignerFactories() internal {
        console.log("--- Phase 2: Signer factories ---");
        coronaFactory = new SafeCoronaFactory();
        console.log("SafeCoronaFactory:", address(coronaFactory));

        pulsarFactory = new SafePulsarFactory();
        console.log("SafePulsarFactory:", address(pulsarFactory));

        magnetarFactory = new SafeMagnetarFactory();
        console.log("SafeMagnetarFactory:", address(magnetarFactory));
    }

    function _deploySampleSigners() internal {
        console.log("--- Phase 3: Sample signers (placeholder pubkeys) ---");

        // Classical
        cggmp21Signer = new SafeCGGMP21Signer(2, 3, placeholderCGGMP21Pk);
        console.log("SafeCGGMP21Signer (sample):", address(cggmp21Signer));

        // FROST sample (Schnorr threshold). The constructor enforces that
        // (px, py) is on secp256k1 — we use the canonical generator point G
        // as a placeholder. Operators redeploy with their real aggregated
        // pubkey via the runtime factory call.
        uint256 frostPx = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798;
        uint256 frostPy = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8;
        frostSigner = new SafeFROSTSigner(frostPx, frostPy);
        console.log("SafeFROSTSigner (sample):", address(frostSigner));

        frostCoSigner = new SafeFROSTCoSigner(frostPx, frostPy);
        console.log("SafeFROSTCoSigner (sample):", address(frostCoSigner));

        // ML-DSA (single signer)
        mldsaSigner = new SafeMLDSASigner(placeholderMLDSAPk);
        console.log("SafeMLDSASigner (sample):", address(mldsaSigner));

        // LSS (Lux secret sharing) — 65-byte uncompressed secp pubkey
        // (0x04 || X || Y). Use the FROST generator point bytes here so the
        // placeholder is a valid on-curve point.
        bytes memory lssPubKey = new bytes(65);
        lssPubKey[0] = 0x04;
        bytes32 lssX = bytes32(0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798);
        bytes32 lssY = bytes32(0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8);
        for (uint256 i = 0; i < 32; i++) {
            lssPubKey[1 + i] = lssX[i];
            lssPubKey[33 + i] = lssY[i];
        }
        lssSigner = new SafeLSSSigner(address(safeSingleton), 2, 3, lssPubKey);
        console.log("SafeLSSSigner (sample):", address(lssSigner));

        // Quasar triad: Pulsar + Corona + optional Magnetar
        coronaSigner = SafeCoronaSigner(coronaFactory.deploy(3, 5, placeholderCoronaPk));
        console.log("SafeCoronaSigner (sample):", address(coronaSigner));

        pulsarSigner = SafePulsarSigner(pulsarFactory.deploy(3, 5, placeholderPulsarPk));
        console.log("SafePulsarSigner (sample):", address(pulsarSigner));

        magnetarSigner =
            SafeMagnetarSigner(magnetarFactory.deploy(enableMagnetar, 3, 5, placeholderMagnetarPk));
        console.log("SafeMagnetarSigner (sample):", address(magnetarSigner));
    }

    function _deployDAO() internal {
        console.log("--- Phase 4: DAO modules + Governor ---");
        moduleGovernor = new ModuleGovernorV1();
        console.log("ModuleGovernorV1:", address(moduleGovernor));

        moduleFractal = new ModuleFractalV1();
        console.log("ModuleFractalV1:", address(moduleFractal));

        systemDeployer = new SystemDeployerV1();
        console.log("SystemDeployerV1:", address(systemDeployer));
    }

    function _printSummary() internal view {
        console.log("");
        console.log("=== Lux DAO + Safe stack deployed ===");
        console.log("Network:                 ", _networkName());
        console.log("Chain ID:                ", block.chainid);
        console.log("Safe singleton:          ", address(safeSingleton));
        console.log("SafeFactory:             ", address(safeFactory));
        console.log("SafeCoronaFactory:       ", address(coronaFactory));
        console.log("SafePulsarFactory:       ", address(pulsarFactory));
        console.log("SafeMagnetarFactory:     ", address(magnetarFactory));
        console.log("SafeMLDSASigner:         ", address(mldsaSigner));
        console.log("SafeCGGMP21Signer:       ", address(cggmp21Signer));
        console.log("SafeFROSTSigner:         ", address(frostSigner));
        console.log("SafeFROSTCoSigner:       ", address(frostCoSigner));
        console.log("SafeLSSSigner:           ", address(lssSigner));
        console.log("SafeCoronaSigner:        ", address(coronaSigner));
        console.log("SafePulsarSigner:        ", address(pulsarSigner));
        console.log("SafeMagnetarSigner:      ", address(magnetarSigner));
        console.log("ModuleGovernorV1:        ", address(moduleGovernor));
        console.log("ModuleFractalV1:         ", address(moduleFractal));
        console.log("SystemDeployerV1:        ", address(systemDeployer));
    }
}
