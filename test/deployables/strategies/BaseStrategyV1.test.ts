import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  BaseStrategyV1__factory,
  ConcreteBaseStrategyV1,
  ConcreteBaseStrategyV1__factory,
  IBaseStrategyV1__factory,
  IERC165__factory,
  ProxyFactory__factory,
} from '../../../typechain-types';
import { calculateInterfaceId } from '../../helpers/utils';
import { runUUPSUpgradeabilityTests } from '../../helpers/uupsUpgradeabilityTests';

describe('BaseStrategyV1', () => {
  // Signers
  let deployer: SignerWithAddress;
  let owner: SignerWithAddress;
  let nonOwner: SignerWithAddress;
  let proposalInitializer: string;
  let azoriusSigner: SignerWithAddress;

  // Contracts
  let concreteStrategyImplementation: ConcreteBaseStrategyV1;
  let concreteStrategy: ConcreteBaseStrategyV1;

  async function deployConcreteStrategy(
    implementation: ConcreteBaseStrategyV1,
    strategyOwner: SignerWithAddress,
    azoriusAddr: string,
  ): Promise<ConcreteBaseStrategyV1> {
    // Create a unique salt
    const salt = ethers.keccak256(ethers.randomBytes(32));

    // Combine selector and encoded params
    const fullInitData =
      ConcreteBaseStrategyV1__factory.createInterface().getFunction('initialize').selector +
      ethers.AbiCoder.defaultAbiCoder()
        .encode(['address', 'address'], [strategyOwner.address, azoriusAddr])
        .slice(2);

    // Deploy the factory
    const factory = await new ProxyFactory__factory(deployer).deploy();

    // Deploy the proxy
    await factory.deployProxy(await implementation.getAddress(), fullInitData, salt);

    // Predict the address
    const predictedAddress = await factory.predictProxyAddress(
      await implementation.getAddress(),
      fullInitData,
      salt,
      deployer.address,
    );

    // Create a contract instance at the predicted address
    return ConcreteBaseStrategyV1__factory.connect(predictedAddress, strategyOwner);
  }

  beforeEach(async () => {
    [deployer, owner, nonOwner, azoriusSigner] = await ethers.getSigners();

    // For the purpose of the test, we'll use the dedicated signer address as the Azorius address
    proposalInitializer = await azoriusSigner.getAddress();

    // Deploy the concrete strategy implementation
    concreteStrategyImplementation = await new ConcreteBaseStrategyV1__factory(deployer).deploy();

    // Deploy a proxy instance of the concrete strategy for testing
    concreteStrategy = await deployConcreteStrategy(
      concreteStrategyImplementation,
      owner,
      proposalInitializer,
    );
  });

  describe('Initialization', () => {
    it('should initialize with correct owner', async () => {
      expect(await concreteStrategy.owner()).to.equal(owner.address);
    });

    it('should initialize with correct proposal initializer', async () => {
      expect(await concreteStrategy.proposalInitializer()).to.equal(proposalInitializer);
    });

    it('should not allow reinitialization', async () => {
      await expect(concreteStrategy.initialize(owner.address, proposalInitializer)).to.be.reverted;
    });

    it('should emit StrategySetUp event on initialization', async () => {
      // Create a unique salt
      const salt = ethers.keccak256(ethers.randomBytes(32));

      // Combine selector and encoded params
      const fullInitData =
        ConcreteBaseStrategyV1__factory.createInterface().getFunction('initialize').selector +
        ethers.AbiCoder.defaultAbiCoder()
          .encode(['address', 'address'], [owner.address, proposalInitializer])
          .slice(2);

      // Deploy the factory
      const factory = await new ProxyFactory__factory(deployer).deploy();

      // Deploy the proxy and get the transaction
      const tx = await factory.deployProxy(
        await concreteStrategyImplementation.getAddress(),
        fullInitData,
        salt,
      );
      const receipt = await tx.wait();

      // Check for the event in the transaction logs
      // The event might be in any of the logs, so we need to look through all of them
      const eventSignature = BaseStrategyV1__factory.createInterface().getEvent('StrategySetUp');
      const strategySetUpLogs = receipt?.logs.filter(
        log => log.topics[0] === eventSignature.topicHash,
      );

      expect(strategySetUpLogs?.length).to.be.greaterThan(0);

      if (strategySetUpLogs && strategySetUpLogs.length > 0) {
        // Parse the log data
        const eventInterface = BaseStrategyV1__factory.createInterface();
        const parsedLog = eventInterface.parseLog({
          topics: strategySetUpLogs[0].topics,
          data: strategySetUpLogs[0].data,
        });

        // Check event parameters
        expect(parsedLog?.args[0].toLowerCase()).to.equal(proposalInitializer.toLowerCase());
        expect(parsedLog?.args[1].toLowerCase()).to.equal(owner.address.toLowerCase());
      }
    });
  });

  describe('onlyAzorius modifier', () => {
    it('should allow calls from Azorius address', async () => {
      // Call from the Azorius address should succeed
      await expect(
        concreteStrategy.connect(azoriusSigner).concreteOnlyProposalInitializerFunction(),
      ).not.to.be.reverted;
    });

    it('should revert calls from non-Azorius address', async () => {
      // Call from a regular account should revert
      await expect(
        concreteStrategy.connect(owner).concreteOnlyProposalInitializerFunction(),
      ).to.be.revertedWithCustomError(concreteStrategy, 'ProposalInitializerUnauthorizedAccount');
    });
  });

  describe('ERC165', function () {
    let iBaseStrategyV1InterfaceId: string;
    let iERC165InterfaceId: string;

    beforeEach(async function () {
      // Dynamically calculate interface IDs
      const IBaseStrategyV1Interface = IBaseStrategyV1__factory.createInterface();
      iBaseStrategyV1InterfaceId = calculateInterfaceId(IBaseStrategyV1Interface);

      const IERC165Interface = IERC165__factory.createInterface();
      iERC165InterfaceId = calculateInterfaceId(IERC165Interface);
    });

    it('Should support IERC165 interface', async function () {
      const supported = await concreteStrategy.supportsInterface(iERC165InterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should support IBaseStrategyV1 interface', async function () {
      const supported = await concreteStrategy.supportsInterface(iBaseStrategyV1InterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should not support random interface', async function () {
      const randomInterfaceId = '0x12345678';
      const supported = await concreteStrategy.supportsInterface(randomInterfaceId);
      void expect(supported).to.be.false;
    });
  });

  describe('UUPS Upgradeability', function () {
    runUUPSUpgradeabilityTests({
      getContract: () => concreteStrategy,
      createNewImplementation: async () => {
        const newImplementation = await new ConcreteBaseStrategyV1__factory(owner).deploy();
        return newImplementation;
      },
      owner: () => owner,
      nonOwner: () => nonOwner,
    });
  });
});
