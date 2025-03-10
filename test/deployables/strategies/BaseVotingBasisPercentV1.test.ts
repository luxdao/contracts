import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  ConcreteBaseVotingBasisPercentV1,
  ConcreteBaseVotingBasisPercentV1__factory,
} from '../../../typechain-types';
import { getModuleProxyFactory } from '../../helpers/globals.test';
import { calculateProxyAddress } from '../../helpers/utils';

describe('BaseVotingBasisPercentV1', () => {
  // Signers
  let deployer: SignerWithAddress;
  let owner: SignerWithAddress;
  let nonOwner: SignerWithAddress;

  // Contracts
  let concreteVotingBasisMastercopy: ConcreteBaseVotingBasisPercentV1;
  let concreteVotingBasis: ConcreteBaseVotingBasisPercentV1;

  // Constants
  const INITIAL_BASIS_NUMERATOR = 500000; // 50% - simple majority
  const BASIS_DENOMINATOR = 1000000;

  async function deployConcreteVotingBasis(
    mastercopy: ConcreteBaseVotingBasisPercentV1,
    basisOwner: SignerWithAddress,
    basisNumerator: number,
  ): Promise<ConcreteBaseVotingBasisPercentV1> {
    const salt = ethers.hexlify(ethers.randomBytes(32));
    const setupCalldata = mastercopy.interface.encodeFunctionData('setUp', [
      ethers.AbiCoder.defaultAbiCoder().encode(
        ['address', 'uint256'],
        [basisOwner.address, basisNumerator],
      ),
    ]);

    const moduleProxyFactory = getModuleProxyFactory();

    await moduleProxyFactory.deployModule(await mastercopy.getAddress(), setupCalldata, salt);

    const predictedAddress = await calculateProxyAddress(
      moduleProxyFactory,
      await mastercopy.getAddress(),
      setupCalldata,
      salt,
    );

    return ConcreteBaseVotingBasisPercentV1__factory.connect(predictedAddress, basisOwner);
  }

  beforeEach(async () => {
    [deployer, owner, nonOwner] = await ethers.getSigners();

    // Deploy the concrete voting basis mastercopy
    concreteVotingBasisMastercopy = await new ConcreteBaseVotingBasisPercentV1__factory(
      deployer,
    ).deploy();

    // Deploy a proxy instance of the concrete voting basis for testing
    concreteVotingBasis = await deployConcreteVotingBasis(
      concreteVotingBasisMastercopy,
      owner,
      INITIAL_BASIS_NUMERATOR,
    );
  });

  describe('Initialization', () => {
    it('should initialize with correct owner', async () => {
      expect(await concreteVotingBasis.owner()).to.equal(owner.address);
    });

    it('should initialize with correct basisNumerator', async () => {
      expect(await concreteVotingBasis.basisNumerator()).to.equal(INITIAL_BASIS_NUMERATOR);
    });

    it('should not allow reinitialization', async () => {
      const setupCalldata = concreteVotingBasisMastercopy.interface.encodeFunctionData('setUp', [
        ethers.AbiCoder.defaultAbiCoder().encode(
          ['address', 'uint256'],
          [owner.address, INITIAL_BASIS_NUMERATOR],
        ),
      ]);

      await expect(concreteVotingBasis.setUp(setupCalldata)).to.be.reverted;
    });

    it('should have the correct BASIS_DENOMINATOR', async () => {
      expect(await concreteVotingBasis.BASIS_DENOMINATOR()).to.equal(BASIS_DENOMINATOR);
    });
  });

  describe('updateBasisNumerator', () => {
    it('should allow owner to update basisNumerator', async () => {
      const newBasisNumerator = 700000; // 70%
      await concreteVotingBasis.connect(owner).updateBasisNumerator(newBasisNumerator);
      expect(await concreteVotingBasis.basisNumerator()).to.equal(newBasisNumerator);
    });

    it('should emit BasisNumeratorUpdated event when basisNumerator is updated', async () => {
      const newBasisNumerator = 700000; // 70%
      await expect(concreteVotingBasis.connect(owner).updateBasisNumerator(newBasisNumerator))
        .to.emit(concreteVotingBasis, 'BasisNumeratorUpdated')
        .withArgs(newBasisNumerator);
    });

    it('should not allow non-owner to update basisNumerator', async () => {
      const newBasisNumerator = 700000; // 70%
      await expect(
        concreteVotingBasis.connect(nonOwner).updateBasisNumerator(newBasisNumerator),
      ).to.be.revertedWithCustomError(concreteVotingBasis, 'OwnableUnauthorizedAccount');
    });

    it('should revert when basisNumerator is greater than BASIS_DENOMINATOR', async () => {
      const invalidBasisNumerator = BASIS_DENOMINATOR + 1;
      await expect(
        concreteVotingBasis.connect(owner).updateBasisNumerator(invalidBasisNumerator),
      ).to.be.revertedWithCustomError(concreteVotingBasis, 'InvalidBasisNumerator');
    });

    it('should revert when basisNumerator is less than BASIS_DENOMINATOR / 2', async () => {
      const invalidBasisNumerator = BASIS_DENOMINATOR / 2 - 1;
      await expect(
        concreteVotingBasis.connect(owner).updateBasisNumerator(invalidBasisNumerator),
      ).to.be.revertedWithCustomError(concreteVotingBasis, 'InvalidBasisNumerator');
    });

    it('should allow basisNumerator to be equal to BASIS_DENOMINATOR / 2', async () => {
      const newBasisNumerator = BASIS_DENOMINATOR / 2;
      await concreteVotingBasis.connect(owner).updateBasisNumerator(newBasisNumerator);
      expect(await concreteVotingBasis.basisNumerator()).to.equal(newBasisNumerator);
    });

    it('should allow basisNumerator to be equal to BASIS_DENOMINATOR', async () => {
      const newBasisNumerator = BASIS_DENOMINATOR;
      await concreteVotingBasis.connect(owner).updateBasisNumerator(newBasisNumerator);
      expect(await concreteVotingBasis.basisNumerator()).to.equal(newBasisNumerator);
    });
  });

  describe('meetsBasis', () => {
    // Test with default 50% basis
    it('should return true when yes votes exceed the basis threshold', async () => {
      const yesVotes = 60;
      const noVotes = 40;
      // 60 > ((60 + 40) * 500000 / 1000000) = 50, so it passes
      void expect(await concreteVotingBasis.meetsBasis(yesVotes, noVotes)).to.be.true;
    });

    it('should return false when yes votes equal the basis threshold', async () => {
      const yesVotes = 50;
      const noVotes = 50;
      // 50 = ((50 + 50) * 500000 / 1000000) = 50, but we need >
      void expect(await concreteVotingBasis.meetsBasis(yesVotes, noVotes)).to.be.false;
    });

    it('should return false when yes votes are below the basis threshold', async () => {
      const yesVotes = 49;
      const noVotes = 51;
      // 49 < ((49 + 51) * 500000 / 1000000) = 50
      void expect(await concreteVotingBasis.meetsBasis(yesVotes, noVotes)).to.be.false;
    });

    // Test with higher basis (e.g., 70%)
    it('should work with higher basis threshold', async () => {
      // Update to 70%
      await concreteVotingBasis.connect(owner).updateBasisNumerator(700000);

      // Case where it passes with the new threshold
      const yesVotes = 71;
      const noVotes = 29;
      // 71 > ((71 + 29) * 700000 / 1000000) = 70
      void expect(await concreteVotingBasis.meetsBasis(yesVotes, noVotes)).to.be.true;

      // Case where it fails with the new threshold
      const yesVotes2 = 69;
      const noVotes2 = 31;
      // 69 < ((69 + 31) * 700000 / 1000000) = 70
      void expect(await concreteVotingBasis.meetsBasis(yesVotes2, noVotes2)).to.be.false;
    });

    it('should handle zero votes correctly', async () => {
      const yesVotes = 0;
      const noVotes = 0;
      // When both are 0, formula is 0 > (0 * 500000 / 1000000) which is 0 > 0, which is false
      void expect(await concreteVotingBasis.meetsBasis(yesVotes, noVotes)).to.be.false;
    });

    it('should handle case where only yes votes exist', async () => {
      const yesVotes = 100;
      const noVotes = 0;
      // 100 > ((100 + 0) * 500000 / 1000000) = 50
      void expect(await concreteVotingBasis.meetsBasis(yesVotes, noVotes)).to.be.true;
    });

    it('should handle case where only no votes exist', async () => {
      const yesVotes = 0;
      const noVotes = 100;
      // 0 < ((0 + 100) * 500000 / 1000000) = 50
      void expect(await concreteVotingBasis.meetsBasis(yesVotes, noVotes)).to.be.false;
    });
  });

  describe('Version', () => {
    it('should return correct version', async () => {
      expect(await concreteVotingBasis.getVersion()).to.equal(1);
    });
  });
});
