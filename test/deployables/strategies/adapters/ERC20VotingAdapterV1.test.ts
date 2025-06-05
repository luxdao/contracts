import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { loadFixture, time } from '@nomicfoundation/hardhat-network-helpers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  ERC1967Proxy__factory,
  ERC20VotingAdapterV1,
  ERC20VotingAdapterV1__factory,
  IERC165__factory,
  IERC20VotingAdapterV1__factory,
  IVersion__factory,
  IVotingAdapterV1__factory,
  MockERC20Votes,
  MockERC20Votes__factory,
  MockVotingStrategy,
  MockVotingStrategy__factory,
} from '../../../../typechain-types';
import { calculateInterfaceId } from '../../../helpers/utils';

// Modified helper function to return deployment tx hash
async function deployERC20AdapterProxy(
  proxyDeployer: SignerWithAddress,
  implementationAddress: string,
  tokenAddress: string,
  strategyAddress: string,
  weightPerToken: bigint,
): Promise<{ adapter: ERC20VotingAdapterV1 }> {
  const initData = ERC20VotingAdapterV1__factory.createInterface().encodeFunctionData(
    'initialize',
    [tokenAddress, strategyAddress, weightPerToken],
  );
  const proxyContractFactory = new ERC1967Proxy__factory(proxyDeployer);
  const proxy = await proxyContractFactory.deploy(implementationAddress, initData);
  await proxy.waitForDeployment();

  const adapter = ERC20VotingAdapterV1__factory.connect(await proxy.getAddress(), proxyDeployer);
  return { adapter };
}

