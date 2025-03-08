import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  ConcreteBaseQuorumPercentV1,
  ConcreteBaseQuorumPercentV1__factory,
} from '../../../typechain-types';
import { getModuleProxyFactory } from '../../helpers/globals.test';
import { calculateProxyAddress } from '../../helpers/utils';

describe('BaseQuorumPercentV1', () => {
  // Signers
  let deployer: SignerWithAddress;
  let owner: SignerWithAddress;
  let nonOwner: SignerWithAddress;

  // Contracts
  let concreteQuorumPercentMastercopy: ConcreteBaseQuorumPercentV1;
  let concreteQuorumPercent: ConcreteBaseQuorumPercentV1;

  // Constants
  const INITIAL_QUORUM_NUMERATOR = 300000; // 30%
  const QUORUM_DENOMINATOR = 1000000;

  async function deployConcreteQuorumPercent(
    mastercopy: ConcreteBaseQuorumPercentV1,
    quorumOwner: SignerWithAddress,
    quorumNumerator: number,
  ): Promise<ConcreteBaseQuorumPercentV1> {
    const salt = ethers.hexlify(ethers.randomBytes(32));
    const setupCalldata = mastercopy.interface.encodeFunctionData('setUp', [
      ethers.AbiCoder.defaultAbiCoder().encode(
        ['address', 'uint256'],
        [quorumOwner.address, quorumNumerator],
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

    return ConcreteBaseQuorumPercentV1__factory.connect(predictedAddress, quorumOwner);
  }

  beforeEach(async () => {
    [deployer, owner, nonOwner] = await ethers.getSigners();

    // Deploy the concrete quorum mastercopy
    concreteQuorumPercentMastercopy = await new ConcreteBaseQuorumPercentV1__factory(
      deployer,
    ).deploy();

    // Deploy a proxy instance of the concrete quorum percent for testing
    concreteQuorumPercent = await deployConcreteQuorumPercent(
      concreteQuorumPercentMastercopy,
      owner,
      INITIAL_QUORUM_NUMERATOR,
    );
  });

  describe('Initialization', () => {
    it('should initialize with correct owner', async () => {
      expect(await concreteQuorumPercent.owner()).to.equal(owner.address);
    });

    it('should initialize with correct quorumNumerator', async () => {
      expect(await concreteQuorumPercent.quorumNumerator()).to.equal(INITIAL_QUORUM_NUMERATOR);
    });

    it('should not allow reinitialization', async () => {
      const setupCalldata = concreteQuorumPercentMastercopy.interface.encodeFunctionData('setUp', [
        ethers.AbiCoder.defaultAbiCoder().encode(
          ['address', 'uint256'],
          [owner.address, INITIAL_QUORUM_NUMERATOR],
        ),
      ]);

      await expect(concreteQuorumPercent.setUp(setupCalldata)).to.be.reverted;
    });

    it('should have the correct QUORUM_DENOMINATOR', async () => {
      expect(await concreteQuorumPercent.QUORUM_DENOMINATOR()).to.equal(QUORUM_DENOMINATOR);
    });
  });

  describe('updateQuorumNumerator', () => {
    it('should allow owner to update quorumNumerator', async () => {
      const newQuorumNumerator = 500000; // 50%
      await concreteQuorumPercent.connect(owner).updateQuorumNumerator(newQuorumNumerator);
      expect(await concreteQuorumPercent.quorumNumerator()).to.equal(newQuorumNumerator);
    });

    it('should emit QuorumNumeratorUpdated event when quorumNumerator is updated', async () => {
      const newQuorumNumerator = 500000; // 50%
      await expect(concreteQuorumPercent.connect(owner).updateQuorumNumerator(newQuorumNumerator))
        .to.emit(concreteQuorumPercent, 'QuorumNumeratorUpdated')
        .withArgs(newQuorumNumerator);
    });

    it('should not allow non-owner to update quorumNumerator', async () => {
      const newQuorumNumerator = 500000; // 50%
      await expect(
        concreteQuorumPercent.connect(nonOwner).updateQuorumNumerator(newQuorumNumerator),
      ).to.be.revertedWithCustomError(concreteQuorumPercent, 'OwnableUnauthorizedAccount');
    });

    it('should revert when quorumNumerator is greater than QUORUM_DENOMINATOR', async () => {
      const invalidQuorumNumerator = QUORUM_DENOMINATOR + 1;
      await expect(
        concreteQuorumPercent.connect(owner).updateQuorumNumerator(invalidQuorumNumerator),
      ).to.be.revertedWithCustomError(concreteQuorumPercent, 'InvalidQuorumNumerator');
    });

    it('should allow quorumNumerator to be zero', async () => {
      const newQuorumNumerator = 0;
      await concreteQuorumPercent.connect(owner).updateQuorumNumerator(newQuorumNumerator);
      expect(await concreteQuorumPercent.quorumNumerator()).to.equal(newQuorumNumerator);
    });

    it('should allow quorumNumerator to be equal to QUORUM_DENOMINATOR', async () => {
      const newQuorumNumerator = QUORUM_DENOMINATOR;
      await concreteQuorumPercent.connect(owner).updateQuorumNumerator(newQuorumNumerator);
      expect(await concreteQuorumPercent.quorumNumerator()).to.equal(newQuorumNumerator);
    });
  });

  describe('meetsQuorum', () => {
    it('should return true when yes + abstain votes exceed quorum threshold', async () => {
      const totalSupply = 1000;
      const yesVotes = 200;
      const abstainVotes = 100;
      // quorum is 30% of 1000 = 300, yes + abstain = 300
      void expect(await concreteQuorumPercent.meetsQuorum(totalSupply, yesVotes, abstainVotes)).to
        .be.true;
    });

    it('should return true when yes + abstain votes equal quorum threshold', async () => {
      const totalSupply = 1000;
      const yesVotes = 250;
      const abstainVotes = 50;
      // quorum is 30% of 1000 = 300, yes + abstain = 300
      void expect(await concreteQuorumPercent.meetsQuorum(totalSupply, yesVotes, abstainVotes)).to
        .be.true;
    });

    it('should return false when yes + abstain votes are below quorum threshold', async () => {
      const totalSupply = 1000;
      const yesVotes = 200;
      const abstainVotes = 50;
      // quorum is 30% of 1000 = 300, yes + abstain = 250
      void expect(await concreteQuorumPercent.meetsQuorum(totalSupply, yesVotes, abstainVotes)).to
        .be.false;
    });

    it('should handle zero votes correctly', async () => {
      const totalSupply = 1000;
      const yesVotes = 0;
      const abstainVotes = 0;
      void expect(await concreteQuorumPercent.meetsQuorum(totalSupply, yesVotes, abstainVotes)).to
        .be.false;
    });

    it('should handle zero total supply correctly', async () => {
      const totalSupply = 0;
      const yesVotes = 0;
      const abstainVotes = 0;
      // 0% of 0 = 0, 0 >= 0 is true
      void expect(await concreteQuorumPercent.meetsQuorum(totalSupply, yesVotes, abstainVotes)).to
        .be.true;
    });
  });

  describe('quorumVotes', () => {
    it('should return correct quorum votes value', async () => {
      // concrete implementation uses a fixed total supply of 1000000
      const expectedQuorumVotes = (1000000 * INITIAL_QUORUM_NUMERATOR) / QUORUM_DENOMINATOR;
      expect(await concreteQuorumPercent.quorumVotes(1)).to.equal(expectedQuorumVotes);
    });
  });

  describe('Version', () => {
    it('should return correct version', async () => {
      expect(await concreteQuorumPercent.getVersion()).to.equal(1);
    });
  });
});
