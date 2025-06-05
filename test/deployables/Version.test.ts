import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import { ConcreteVersion, ConcreteVersion__factory } from '../../typechain-types';

describe('Version', () => {
  // Signers
  let deployer: SignerWithAddress;

  // Contracts
  let concreteVersion: ConcreteVersion;

  beforeEach(async () => {
    [deployer] = await ethers.getSigners();

    // Deploy the concrete version implementation
    concreteVersion = await new ConcreteVersion__factory(deployer).deploy();
  });

  describe('Version Identification', () => {
    it('should return version value that matches what was set', async () => {
      const version = 123;

      await concreteVersion.setVersion(version);

      expect(await concreteVersion.version()).to.equal(version);
    });

    it('should update version when setter is called', async () => {
      const oldVersion = 1;
      const newVersion = 2;

      await concreteVersion.setVersion(oldVersion);
      expect(await concreteVersion.version()).to.equal(oldVersion);

      await concreteVersion.setVersion(newVersion);
      expect(await concreteVersion.version()).to.equal(newVersion);
    });
  });
});