describe('ERC20VotingAdapterV1', () => {
  let deployerG: SignerWithAddress;
  let erc20AdapterImplementationAddressG: string;

  const DEFAULT_WEIGHT_PER_TOKEN = 1n;

  async function deployGlobalFixture() {
    const [deployer, user1, user2] = await ethers.getSigners();
    const deployedAdapterImpl = await new ERC20VotingAdapterV1__factory(deployer).deploy();
    await deployedAdapterImpl.waitForDeployment();

    // Assign to global vars
    deployerG = deployer;
    erc20AdapterImplementationAddressG = await deployedAdapterImpl.getAddress();

    // Only return what's needed if this fixture is for global one-time setup
    // For deploying fresh mocks per test suite, a different fixture or direct deployment is better.
    return {
      deployer,
      user1,
      user2,
      erc20AdapterImplementationAddress: erc20AdapterImplementationAddressG,
    };
  }

  // This specialized fixture is for deploying fresh mocks for specific test suites
  async function deployMocksAndSignersFixture() {
    const [deployer, user1, user2] = await ethers.getSigners();

    const deployedMockToken = await new MockERC20Votes__factory(deployer).deploy();

    const deployedMockStrategy = await new MockVotingStrategy__factory(deployer).deploy(
      user1.address,
    ); // user1 as default mock proposer

    // Mint and delegate on the fresh mockToken
    await deployedMockToken.mint(user1.address, ethers.parseUnits('1000', 18));
    await deployedMockToken.mint(user2.address, ethers.parseUnits('500', 18));
    await deployedMockToken.connect(user1).delegate(user1.address);
    await deployedMockToken.connect(user2).delegate(user2.address);

    return {
      deployer,
      user1Signer: user1,
      user2Signer: user2,
      mockToken: deployedMockToken,
      mockStrategy: deployedMockStrategy,
    };
  }

  before(async () => {
    // Load global (one-time) deployments like the adapter implementation address
    await loadFixture(deployGlobalFixture);
  });

  let mockToken: MockERC20Votes;
  let mockStrategy: MockVotingStrategy;
  let deployer: SignerWithAddress;
  let user1Signer: SignerWithAddress;

  beforeEach(async () => {
    const {
      mockToken: mToken,
      mockStrategy: mStrategy,
      deployer: dDeployer,
      user1Signer: vSigner,
    } = await loadFixture(deployMocksAndSignersFixture);

    user1Signer = vSigner;
    mockToken = mToken;
    mockStrategy = mStrategy;
    deployer = dDeployer;
  });

  describe('Initialization', () => {
    it('should initialize correctly with valid parameters and emit event', async () => {
      const { adapter: erc20Adapter } = await deployERC20AdapterProxy(
        deployer,
        erc20AdapterImplementationAddressG,
        await mockToken.getAddress(),
        await mockStrategy.getAddress(),
        DEFAULT_WEIGHT_PER_TOKEN,
      );

      expect(await erc20Adapter.token()).to.equal(await mockToken.getAddress());
      expect(await erc20Adapter.strategy()).to.equal(await mockStrategy.getAddress());
      expect(await erc20Adapter.weightPerToken()).to.equal(DEFAULT_WEIGHT_PER_TOKEN);
    });

    it('should not allow reinitialization', async () => {
      const { adapter: erc20Adapter } = await deployERC20AdapterProxy(
        deployer,
        erc20AdapterImplementationAddressG,
        await mockToken.getAddress(),
        await mockStrategy.getAddress(),
        DEFAULT_WEIGHT_PER_TOKEN,
      );

      await expect(
        erc20Adapter.initialize(ethers.ZeroAddress, ethers.ZeroAddress, 0n),
      ).to.be.revertedWithCustomError(erc20Adapter, 'InvalidInitialization');
    });

    it('Should have initialization disabled in the implementation contract', async function () {
      const implementationContract = ERC20VotingAdapterV1__factory.connect(
        erc20AdapterImplementationAddressG,
        deployerG,
      );

      await expect(
        implementationContract.initialize(
          await mockToken.getAddress(),
          await mockStrategy.getAddress(),
          DEFAULT_WEIGHT_PER_TOKEN,
        ),
      ).to.be.revertedWithCustomError(implementationContract, 'InvalidInitialization');
    });
  });

  describe('weightOf', () => {
    const proposalId = 1;
    const mockExtraData = ethers.ZeroHash;
    let adapter: ERC20VotingAdapterV1;

    async function setupAdapterForWeightOf(clockMode: 0 | 1, customWeightPerToken?: bigint) {
      await mockToken.setClockMode(clockMode);
      const { adapter: deployedAdapter } = await deployERC20AdapterProxy(
        deployer,
        erc20AdapterImplementationAddressG,
        await mockToken.getAddress(),
        await mockStrategy.getAddress(),
        customWeightPerToken || DEFAULT_WEIGHT_PER_TOKEN,
      );
      adapter = deployedAdapter;
    }

    describe('Timestamp Mode', () => {
      beforeEach(async () => {
        await setupAdapterForWeightOf(0);
      });

      it('should return correct weight based on past votes at startTimestamp', async () => {
        const expectedRawVotes = ethers.parseUnits('50', 18);
        const votingStartTimestamp = (await time.latest()) + 100;
        await time.increaseTo(votingStartTimestamp - 50);
        await mockToken.mint(user1Signer.address, expectedRawVotes);
        await mockToken.connect(user1Signer).delegate(user1Signer.address);
        await mockToken.setPastVotes(user1Signer.address, votingStartTimestamp, expectedRawVotes);
        await mockStrategy.setVotingTimestamps(
          proposalId,
          votingStartTimestamp,
          votingStartTimestamp + 1000,
        );
        const weight = await adapter.weightOf(user1Signer.address, proposalId, mockExtraData);
        expect(weight).to.equal(expectedRawVotes * DEFAULT_WEIGHT_PER_TOKEN);
      });

      it('should correctly apply custom weightPerToken', async () => {
        const customWeight = 5n;
        await setupAdapterForWeightOf(0, customWeight);

        const expectedRawVotes = ethers.parseUnits('50', 18);
        const votingStartTimestamp = (await time.latest()) + 100;
        await time.increaseTo(votingStartTimestamp - 50);
        await mockToken.mint(user1Signer.address, expectedRawVotes);
        await mockToken.connect(user1Signer).delegate(user1Signer.address);
        await mockToken.setPastVotes(user1Signer.address, votingStartTimestamp, expectedRawVotes);
        await mockStrategy.setVotingTimestamps(
          proposalId,
          votingStartTimestamp,
          votingStartTimestamp + 1000,
        );

        const weight = await adapter.weightOf(user1Signer.address, proposalId, mockExtraData);
        expect(weight).to.equal(expectedRawVotes * customWeight);
      });

      it('should revert if strategy returns startTimestamp as 0', async () => {
        await mockStrategy.setVotingTimestamps(proposalId, 0, 1000);
        await expect(
          adapter.weightOf(user1Signer.address, proposalId, mockExtraData),
        ).to.be.revertedWithCustomError(adapter, 'ProposalNotReadyForSnapshot');
      });
    });

    describe('BlockNumber Mode', () => {
      beforeEach(async () => {
        await setupAdapterForWeightOf(1);
      });

      it('should return correct weight based on past votes at startBlock', async () => {
        const expectedRawVotes = ethers.parseUnits('75', 18);
        await mockToken.mint(user1Signer.address, expectedRawVotes);
        await mockToken.connect(user1Signer).delegate(user1Signer.address);
        const snapshotBlockNumber = (await time.latestBlock()) + 5;
        await mockToken.setPastVotes(user1Signer.address, snapshotBlockNumber, expectedRawVotes);
        await mockStrategy.setVotingStartBlock(proposalId, snapshotBlockNumber);
        const weight = await adapter.weightOf(user1Signer.address, proposalId, mockExtraData);
        expect(weight).to.equal(expectedRawVotes * DEFAULT_WEIGHT_PER_TOKEN);
      });

      it('should revert if strategy returns startBlock as 0', async () => {
        await mockStrategy.setVotingStartBlock(proposalId, 0);
        await expect(
          adapter.weightOf(user1Signer.address, proposalId, mockExtraData),
        ).to.be.revertedWithCustomError(adapter, 'ProposalNotReadyForSnapshot');
      });
    });

    it('should return 0 if voter has already casted a vote for the proposal', async () => {
      await setupAdapterForWeightOf(0); // Default to timestamp mode
      const votingStartTimestamp = (await time.latest()) + 100;
      await mockStrategy.setVotingTimestamps(
        proposalId,
        votingStartTimestamp,
        votingStartTimestamp + 1000,
      );
      await mockToken.setPastVotes(
        user1Signer.address,
        votingStartTimestamp,
        ethers.parseUnits('10', 18),
      );
      await adapter.connect(user1Signer).recordVote(user1Signer.address, proposalId, mockExtraData);
      const weight = await adapter.weightOf(user1Signer.address, proposalId, mockExtraData);
      expect(weight).to.equal(0);
    });
  });

  describe('recordVote', () => {
    const proposalId = 1;
    const mockExtraData = ethers.ZeroHash;
    const expectedEventAdapterVoteData = '0x';

    let adapter: ERC20VotingAdapterV1;
    let token: MockERC20Votes;
    let strategy: MockVotingStrategy;
    let voter: SignerWithAddress;
    let currentDeployer: SignerWithAddress;

    async function setupAdapterForRecordVote(clockMode: 0 | 1, customWeightPerToken?: bigint) {
      const {
        user1Signer: fixtureVoter,
        deployer: fixDeployer,
        mockToken: fToken,
        mockStrategy: fStrategy,
      } = await loadFixture(deployMocksAndSignersFixture);

      voter = fixtureVoter;
      token = fToken;
      strategy = fStrategy;
      currentDeployer = fixDeployer;

      await token.setClockMode(clockMode);
      const { adapter: deployedAdapter } = await deployERC20AdapterProxy(
        currentDeployer,
        erc20AdapterImplementationAddressG,
        await token.getAddress(),
        await strategy.getAddress(),
        customWeightPerToken || DEFAULT_WEIGHT_PER_TOKEN,
      );
      adapter = deployedAdapter;
    }

    it('should record vote, return casted weight, set flag, and emit VoteRecorded event', async () => {
      await setupAdapterForRecordVote(0);
      const expectedRawVotes = ethers.parseUnits('120', 18);
      const votingStartTimestamp = (await time.latest()) + 200;
      await time.increaseTo(votingStartTimestamp - 100);
      await token.mint(voter.address, expectedRawVotes);
      await token.connect(voter).delegate(voter.address);
      await token.setPastVotes(voter.address, votingStartTimestamp, expectedRawVotes);
      await strategy.setVotingTimestamps(
        proposalId,
        votingStartTimestamp,
        votingStartTimestamp + 1000,
      );

      const expectedWeightCasted = expectedRawVotes * DEFAULT_WEIGHT_PER_TOKEN;

      const weightCastedStatically = await adapter
        .connect(voter)
        .recordVote.staticCall(voter.address, proposalId, mockExtraData);
      expect(weightCastedStatically).to.equal(expectedWeightCasted);

      await expect(adapter.connect(voter).recordVote(voter.address, proposalId, mockExtraData))
        .to.emit(adapter, 'VoteRecorded')
        .withArgs(voter.address, proposalId, expectedWeightCasted, expectedEventAdapterVoteData);

      const weightAfterVote = await adapter.weightOf(voter.address, proposalId, mockExtraData);
      expect(weightAfterVote).to.equal(0);
    });

    it('should correctly apply custom weightPerToken on recordVote and emit event', async () => {
      const customWeight = 3n;
      await setupAdapterForRecordVote(0, customWeight);
      const expectedRawVotes = ethers.parseUnits('70', 18);
      const votingStartTimestamp = (await time.latest()) + 200;
      await time.increaseTo(votingStartTimestamp - 100);
      await token.mint(voter.address, expectedRawVotes);
      await token.connect(voter).delegate(voter.address);
      await token.setPastVotes(voter.address, votingStartTimestamp, expectedRawVotes);
      await strategy.setVotingTimestamps(
        proposalId,
        votingStartTimestamp,
        votingStartTimestamp + 1000,
      );

      const expectedWeightCasted = expectedRawVotes * customWeight;

      const weightCastedStatically = await adapter
        .connect(voter)
        .recordVote.staticCall(voter.address, proposalId, mockExtraData);
      expect(weightCastedStatically).to.equal(expectedWeightCasted);

      await expect(adapter.connect(voter).recordVote(voter.address, proposalId, mockExtraData))
        .to.emit(adapter, 'VoteRecorded')
        .withArgs(voter.address, proposalId, expectedWeightCasted, expectedEventAdapterVoteData);
    });

    it('should revert with AlreadyVoted if trying to vote again', async () => {
      await setupAdapterForRecordVote(0);
      const votingStartTimestamp = (await time.latest()) + 200;
      await token.setPastVotes(voter.address, votingStartTimestamp, ethers.parseUnits('10', 18));
      await strategy.setVotingTimestamps(
        proposalId,
        votingStartTimestamp,
        votingStartTimestamp + 1000,
      );
      await adapter.connect(voter).recordVote(voter.address, proposalId, mockExtraData);
      await expect(
        adapter.connect(voter).recordVote(voter.address, proposalId, mockExtraData),
      ).to.be.revertedWithCustomError(adapter, 'AlreadyVoted');
    });

    it('subsequent weightOf should return 0 after recordVote', async () => {
      await setupAdapterForRecordVote(0);
      const votingStartTimestamp = (await time.latest()) + 200;
      await token.setPastVotes(voter.address, votingStartTimestamp, ethers.parseUnits('10', 18));
      await strategy.setVotingTimestamps(
        proposalId,
        votingStartTimestamp,
        votingStartTimestamp + 1000,
      );
      await adapter.connect(voter).recordVote(voter.address, proposalId, mockExtraData);
      const weight = await adapter.weightOf(voter.address, proposalId, mockExtraData);
      expect(weight).to.equal(0);
    });

    it('should revert with ProposalNotReadyForSnapshot if strategy returns startTimestamp as 0 (Timestamp Mode)', async () => {
      await setupAdapterForRecordVote(0);
      await strategy.setVotingTimestamps(proposalId, 0, 1000);
      await expect(
        adapter.connect(voter).recordVote(voter.address, proposalId, mockExtraData),
      ).to.be.revertedWithCustomError(adapter, 'ProposalNotReadyForSnapshot');
    });

    it('should revert with ProposalNotReadyForSnapshot if strategy returns startBlock as 0 (BlockNumber Mode)', async () => {
      await setupAdapterForRecordVote(1);
      await strategy.setVotingStartBlock(proposalId, 0);
      await expect(
        adapter.connect(voter).recordVote(voter.address, proposalId, mockExtraData),
      ).to.be.revertedWithCustomError(adapter, 'ProposalNotReadyForSnapshot');
    });
  });

  describe('version()', () => {
    it('should return the correct version', async () => {
      const { adapter: erc20Adapter } = await deployERC20AdapterProxy(
        deployer,
        erc20AdapterImplementationAddressG,
        await mockToken.getAddress(),
        await mockStrategy.getAddress(),
        DEFAULT_WEIGHT_PER_TOKEN,
      );

      expect(await erc20Adapter.version()).to.equal(1);
    });
  });

  describe('ERC165 supportsInterface', () => {
    let erc20Adapter: ERC20VotingAdapterV1;

    beforeEach(async () => {
      const { adapter } = await deployERC20AdapterProxy(
        deployer,
        erc20AdapterImplementationAddressG,
        await mockToken.getAddress(),
        await mockStrategy.getAddress(),
        DEFAULT_WEIGHT_PER_TOKEN,
      );
      erc20Adapter = adapter;
    });

    it('should support IERC20VotingAdapterV1', async () => {
      void expect(
        await erc20Adapter.supportsInterface(
          calculateInterfaceId(IERC20VotingAdapterV1__factory.createInterface(), [
            IVotingAdapterV1__factory.createInterface(),
          ]),
        ),
      ).to.be.true;
    });

    it('should support IVotingAdapterV1', async () => {
      void expect(
        await erc20Adapter.supportsInterface(
          calculateInterfaceId(IVotingAdapterV1__factory.createInterface()),
        ),
      ).to.be.true;
    });

    it('should support IVersion', async () => {
      void expect(
        await erc20Adapter.supportsInterface(
          calculateInterfaceId(IVersion__factory.createInterface()),
        ),
      ).to.be.true;
    });

    it('should support IERC165', async () => {
      void expect(
        await erc20Adapter.supportsInterface(
          calculateInterfaceId(IERC165__factory.createInterface()),
        ),
      ).to.be.true;
    });

    it('should not support a random interfaceId', async () => {
      void expect(await erc20Adapter.supportsInterface('0x12345678')).to.be.false;
    });
  });
});
