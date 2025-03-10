import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import { ConcreteBaseStrategyV1, ConcreteBaseStrategyV1__factory } from '../../../typechain-types';
import { getModuleProxyFactory } from '../../helpers/globals.test';
import { calculateProxyAddress } from '../../helpers/utils';

describe('BaseStrategyV1', () => {
  // Signers
  let deployer: SignerWithAddress;
  let owner: SignerWithAddress;
  let nonOwner: SignerWithAddress;
  let azoriusAddress: string;
  let azoriusSigner: SignerWithAddress;

  // Contracts
  let concreteStrategyMastercopy: ConcreteBaseStrategyV1;
  let concreteStrategy: ConcreteBaseStrategyV1;

  async function deployConcreteStrategy(
    mastercopy: ConcreteBaseStrategyV1,
    strategyOwner: SignerWithAddress,
    azoriusAddr: string,
  ): Promise<ConcreteBaseStrategyV1> {
    const salt = ethers.hexlify(ethers.randomBytes(32));
    const setupCalldata = mastercopy.interface.encodeFunctionData('setUp', [
      ethers.AbiCoder.defaultAbiCoder().encode(
        ['address', 'address'],
        [strategyOwner.address, azoriusAddr],
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

    return ConcreteBaseStrategyV1__factory.connect(predictedAddress, strategyOwner);
  }

  beforeEach(async () => {
    [deployer, owner, nonOwner, azoriusSigner] = await ethers.getSigners();

    // For the purpose of the test, we'll use the dedicated signer address as the Azorius address
    azoriusAddress = await azoriusSigner.getAddress();

    // Deploy the concrete strategy mastercopy
    concreteStrategyMastercopy = await new ConcreteBaseStrategyV1__factory(deployer).deploy();

    // Deploy a proxy instance of the concrete strategy for testing
    concreteStrategy = await deployConcreteStrategy(
      concreteStrategyMastercopy,
      owner,
      azoriusAddress,
    );
  });

  describe('Initialization', () => {
    it('should initialize with correct owner', async () => {
      expect(await concreteStrategy.owner()).to.equal(owner.address);
    });

    it('should initialize with correct Azorius module', async () => {
      expect(await concreteStrategy.azoriusModule()).to.equal(azoriusAddress);
    });

    it('should not allow reinitialization', async () => {
      const setupCalldata = concreteStrategyMastercopy.interface.encodeFunctionData('setUp', [
        ethers.AbiCoder.defaultAbiCoder().encode(
          ['address', 'address'],
          [owner.address, azoriusAddress],
        ),
      ]);

      await expect(concreteStrategy.setUp(setupCalldata)).to.be.reverted;
    });

    it('should emit StrategySetUp event on initialization', async () => {
      // Need to deploy a new instance to catch the event during initialization
      const newSalt = ethers.keccak256(ethers.toUtf8Bytes('new-concrete-strategy-salt'));
      const setupCalldata = concreteStrategyMastercopy.interface.encodeFunctionData('setUp', [
        ethers.AbiCoder.defaultAbiCoder().encode(
          ['address', 'address'],
          [owner.address, azoriusAddress],
        ),
      ]);

      const moduleProxyFactory = getModuleProxyFactory();

      const deployTx = await moduleProxyFactory.deployModule(
        await concreteStrategyMastercopy.getAddress(),
        setupCalldata,
        newSalt,
      );

      const receipt = await ethers.provider.getTransactionReceipt(deployTx.hash);
      const predictedAddress = await calculateProxyAddress(
        moduleProxyFactory,
        await concreteStrategyMastercopy.getAddress(),
        setupCalldata,
        newSalt,
      );

      const newConcreteStrategy = ConcreteBaseStrategyV1__factory.connect(predictedAddress, owner);

      // Check event logs (need to filter for events from the new contract)
      const events = receipt?.logs
        .filter(log => log.address.toLowerCase() === predictedAddress.toLowerCase())
        .map(log => {
          try {
            return newConcreteStrategy.interface.parseLog({
              topics: [...log.topics],
              data: log.data,
            });
          } catch (e) {
            return null;
          }
        })
        .filter(event => event !== null && event.name === 'StrategySetUp');

      expect(events?.length).to.be.greaterThan(0);
      if (events && events.length > 0 && events[0]) {
        expect(events[0].args.azoriusModule).to.equal(azoriusAddress);
        expect(events[0].args.owner).to.equal(owner.address);
      }
    });
  });

  describe('setAzorius', () => {
    it('should allow owner to update Azorius address', async () => {
      const newAzoriusAddress = await nonOwner.getAddress();
      await concreteStrategy.connect(owner).setAzorius(newAzoriusAddress);
      expect(await concreteStrategy.azoriusModule()).to.equal(newAzoriusAddress);
    });

    it('should emit AzoriusSet event when Azorius address is updated', async () => {
      const newAzoriusAddress = await nonOwner.getAddress();
      await expect(concreteStrategy.connect(owner).setAzorius(newAzoriusAddress))
        .to.emit(concreteStrategy, 'AzoriusSet')
        .withArgs(newAzoriusAddress);
    });

    it('should not allow non-owner to update Azorius address', async () => {
      const newAzoriusAddress = await nonOwner.getAddress();
      await expect(
        concreteStrategy.connect(nonOwner).setAzorius(newAzoriusAddress),
      ).to.be.revertedWithCustomError(concreteStrategy, 'OwnableUnauthorizedAccount');
    });
  });

  describe('onlyAzorius modifier', () => {
    it('should allow calls from Azorius address', async () => {
      // Use the dedicated Azorius signer directly
      // Call a function that uses the onlyAzorius modifier
      await expect(concreteStrategy.connect(azoriusSigner).concreteOnlyAzoriusFunction()).to.not.be
        .reverted;
    });

    it('should revert calls from non-Azorius address', async () => {
      // Call from a regular account should revert
      await expect(
        concreteStrategy.connect(owner).concreteOnlyAzoriusFunction(),
      ).to.be.revertedWithCustomError(concreteStrategy, 'OnlyAzorius');
    });
  });

  describe('Version', () => {
    it('should return correct version', async () => {
      expect(await concreteStrategy.getVersion()).to.equal(1);
    });
  });
});
