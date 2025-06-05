import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { loadFixture } from '@nomicfoundation/hardhat-network-helpers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  ConcreteBaseVotingAdapterV1,
  ConcreteBaseVotingAdapterV1__factory,
  ERC1967Proxy__factory,
  MockVotingStrategy,
  MockVotingStrategy__factory,
} from '../../../../typechain-types';

describe('BaseVotingAdapterV1', () => {
  let deployer: SignerWithAddress;
  let eoaStrategySigner: SignerWithAddress; // An EOA that will be designated as the strategy for some tests
  let nonStrategySigner: SignerWithAddress;
  let concreteAdapterImplementationAddress: string;
  let mockStrategyContract: MockVotingStrategy; // Actual MockVotingStrategy contract instance

  async function deployImplementationFixture() {
    const [d, s, ns] = await ethers.getSigners();
    const factory = new ConcreteBaseVotingAdapterV1__factory(d);
    const impl = await factory.deploy();
    await impl.waitForDeployment();
    return {
      implAddress: await impl.getAddress(),
      deployer: d,
      eoaStrategySigner: s,
      nonStrategySigner: ns,
    };
  }

  async function deployMockStrategyFixture() {
    const [d] = await ethers.getSigners(); // Deployer for the mock strategy
    const strategyFactory = new MockVotingStrategy__factory(d);
    // The proposer for MockVotingStrategy doesn't matter for these tests
    const strategy = await strategyFactory.deploy(d.address);
    await strategy.waitForDeployment();
    return { mockStrategyContract: strategy };
  }

  before(async () => {
    const {
      implAddress,
      deployer: d,
      eoaStrategySigner: es,
      nonStrategySigner: ns,
    } = await loadFixture(deployImplementationFixture);
    concreteAdapterImplementationAddress = implAddress;
    deployer = d;
    eoaStrategySigner = es;
    nonStrategySigner = ns;

    const { mockStrategyContract: ms } = await loadFixture(deployMockStrategyFixture);
    mockStrategyContract = ms;
  });

  async function deployAdapterProxy(
    strategyAddressToSet: string,
  ): Promise<ConcreteBaseVotingAdapterV1> {
    const factory = new ConcreteBaseVotingAdapterV1__factory(deployer);
    const initData = factory.interface.encodeFunctionData('initialize', [strategyAddressToSet]);
    const proxyFactory = new ERC1967Proxy__factory(deployer);
    const proxy = await proxyFactory.deploy(concreteAdapterImplementationAddress, initData);
    await proxy.waitForDeployment();
    return ConcreteBaseVotingAdapterV1__factory.connect(await proxy.getAddress(), deployer);
  }

  describe('Initialization', () => {
    it('should correctly initialize with the strategy address', async () => {
      const adapter = await deployAdapterProxy(eoaStrategySigner.address);
      expect(await adapter.strategy()).to.equal(eoaStrategySigner.address);
    });

    it('should not allow reinitialization (via proxy)', async () => {
      const adapter = await deployAdapterProxy(eoaStrategySigner.address);
      await expect(adapter.initialize(nonStrategySigner.address)).to.be.revertedWithCustomError(
        adapter,
        'InvalidInitialization',
      );
    });

    it('implementation contract should have initializers disabled', async () => {
      const implContract = ConcreteBaseVotingAdapterV1__factory.connect(
        concreteAdapterImplementationAddress,
        deployer,
      );
      await expect(
        implContract.initialize(eoaStrategySigner.address),
      ).to.be.revertedWithCustomError(implContract, 'InvalidInitialization');
    });
  });

  describe('strategy() view function', () => {
    it('should return the correct strategy address after initialization', async () => {
      const adapter = await deployAdapterProxy(eoaStrategySigner.address);
      expect(await adapter.strategy()).to.equal(eoaStrategySigner.address);
    });
  });

  describe('onlyStrategy modifier', () => {
    let adapter: ConcreteBaseVotingAdapterV1;

    beforeEach(async () => {
      // For these tests, the adapter is initialized with the address of the deployed MockVotingStrategy contract
      adapter = await deployAdapterProxy(await mockStrategyContract.getAddress());
      // Ensure the mock strategy is aware of the adapter it's supposed to call (for the success case)
      await mockStrategyContract.setVotingAdapter(await adapter.getAddress(), true);
    });

    it('should allow recordVote to be called by the strategy contract via MockVotingStrategy.vote', async () => {
      const proposalId = 1;
      const adapterVoteData = ethers.ZeroHash; // Dummy data for the adapter

      await expect(
        mockStrategyContract.connect(nonStrategySigner).vote(
          proposalId,
          0, // voteType (e.g., YES)
          [await adapter.getAddress()], // Adapter to use
          [adapterVoteData], // Data for that adapter
        ),
      ).to.not.be.reverted; // Primary check: the call succeeds
    });

    it('should revert if recordVote is called directly by a non-strategy EOA', async () => {
      const voterAddress = nonStrategySigner.address;
      const proposalId = 1;
      const adapterVoteData = ethers.ZeroHash;
      await expect(
        adapter.connect(nonStrategySigner).recordVote(voterAddress, proposalId, adapterVoteData),
      ).to.be.revertedWithCustomError(adapter, 'NotStrategy');
    });
  });
});
