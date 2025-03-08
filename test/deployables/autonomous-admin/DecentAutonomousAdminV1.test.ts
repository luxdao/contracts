import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  DecentAutonomousAdminV1,
  DecentAutonomousAdminV1__factory,
  IDecentAutonomousAdminV1__factory,
  IVersion__factory,
} from '../../../typechain-types';

describe('DecentAutonomousAdminV1', function () {
  // Signer accounts
  let deployer: SignerWithAddress;

  // Contract instance
  let decentAutonomousAdminInstance: DecentAutonomousAdminV1;

  beforeEach(async function () {
    // Get signers
    [deployer] = await ethers.getSigners();

    // Deploy DecentAutonomousAdminV1 contract
    decentAutonomousAdminInstance = await new DecentAutonomousAdminV1__factory(deployer).deploy();
  });

  describe('supportsInterface', function () {
    it('should support IDecentAutonomousAdminV1 interface', async function () {
      // Get the interface ID from the factory
      const decentAdminInterfaceId =
        IDecentAutonomousAdminV1__factory.createInterface().getFunction(
          'triggerStartNextTerm',
        ).selector;

      // Check if the contract supports this interface
      const supports =
        await decentAutonomousAdminInstance.supportsInterface(decentAdminInterfaceId);
      void expect(supports).to.be.true;
    });

    it('should support IVersion interface', async function () {
      // Get the interface ID from the factory
      const versionInterfaceId =
        IVersion__factory.createInterface().getFunction('getVersion').selector;

      // Check if the contract supports this interface
      const supports = await decentAutonomousAdminInstance.supportsInterface(versionInterfaceId);
      void expect(supports).to.be.true;
    });

    it('should support ERC165 interface', async function () {
      // ERC165 interface id is well-known
      const erc165InterfaceId = '0x01ffc9a7';

      const supports = await decentAutonomousAdminInstance.supportsInterface(erc165InterfaceId);
      void expect(supports).to.be.true;
    });

    it('should not support random interface', async function () {
      // Random interface id
      const randomInterfaceId = '0x12345678';

      const supports = await decentAutonomousAdminInstance.supportsInterface(randomInterfaceId);
      void expect(supports).to.be.false;
    });
  });

  describe('getVersion', function () {
    it('should return version 1', async function () {
      const version = await decentAutonomousAdminInstance.getVersion();
      void expect(version).to.equal(1);
    });
  });
});
