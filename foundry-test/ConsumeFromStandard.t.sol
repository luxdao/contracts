// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "forge-std/Test.sol";

// All DAO + Safe contracts are consumed FROM lux/standard via remappings.
// Single source of truth — no local copies of these contracts in luxfi/dao.
import { ModuleGovernorV1 } from "@luxfi/standard/dao/deployables/modules/ModuleGovernorV1.sol";
import { ModuleFractalV1 } from "@luxfi/standard/dao/deployables/modules/ModuleFractalV1.sol";
import { SystemDeployerV1 } from "@luxfi/standard/dao/singletons/SystemDeployerV1.sol";

import { SafeFactory } from "@luxfi/standard/safe/SafeFactory.sol";
import { SafeMLDSASigner } from "@luxfi/standard/safe/SafeMLDSASigner.sol";
import { SafeCoronaSigner } from "@luxfi/standard/safe/SafeCoronaSigner.sol";
import { SafePulsarSigner } from "@luxfi/standard/safe/SafePulsarSigner.sol";
import { SafeMagnetarSigner } from "@luxfi/standard/safe/SafeMagnetarSigner.sol";

/// @title ConsumeFromStandardTest
/// @notice Verifies luxfi-dao can deploy DAO + Safe + Quasar signer contracts
///         entirely via luxfi-standard imports. No local duplication.
contract ConsumeFromStandardTest is Test {
    function testDAOModulesDeployFromStandard() public {
        ModuleGovernorV1 governor = new ModuleGovernorV1();
        ModuleFractalV1 fractal = new ModuleFractalV1();
        SystemDeployerV1 deployer = new SystemDeployerV1();

        assertTrue(address(governor) != address(0));
        assertTrue(address(fractal) != address(0));
        assertTrue(address(deployer) != address(0));
    }

    function testSafeFactoryDeploysFromStandard() public {
        SafeFactory factory = new SafeFactory();
        assertEq(factory.factoryVersion(), "1.0.0");
    }

    function testQuasarSignerSetDeploysFromStandard() public {
        // Corona — R-LWE threshold
        bytes memory coronaPk = new bytes(1500);
        for (uint256 i = 0; i < 1500; i++) coronaPk[i] = bytes1(uint8((i * 7 + 1) & 0xFF));
        SafeCoronaSigner corona = new SafeCoronaSigner(3, 5, coronaPk);
        assertEq(corona.threshold(), 3);

        // Pulsar — M-LWE threshold ML-DSA
        bytes memory pulsarPk = new bytes(1952);
        for (uint256 i = 0; i < 1952; i++) pulsarPk[i] = bytes1(uint8((i * 11 + 3) & 0xFF));
        SafePulsarSigner pulsar = new SafePulsarSigner(3, 5, pulsarPk);
        assertEq(pulsar.totalParties(), 5);

        // Magnetar — SLH-DSA THBS-SE (optional, disabled by default in tests)
        bytes memory magnetarPk = new bytes(32);
        for (uint256 i = 0; i < 32; i++) magnetarPk[i] = bytes1(uint8((i * 13 + 5) & 0xFF));
        SafeMagnetarSigner magnetar = new SafeMagnetarSigner(false, 3, 5, magnetarPk);
        assertFalse(magnetar.enabled());

        // ML-DSA single signer
        SafeMLDSASigner mldsa = new SafeMLDSASigner(pulsarPk);
        assertTrue(mldsa.signer() != address(0));
    }
}
