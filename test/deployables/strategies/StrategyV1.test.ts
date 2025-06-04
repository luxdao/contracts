import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { time } from '@nomicfoundation/hardhat-network-helpers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  ERC1967Proxy__factory,
  IERC165__factory,
  IERC4337VoterSupportV1__factory,
  ISmartAccountValidationV1__factory,
  IStrategyV1__factory,
  IVersion__factory,
  MockLightAccount__factory,
  MockLightAccountFactory,
  MockLightAccountFactory__factory,
  MockProposerAdapter,
  MockProposerAdapter__factory,
  MockVotingAdapter,
  MockVotingAdapter__factory,
  StrategyV1,
  StrategyV1__factory,
} from '../../../typechain-types';
import { calculateInterfaceId } from '../../helpers/utils';

describe('StrategyV1', () => {
  // Signers
  let deployer: SignerWithAddress;
  let proposerInitializer: SignerWithAddress; // To simulate calls from proposer initializer
  let nonOwner: SignerWithAddress;
  let user1: SignerWithAddress;
  let voter1: SignerWithAddress, voter2: SignerWithAddress, voter3: SignerWithAddress;

  // Contract Instances
  let strategyImplementation: StrategyV1;
  let strategy: StrategyV1;
  let mockAdapter1: MockVotingAdapter;
  let mockAdapter2: MockVotingAdapter;
  let mockProposerAdapter1: MockProposerAdapter;
  let mockProposerAdapter2: MockProposerAdapter;
  let lightAccountFactoryMock: MockLightAccountFactory;
  let lightAccountFactoryMockAddress: string;

  // Default Initialization Parameters for StrategyV1
  const DEFAULT_VOTING_PERIOD = 100; // Example value
  const DEFAULT_QUORUM_THRESHOLD = 1n;
  const DEFAULT_BASIS_NUMERATOR = 500_001n;
  let defaultInitialVotingAdapters: string[];
  let defaultInitialProposerAdapters: string[];

  async function deployStrategyProxy(
    proposerInitializerAddress: string,
    votingPeriod: number,
    quorumThreshold: bigint,
    basisNumerator: bigint,
    initialVotingAdaptersAddresses: string[],
    initialProposerAdaptersAddresses: string[],
    lightAccountFactoryAddress: string,
  ): Promise<StrategyV1> {
    const initializeCalldata = strategyImplementation.interface.encodeFunctionData('initialize', [
      proposerInitializerAddress,
      votingPeriod,
      quorumThreshold,
      basisNumerator,
      initialVotingAdaptersAddresses,
      initialProposerAdaptersAddresses,
      lightAccountFactoryAddress,
    ]);
    const proxy = await new ERC1967Proxy__factory(deployer).deploy(
      await strategyImplementation.getAddress(),
      initializeCalldata,
    );
    return StrategyV1__factory.connect(await proxy.getAddress(), deployer);
  }

  beforeEach(async () => {
    [deployer, proposerInitializer, nonOwner, user1, voter2, voter3] = await ethers.getSigners();
    voter1 = user1; // Alias for clarity in some tests

    strategyImplementation = await new StrategyV1__factory(deployer).deploy();
    await strategyImplementation.waitForDeployment();

    lightAccountFactoryMock = await new MockLightAccountFactory__factory(deployer).deploy();
    await lightAccountFactoryMock.waitForDeployment();
    lightAccountFactoryMockAddress = lightAccountFactoryMock.target as string;

    mockAdapter1 = await new MockVotingAdapter__factory(deployer).deploy();
    await mockAdapter1.waitForDeployment();
    mockAdapter2 = await new MockVotingAdapter__factory(deployer).deploy();
    await mockAdapter2.waitForDeployment();

    mockProposerAdapter1 = await new MockProposerAdapter__factory(deployer).deploy();
    await mockProposerAdapter1.waitForDeployment();
    mockProposerAdapter2 = await new MockProposerAdapter__factory(deployer).deploy();
    await mockProposerAdapter2.waitForDeployment();

    defaultInitialVotingAdapters = [await mockAdapter1.getAddress()];
    defaultInitialProposerAdapters = [await mockProposerAdapter1.getAddress()];

    strategy = await deployStrategyProxy(
      proposerInitializer.address,
      DEFAULT_VOTING_PERIOD,
      DEFAULT_QUORUM_THRESHOLD,
      DEFAULT_BASIS_NUMERATOR,
      defaultInitialVotingAdapters,
      defaultInitialProposerAdapters,
      lightAccountFactoryMockAddress,
    );
  });

  describe('Initialization', () => {
    it('should initialize with correct parameters', async () => {
      const proposerInitializerAddress = proposerInitializer.address;
      const lightAccountFactoryAddress = lightAccountFactoryMockAddress;
      const initialVotingAdapters: string[] = [
        await mockAdapter1.getAddress(),
        await mockAdapter2.getAddress(),
      ];
      const initialProposerAdapters: string[] = [
        await mockProposerAdapter1.getAddress(),
        await mockProposerAdapter2.getAddress(),
      ];
      const votingPeriod = DEFAULT_VOTING_PERIOD + 10;
      const quorumThreshold = DEFAULT_QUORUM_THRESHOLD + 1n;
      const basisNumerator = DEFAULT_BASIS_NUMERATOR + 1n;

      const testStrategy = await deployStrategyProxy(
        proposerInitializerAddress,
        votingPeriod,
        quorumThreshold,
        basisNumerator,
        initialVotingAdapters,
        initialProposerAdapters,
        lightAccountFactoryAddress,
      );

      expect(await testStrategy.proposalInitializer()).to.equal(proposerInitializer);
      expect(await testStrategy.votingPeriod()).to.equal(votingPeriod);
      expect(await testStrategy.quorumThreshold()).to.equal(quorumThreshold);
      expect(await testStrategy.basisNumerator()).to.equal(basisNumerator);
      expect(await testStrategy.lightAccountFactory()).to.equal(lightAccountFactoryAddress);
      expect(await testStrategy.votingAdapters()).to.deep.equal(initialVotingAdapters);
      expect(await testStrategy.proposerAdapters()).to.deep.equal(initialProposerAdapters);
    });

    it('should revert if basis numerator is invalid (too high) during initialization', async () => {
      await expect(
        deployStrategyProxy(
          proposerInitializer.address,
          DEFAULT_VOTING_PERIOD,
          DEFAULT_QUORUM_THRESHOLD,
          1_000_001n,
          [await mockAdapter1.getAddress()],
          [await mockProposerAdapter1.getAddress()],
          lightAccountFactoryMockAddress,
        ),
      ).to.be.revertedWithCustomError(strategyImplementation, 'InvalidBasisNumerator');
    });

    it('should revert if basis numerator is invalid (too low, <50%) during initialization', async () => {
      await expect(
        deployStrategyProxy(
          proposerInitializer.address,
          DEFAULT_VOTING_PERIOD,
          DEFAULT_QUORUM_THRESHOLD,
          499_999n,
          [await mockAdapter1.getAddress()],
          [await mockProposerAdapter1.getAddress()],
          lightAccountFactoryMockAddress,
        ),
      ).to.be.revertedWithCustomError(strategyImplementation, 'InvalidBasisNumerator');
    });

    it('should initialize correctly with zero quorum threshold', async () => {
      const testStrategy = await deployStrategyProxy(
        proposerInitializer.address,
        DEFAULT_VOTING_PERIOD,
        0n, // Zero quorum threshold
        DEFAULT_BASIS_NUMERATOR,
        [await mockAdapter1.getAddress()],
        [await mockProposerAdapter1.getAddress()],
        lightAccountFactoryMockAddress,
      );
      expect(await testStrategy.quorumThreshold()).to.equal(0n);
    });

    it('should initialize correctly with basis numerator at 50%', async () => {
      const testStrategy = await deployStrategyProxy(
        proposerInitializer.address,
        DEFAULT_VOTING_PERIOD,
        DEFAULT_QUORUM_THRESHOLD,
        500_000n, // 50% basis numerator
        [await mockAdapter1.getAddress()],
        [await mockProposerAdapter1.getAddress()],
        lightAccountFactoryMockAddress,
      );
      expect(await testStrategy.basisNumerator()).to.equal(500_000n);
    });

    it('should revert when initializing with basis numerator at 100% (1,000,000)', async () => {
      await expect(
        deployStrategyProxy(
          proposerInitializer.address,
          DEFAULT_VOTING_PERIOD,
          DEFAULT_QUORUM_THRESHOLD,
          1_000_000n, // 100% basis numerator - now invalid
          [await mockAdapter1.getAddress()],
          [await mockProposerAdapter1.getAddress()],
          lightAccountFactoryMockAddress,
        ),
      ).to.be.revertedWithCustomError(strategyImplementation, 'InvalidBasisNumerator');
    });

    it('should initialize correctly with basis numerator at new maximum (BASIS_DENOMINATOR - 1)', async () => {
      const maxValidBasis = 1_000_000n - 1n; // BASIS_DENOMINATOR - 1
      const testStrategy = await deployStrategyProxy(
        proposerInitializer.address,
        DEFAULT_VOTING_PERIOD,
        DEFAULT_QUORUM_THRESHOLD,
        maxValidBasis,
        [await mockAdapter1.getAddress()],
        [await mockProposerAdapter1.getAddress()],
        lightAccountFactoryMockAddress,
      );
      expect(await testStrategy.basisNumerator()).to.equal(maxValidBasis);
    });

    it('should revert if initialProposerAdapters is empty', async () => {
      await expect(
        deployStrategyProxy(
          proposerInitializer.address,
          DEFAULT_VOTING_PERIOD,
          DEFAULT_QUORUM_THRESHOLD,
          DEFAULT_BASIS_NUMERATOR,
          defaultInitialVotingAdapters, // Non-empty
          [], // Empty proposer adapters
          lightAccountFactoryMockAddress,
        ),
      ).to.be.revertedWithCustomError(strategyImplementation, 'NoProposerAdapters');
    });

    it('should revert if initialVotingAdapters is empty', async () => {
      await expect(
        deployStrategyProxy(
          proposerInitializer.address,
          DEFAULT_VOTING_PERIOD,
          DEFAULT_QUORUM_THRESHOLD,
          DEFAULT_BASIS_NUMERATOR,
          [], // Empty voting adapters
          defaultInitialProposerAdapters, // Non-empty
          lightAccountFactoryMockAddress,
        ),
      ).to.be.revertedWithCustomError(strategyImplementation, 'NoVotingAdapters');
    });
  });

  describe('votingAdapters', () => {
    it('should return the correct voting adapters', async () => {
      expect(await strategy.votingAdapters()).to.deep.equal(defaultInitialVotingAdapters);
    });
  });

  describe('proposerAdapters', () => {
    it('should return the correct proposer adapters', async () => {
      expect(await strategy.proposerAdapters()).to.deep.equal(defaultInitialProposerAdapters);
    });
  });

  describe('isVotingAdapter', () => {
    it('should return true for a configured voting adapter', async () => {
      const configuredAdapter = defaultInitialVotingAdapters[0];
      void expect(await strategy.isVotingAdapter(configuredAdapter)).to.be.true;
    });

    it('should return false for an unconfigured address', async () => {
      void expect(await strategy.isVotingAdapter(nonOwner.address)).to.be.false;
    });

    it('should return false for a configured proposer adapter that is not a voting adapter', async () => {
      const proposerOnlyAdapter = await new MockProposerAdapter__factory(deployer).deploy();
      await proposerOnlyAdapter.waitForDeployment();
      const testStrategy = await deployStrategyProxy(
        proposerInitializer.address,
        DEFAULT_VOTING_PERIOD,
        DEFAULT_QUORUM_THRESHOLD,
        DEFAULT_BASIS_NUMERATOR,
        defaultInitialVotingAdapters, // mockAdapter1
        [await proposerOnlyAdapter.getAddress()],
        lightAccountFactoryMockAddress,
      );
      void expect(await testStrategy.isVotingAdapter(await proposerOnlyAdapter.getAddress())).to.be
        .false;
    });
  });

  describe('isProposerAdapter', () => {
    it('should return true for a configured proposer adapter', async () => {
      const configuredAdapter = defaultInitialProposerAdapters[0];
      void expect(await strategy.isProposerAdapter(configuredAdapter)).to.be.true;
    });

    it('should return false for an unconfigured address', async () => {
      void expect(await strategy.isProposerAdapter(nonOwner.address)).to.be.false;
    });

    it('should return false for a configured voting adapter that is not a proposer adapter', async () => {
      const votingOnlyAdapter = await new MockVotingAdapter__factory(deployer).deploy();
      await votingOnlyAdapter.waitForDeployment();
      const testStrategy = await deployStrategyProxy(
        proposerInitializer.address,
        DEFAULT_VOTING_PERIOD,
        DEFAULT_QUORUM_THRESHOLD,
        DEFAULT_BASIS_NUMERATOR,
        [await votingOnlyAdapter.getAddress()],
        defaultInitialProposerAdapters, // mockProposerAdapter1
        lightAccountFactoryMockAddress,
      );
      void expect(await testStrategy.isProposerAdapter(await votingOnlyAdapter.getAddress())).to.be
        .false;
    });
  });

  describe('initializeProposal', () => {
    let defaultProposalId: number;

    beforeEach(() => {
      defaultProposalId = 1;
    });

    it('should revert if called by a non-proposer initializer address', async () => {
      await expect(
        strategy.connect(nonOwner).initializeProposal(defaultProposalId, [], ethers.ZeroHash),
      ).to.be.revertedWithCustomError(strategy, 'InvalidProposalInitializer');
    });

    it('should correctly initialize proposal details and emit event', async () => {
      const blockBefore = await ethers.provider.getBlock('latest');
      if (!blockBefore) throw new Error('Failed to get latest block');
      const timestampBefore = blockBefore.timestamp;
      const blockNumberBefore = blockBefore.number;

      await expect(
        strategy
          .connect(proposerInitializer)
          .initializeProposal(defaultProposalId, [], ethers.ZeroHash),
      )
        .to.emit(strategy, 'ProposalInitialized')
        .withArgs(
          defaultProposalId,
          timestampBefore + 1,
          timestampBefore + 1 + DEFAULT_VOTING_PERIOD,
          blockNumberBefore + 1,
        );

      const proposalDetails = await strategy.proposalVotingDetails(defaultProposalId);
      expect(proposalDetails.votingStartTimestamp).to.be.closeTo(timestampBefore + 1, 2);
      expect(proposalDetails.votingEndTimestamp).to.be.closeTo(
        timestampBefore + 1 + DEFAULT_VOTING_PERIOD,
        2,
      );
      expect(proposalDetails.votingStartBlock).to.equal(blockNumberBefore + 1);
      expect(proposalDetails.yesVotes).to.equal(0);
      expect(proposalDetails.noVotes).to.equal(0);
      expect(proposalDetails.abstainVotes).to.equal(0);
    });

    it('should reset vote counts for a re-initialized proposal', async () => {
      await strategy
        .connect(proposerInitializer)
        .initializeProposal(defaultProposalId, [], ethers.ZeroHash);

      await strategy
        .connect(proposerInitializer)
        .initializeProposal(defaultProposalId, [], ethers.ZeroHash); // Re-initialize

      const proposalDetails = await strategy.proposalVotingDetails(defaultProposalId);
      expect(proposalDetails.yesVotes).to.equal(0);
      expect(proposalDetails.noVotes).to.equal(0);
      expect(proposalDetails.abstainVotes).to.equal(0);
    });
  });

  describe('isProposer', () => {
    it('should return true if any configured adapter identifies the address as a proposer', async () => {
      const mockProposerAdapter1Address = await mockProposerAdapter1.getAddress();
      const mockProposerAdapter2Address = await mockProposerAdapter2.getAddress();
      const multiProposerStrategy = await deployStrategyProxy(
        proposerInitializer.address,
        DEFAULT_VOTING_PERIOD,
        DEFAULT_QUORUM_THRESHOLD,
        DEFAULT_BASIS_NUMERATOR,
        defaultInitialVotingAdapters,
        [mockProposerAdapter1Address, mockProposerAdapter2Address],
        lightAccountFactoryMockAddress,
      );

      await mockProposerAdapter1.setProposerStatus(user1.address, false);
      await mockProposerAdapter2.setProposerStatus(user1.address, true);

      // Check against adapter 1 (should be false)
      void expect(
        await multiProposerStrategy.isProposer(
          user1.address,
          mockProposerAdapter1Address,
          ethers.ZeroHash,
        ),
      ).to.be.false;

      // Check against adapter 2 (should be true)
      void expect(
        await multiProposerStrategy.isProposer(
          user1.address,
          mockProposerAdapter2Address,
          ethers.ZeroHash,
        ),
      ).to.be.true;
    });

    it('should return false if no configured adapter identifies the address as a proposer', async () => {
      const mockProposerAdapter1Address = await mockProposerAdapter1.getAddress();
      await mockProposerAdapter1.setProposerStatus(user1.address, false);
      void expect(
        await strategy.isProposer(user1.address, mockProposerAdapter1Address, ethers.ZeroHash),
      ).to.be.false;

      const mockProposerAdapter2Address = await mockProposerAdapter2.getAddress();
      const multiProposerStrategy = await deployStrategyProxy(
        proposerInitializer.address,
        DEFAULT_VOTING_PERIOD,
        DEFAULT_QUORUM_THRESHOLD,
        DEFAULT_BASIS_NUMERATOR,
        defaultInitialVotingAdapters,
        [mockProposerAdapter1Address, mockProposerAdapter2Address],
        lightAccountFactoryMockAddress,
      );
      await mockProposerAdapter1.setProposerStatus(user1.address, false);
      await mockProposerAdapter2.setProposerStatus(user1.address, false);
      void expect(
        await multiProposerStrategy.isProposer(
          user1.address,
          mockProposerAdapter1Address,
          ethers.ZeroHash,
        ),
      ).to.be.false;
      void expect(
        await multiProposerStrategy.isProposer(
          user1.address,
          mockProposerAdapter2Address,
          ethers.ZeroHash,
        ),
      ).to.be.false;
    });

    it('should return true if the first configured adapter identifies the address as a proposer', async () => {
      const mockProposerAdapter1Address = await mockProposerAdapter1.getAddress();
      await mockProposerAdapter1.setProposerStatus(user1.address, true);
      void expect(
        await strategy.isProposer(user1.address, mockProposerAdapter1Address, ethers.ZeroHash),
      ).to.be.true;
    });
  });

  describe('getVotingTimestamps & getVotingStartBlock', () => {
    let proposalId: number;

    beforeEach(async () => {
      proposalId = 1;
      await strategy
        .connect(proposerInitializer)
        .initializeProposal(proposalId, [], ethers.ZeroHash);
    });

    it('should return correct timestamps and block after proposal initialization', async () => {
      const blockBeforeInit = await strategy.proposalVotingDetails(proposalId);
      const initTimestamp = blockBeforeInit.votingStartTimestamp;

      const [startTime, endTime] = await strategy.getVotingTimestamps(proposalId);
      const startBlock = await strategy.getVotingStartBlock(proposalId);

      expect(startTime).to.equal(initTimestamp);
      expect(endTime).to.equal(initTimestamp + BigInt(DEFAULT_VOTING_PERIOD));
      expect(startBlock).to.equal(blockBeforeInit.votingStartBlock);
    });

    it('getVotingTimestamps should revert if proposal is not initialized', async () => {
      const uninitializedProposalId = 999;
      await expect(
        strategy.getVotingTimestamps(uninitializedProposalId),
      ).to.be.revertedWithCustomError(strategy, 'ProposalNotInitialized');
    });

    it('getVotingStartBlock should revert if proposal is not initialized', async () => {
      const uninitializedProposalId = 999;
      await expect(
        strategy.getVotingStartBlock(uninitializedProposalId),
      ).to.be.revertedWithCustomError(strategy, 'ProposalNotInitialized');
    });
  });

  describe('vote', () => {
    let proposalId: number;
    let adapter1Data: string;
    let adapter2Data: string;

    beforeEach(async () => {
      proposalId = 1;
      await strategy
        .connect(proposerInitializer)
        .initializeProposal(proposalId, [], ethers.ZeroHash);

      adapter1Data = ethers.AbiCoder.defaultAbiCoder().encode(['uint256[]'], [[1]]);
      adapter2Data = ethers.AbiCoder.defaultAbiCoder().encode(['uint256[]'], [[2]]);
    });

    it('should revert if _adaptersToUse and _adapterVoteData lengths mismatch', async () => {
      const adaptersToUse = [await mockAdapter1.getAddress()]; // 1 adapter
      const adapterVoteData: string[] = []; // 0 data entries
      await expect(
        strategy.connect(user1).vote(proposalId, 1, adaptersToUse, adapterVoteData),
      ).to.be.revertedWithCustomError(strategy, 'MismatchedInputs');
    });

    it('should revert if proposal is not initialized (votingEndTimestamp is 0)', async () => {
      const uninitializedProposalId = 999;
      await expect(
        strategy
          .connect(user1)
          .vote(uninitializedProposalId, 1, [await mockAdapter1.getAddress()], [adapter1Data]),
      ).to.be.revertedWithCustomError(strategy, 'ProposalNotFoundOrNotActive');
    });

    it('should revert if voting period has ended', async () => {
      const proposalDetails = await strategy.proposalVotingDetails(proposalId);
      await time.increaseTo(proposalDetails.votingEndTimestamp + 1n);

      await expect(
        strategy
          .connect(user1)
          .vote(proposalId, 1, [await mockAdapter1.getAddress()], [adapter1Data]),
      ).to.be.revertedWithCustomError(strategy, 'ProposalNotFoundOrNotActive');
    });

    it('should revert if total weight cast is zero (e.g., adapter.recordVote returns 0)', async () => {
      await mockAdapter1.setWeight(user1.address, 0);
      await expect(
        strategy
          .connect(user1)
          .vote(proposalId, 1, [await mockAdapter1.getAddress()], [adapter1Data]),
      ).to.be.revertedWithCustomError(strategy, 'NoVotingWeight');
    });

    it('should revert on invalid voteType', async () => {
      const invalidVoteType = 3; // VoteType enum is 0, 1, 2
      await mockAdapter1.setWeight(user1.address, 10);
      await expect(
        strategy
          .connect(user1)
          .vote(proposalId, invalidVoteType, [await mockAdapter1.getAddress()], [adapter1Data]),
      ).to.be.revertedWithCustomError(strategy, 'InvalidVoteType');
    });

    it('should revert with InvalidVotingAdapter if an adapter in _adaptersToUse is not configured in the strategy', async () => {
      const unconfiguredAdapter = await new MockVotingAdapter__factory(deployer).deploy();
      await unconfiguredAdapter.waitForDeployment();
      const unconfiguredAdapterAddress = await unconfiguredAdapter.getAddress();

      await mockAdapter1.setWeight(user1.address, 10);

      const adaptersToUse = [await mockAdapter1.getAddress(), unconfiguredAdapterAddress];
      const adapterDataArray = [adapter1Data, adapter1Data];

      await expect(
        strategy.connect(user1).vote(proposalId, 1 /* YES */, adaptersToUse, adapterDataArray),
      ).to.be.revertedWithCustomError(strategy, 'InvalidVotingAdapter');
    });

    it('should correctly record a YES vote, update counts, and emit Voted event', async () => {
      const voteWeight = 100;
      await mockAdapter1.setWeight(user1.address, voteWeight);

      const tx = await strategy
        .connect(user1)
        .vote(proposalId, 1 /* YES */, [await mockAdapter1.getAddress()], [adapter1Data]);

      await expect(tx)
        .to.emit(strategy, 'Voted')
        .withArgs(user1.address, proposalId, 1 /* YES */, voteWeight);

      const proposalDetails = await strategy.proposalVotingDetails(proposalId);
      expect(proposalDetails.yesVotes).to.equal(voteWeight);
      expect(proposalDetails.noVotes).to.equal(0);
      expect(proposalDetails.abstainVotes).to.equal(0);

      expect(await mockAdapter1.lastVoterForRecordVote()).to.equal(user1.address);
      expect(await mockAdapter1.lastProposalIdForRecordVote()).to.equal(proposalId);
      expect(
        await mockAdapter1.recordedVotesWeight(
          user1.address,
          proposalId,
          ethers.keccak256(adapter1Data),
        ),
      ).to.equal(voteWeight);
    });

    it('should correctly record a NO vote', async () => {
      const voteWeight = 50;
      await mockAdapter1.setWeight(user1.address, voteWeight);

      await expect(
        strategy
          .connect(user1)
          .vote(proposalId, 0 /* NO */, [await mockAdapter1.getAddress()], [adapter1Data]),
      )
        .to.emit(strategy, 'Voted')
        .withArgs(user1.address, proposalId, 0 /* NO */, voteWeight);

      const proposalDetails = await strategy.proposalVotingDetails(proposalId);
      expect(proposalDetails.noVotes).to.equal(voteWeight);
      expect(proposalDetails.yesVotes).to.equal(0);
      expect(proposalDetails.abstainVotes).to.equal(0);
    });

    it('should correctly record an ABSTAIN vote', async () => {
      const voteWeight = 25;
      await mockAdapter1.setWeight(user1.address, voteWeight);

      await expect(
        strategy
          .connect(user1)
          .vote(proposalId, 2 /* ABSTAIN */, [await mockAdapter1.getAddress()], [adapter1Data]),
      )
        .to.emit(strategy, 'Voted')
        .withArgs(user1.address, proposalId, 2 /* ABSTAIN */, voteWeight);

      const proposalDetails = await strategy.proposalVotingDetails(proposalId);
      expect(proposalDetails.abstainVotes).to.equal(voteWeight);
      expect(proposalDetails.yesVotes).to.equal(0);
      expect(proposalDetails.noVotes).to.equal(0);
    });

    it('should sum weights if multiple adapters are used in one vote call', async () => {
      const multiAdapterStrategy = await deployStrategyProxy(
        proposerInitializer.address,
        DEFAULT_VOTING_PERIOD,
        DEFAULT_QUORUM_THRESHOLD,
        DEFAULT_BASIS_NUMERATOR,
        [await mockAdapter1.getAddress(), await mockAdapter2.getAddress()], // Both adapters
        defaultInitialProposerAdapters,
        lightAccountFactoryMockAddress,
      );
      await multiAdapterStrategy
        .connect(proposerInitializer)
        .initializeProposal(proposalId, [], ethers.ZeroHash);

      const weight1 = 60;
      const weight2 = 40;
      await mockAdapter1.setWeight(user1.address, weight1);
      await mockAdapter2.setWeight(user1.address, weight2);

      const adaptersToUseAddresses = [
        await mockAdapter1.getAddress(),
        await mockAdapter2.getAddress(),
      ];
      const adapterVoteDataArray = [adapter1Data, adapter2Data];

      await expect(
        multiAdapterStrategy
          .connect(user1)
          .vote(proposalId, 1 /* YES */, adaptersToUseAddresses, adapterVoteDataArray),
      )
        .to.emit(multiAdapterStrategy, 'Voted')
        .withArgs(user1.address, proposalId, 1 /* YES */, weight1 + weight2);

      const proposalDetails = await multiAdapterStrategy.proposalVotingDetails(proposalId);
      expect(proposalDetails.yesVotes).to.equal(weight1 + weight2);
    });

    it('should support ERC4337 by using the resolved voter address', async () => {
      const smartAccountOwner = user1;
      const relayer = nonOwner;

      const mockLightAccountDeployedFactory = new MockLightAccount__factory(deployer);
      const mockSmartAccount = await mockLightAccountDeployedFactory.deploy(
        smartAccountOwner.address,
      );
      await mockSmartAccount.waitForDeployment();
      const mockSmartAccountAddress = await mockSmartAccount.getAddress();

      await lightAccountFactoryMock.setAccountAddress(
        smartAccountOwner.address,
        0,
        mockSmartAccountAddress,
      );

      const voteWeight = 77;
      await mockAdapter1.setWeight(smartAccountOwner.address, voteWeight);

      const tx = await mockSmartAccount
        .connect(relayer)
        .callStrategyVote(
          await strategy.getAddress(),
          proposalId,
          1 /* YES */,
          [await mockAdapter1.getAddress()],
          [adapter1Data],
        );

      await expect(tx)
        .to.emit(strategy, 'Voted')
        .withArgs(smartAccountOwner.address, proposalId, 1 /* YES */, voteWeight);

      const proposalDetails = await strategy.proposalVotingDetails(proposalId);
      expect(proposalDetails.yesVotes).to.equal(voteWeight);

      expect(await mockAdapter1.lastVoterForRecordVote()).to.equal(smartAccountOwner.address);
    });

    it('should revert if an adapter call to recordVote reverts', async () => {
      await mockAdapter1.setWeight(user1.address, 10);
      await mockAdapter1.setShouldRevertOnRecordVote(true);

      await expect(
        strategy
          .connect(user1)
          .vote(proposalId, 1 /* YES */, [await mockAdapter1.getAddress()], [adapter1Data]),
      ).to.be.revertedWith('MockVotingAdapter: recordVote forced revert');
    });

    it('should revert if any adapter call reverts in a multi-adapter vote (all-or-nothing)', async () => {
      const multiAdapterStrategy = await deployStrategyProxy(
        proposerInitializer.address,
        DEFAULT_VOTING_PERIOD,
        DEFAULT_QUORUM_THRESHOLD,
        DEFAULT_BASIS_NUMERATOR,
        [await mockAdapter1.getAddress(), await mockAdapter2.getAddress()], // Both adapters
        defaultInitialProposerAdapters,
        lightAccountFactoryMockAddress,
      );
      await multiAdapterStrategy
        .connect(proposerInitializer)
        .initializeProposal(proposalId, [], ethers.ZeroHash);

      await mockAdapter1.setWeight(user1.address, 10);
      await mockAdapter2.setWeight(user1.address, 20);

      await mockAdapter1.setShouldRevertOnRecordVote(false);
      await mockAdapter2.setShouldRevertOnRecordVote(true); // Adapter 2 will revert

      const adaptersToUseAddresses = [
        await mockAdapter1.getAddress(),
        await mockAdapter2.getAddress(),
      ];
      const adapterDataForVoter1Adapter1 = ethers.AbiCoder.defaultAbiCoder().encode(
        ['uint256[]'],
        [[777]],
      );
      const adapterDataForVoter1Adapter2 = ethers.AbiCoder.defaultAbiCoder().encode(
        ['uint256[]'],
        [[888]],
      );
      const adapterVoteDataArray = [adapterDataForVoter1Adapter1, adapterDataForVoter1Adapter2];

      await expect(
        multiAdapterStrategy
          .connect(user1)
          .vote(proposalId, 1 /* YES */, adaptersToUseAddresses, adapterVoteDataArray),
      ).to.be.revertedWith('MockVotingAdapter: recordVote forced revert');

      const proposalDetails = await multiAdapterStrategy.proposalVotingDetails(proposalId);
      expect(proposalDetails.yesVotes).to.equal(0);
      expect(proposalDetails.noVotes).to.equal(0);
      expect(proposalDetails.abstainVotes).to.equal(0);

      const dataHashAdapter1 = ethers.keccak256(adapterDataForVoter1Adapter1);
      void expect(await mockAdapter1.hasRecordedVote(user1.address, proposalId, dataHashAdapter1))
        .to.be.false;
    });
  });

  describe('isPassed', () => {
    const PROPOSAL_ID = 1;
    beforeEach(async () => {
      await strategy
        .connect(proposerInitializer)
        .initializeProposal(PROPOSAL_ID, [], ethers.ZeroHash);
    });

    it('should revert with ProposalNotInitialized if proposal was not initialized', async () => {
      const uninitializedProposalId = 999;
      await expect(strategy.isPassed(uninitializedProposalId)).to.be.revertedWithCustomError(
        strategy,
        'ProposalNotInitialized',
      );
    });

    it('should return false if voting period is not over', async () => {
      await mockAdapter1.setWeight(voter1.address, DEFAULT_QUORUM_THRESHOLD + 10n);
      await strategy
        .connect(voter1)
        .vote(PROPOSAL_ID, 1 /* YES */, [await mockAdapter1.getAddress()], [ethers.ZeroHash]);
      void expect(await strategy.isPassed(PROPOSAL_ID)).to.be.false; // Voting not over
    });

    it('should return true if quorum and basis are met and voting is over', async () => {
      await mockAdapter1.setWeight(voter1.address, DEFAULT_QUORUM_THRESHOLD + 10n);
      await strategy
        .connect(voter1)
        .vote(PROPOSAL_ID, 1 /* YES */, [await mockAdapter1.getAddress()], [ethers.ZeroHash]);

      const proposalDetails = await strategy.proposalVotingDetails(PROPOSAL_ID);
      await time.increaseTo(proposalDetails.votingEndTimestamp + 1n);

      void expect(await strategy.isPassed(PROPOSAL_ID)).to.be.true;
    });

    it('should return false if quorum is met but basis is not, after voting period', async () => {
      const specificStrategy = await deployStrategyProxy(
        proposerInitializer.address,
        DEFAULT_VOTING_PERIOD,
        50n, // quorumThreshold
        500_001n, // basisNumerator (yes > no)
        defaultInitialVotingAdapters,
        defaultInitialProposerAdapters,
        lightAccountFactoryMockAddress,
      );
      await specificStrategy
        .connect(proposerInitializer)
        .initializeProposal(PROPOSAL_ID, [], ethers.ZeroHash);

      await mockAdapter1.setWeight(voter1.address, 50n);
      await mockAdapter1.setWeight(voter2.address, 50n);
      await mockAdapter1.setWeight(voter3.address, 10n);

      await specificStrategy
        .connect(voter1)
        .vote(PROPOSAL_ID, 1 /* YES */, [await mockAdapter1.getAddress()], [ethers.ZeroHash]);
      await specificStrategy
        .connect(voter2)
        .vote(PROPOSAL_ID, 0 /* NO */, [await mockAdapter1.getAddress()], [ethers.ZeroHash]);
      await specificStrategy
        .connect(voter3)
        .vote(PROPOSAL_ID, 2 /* ABSTAIN */, [await mockAdapter1.getAddress()], [ethers.ZeroHash]);

      const proposalDetails = await specificStrategy.proposalVotingDetails(PROPOSAL_ID);
      await time.increaseTo(proposalDetails.votingEndTimestamp + 1n);

      void expect(await specificStrategy.isPassed(PROPOSAL_ID)).to.be.false;
    });

    it('should return false if basis is met but quorum is not, after voting period', async () => {
      const specificStrategy = await deployStrategyProxy(
        proposerInitializer.address,
        DEFAULT_VOTING_PERIOD,
        100n, // quorumThreshold
        500_001n, // basisNumerator (yes > no)
        defaultInitialVotingAdapters,
        defaultInitialProposerAdapters,
        lightAccountFactoryMockAddress,
      );
      await specificStrategy
        .connect(proposerInitializer)
        .initializeProposal(PROPOSAL_ID, [], ethers.ZeroHash);

      await mockAdapter1.setWeight(voter1.address, 60n); // YES
      await mockAdapter1.setWeight(voter2.address, 10n); // NO

      await specificStrategy
        .connect(voter1)
        .vote(PROPOSAL_ID, 1 /* YES */, [await mockAdapter1.getAddress()], [ethers.ZeroHash]);
      await specificStrategy
        .connect(voter2)
        .vote(PROPOSAL_ID, 0 /* NO */, [await mockAdapter1.getAddress()], [ethers.ZeroHash]);

      const proposalDetails = await specificStrategy.proposalVotingDetails(PROPOSAL_ID);
      await time.increaseTo(proposalDetails.votingEndTimestamp + 1n);

      void expect(await specificStrategy.isPassed(PROPOSAL_ID)).to.be.false;
    });
  });

  describe('ERC165 Supports Interface', () => {
    it('Should support IStrategyV1 interface', async () => {
      void expect(
        await strategy.supportsInterface(
          calculateInterfaceId(IStrategyV1__factory.createInterface()),
        ),
      ).to.be.true;
    });

    it('Should support IERC4337VoterSupportV1 interface', async () => {
      void expect(
        await strategy.supportsInterface(
          calculateInterfaceId(IERC4337VoterSupportV1__factory.createInterface()),
        ),
      ).to.be.true;
    });

    it('Should support ISmartAccountValidationV1 interface', async () => {
      void expect(
        await strategy.supportsInterface(
          calculateInterfaceId(ISmartAccountValidationV1__factory.createInterface()),
        ),
      ).to.be.true;
    });

    it('Should support IERC165 interface', async () => {
      void expect(
        await strategy.supportsInterface(calculateInterfaceId(IERC165__factory.createInterface())),
      ).to.be.true;
    });

    it('Should support IVersion interface', async () => {
      void expect(
        await strategy.supportsInterface(calculateInterfaceId(IVersion__factory.createInterface())),
      ).to.be.true;
    });

    it('Should not support a random interface', async () => {
      const randomInterfaceId = '0x12345678';
      void expect(await strategy.supportsInterface(randomInterfaceId)).to.be.false;
    });
  });

  describe('Version', () => {
    it('should return the correct version', async () => {
      void expect(await strategy.version()).to.equal(1);
    });
  });

  describe('Quorum and Basis Checks', () => {
    const PROPOSAL_ID = 1;

    beforeEach(async () => {
      await strategy
        .connect(proposerInitializer)
        .initializeProposal(PROPOSAL_ID, [], ethers.ZeroHash);
    });

    describe('isQuorumMet', () => {
      it('should revert if proposal not initialized', async () => {
        await expect(strategy.isQuorumMet(999)).to.be.revertedWithCustomError(
          strategy,
          'ProposalNotInitialized',
        );
      });

      it('should return true if quorum is met exactly (yes + abstain == threshold)', async () => {
        const testQuorum = 100n;
        const qStrategy = await deployStrategyProxy(
          proposerInitializer.address,
          DEFAULT_VOTING_PERIOD,
          testQuorum,
          DEFAULT_BASIS_NUMERATOR,
          defaultInitialVotingAdapters,
          defaultInitialProposerAdapters,
          lightAccountFactoryMockAddress,
        );
        await qStrategy
          .connect(proposerInitializer)
          .initializeProposal(PROPOSAL_ID, [], ethers.ZeroHash);

        await mockAdapter1.setWeight(voter1.address, 60n);
        await mockAdapter1.setWeight(voter2.address, 40n);
        await qStrategy
          .connect(voter1)
          .vote(PROPOSAL_ID, 1 /* YES */, [await mockAdapter1.getAddress()], [ethers.ZeroHash]);
        await qStrategy
          .connect(voter2)
          .vote(PROPOSAL_ID, 2 /* ABSTAIN */, [await mockAdapter1.getAddress()], [ethers.ZeroHash]);
        void expect(await qStrategy.isQuorumMet(PROPOSAL_ID)).to.be.true;
      });

      it('should return true if quorum is exceeded (yes + abstain > threshold)', async () => {
        const testQuorum = 100n;
        const qStrategy = await deployStrategyProxy(
          proposerInitializer.address,
          DEFAULT_VOTING_PERIOD,
          testQuorum,
          DEFAULT_BASIS_NUMERATOR,
          defaultInitialVotingAdapters,
          defaultInitialProposerAdapters,
          lightAccountFactoryMockAddress,
        );
        await qStrategy
          .connect(proposerInitializer)
          .initializeProposal(PROPOSAL_ID, [], ethers.ZeroHash);

        await mockAdapter1.setWeight(voter1.address, 60n);
        await mockAdapter1.setWeight(voter2.address, 41n); // Exceeds
        await qStrategy
          .connect(voter1)
          .vote(PROPOSAL_ID, 1 /* YES */, [await mockAdapter1.getAddress()], [ethers.ZeroHash]);
        await qStrategy
          .connect(voter2)
          .vote(PROPOSAL_ID, 2 /* ABSTAIN */, [await mockAdapter1.getAddress()], [ethers.ZeroHash]);
        void expect(await qStrategy.isQuorumMet(PROPOSAL_ID)).to.be.true;
      });

      it('should return false if quorum is not met (yes + abstain < threshold)', async () => {
        const testQuorum = 100n;
        const qStrategy = await deployStrategyProxy(
          proposerInitializer.address,
          DEFAULT_VOTING_PERIOD,
          testQuorum,
          DEFAULT_BASIS_NUMERATOR,
          defaultInitialVotingAdapters,
          defaultInitialProposerAdapters,
          lightAccountFactoryMockAddress,
        );
        await qStrategy
          .connect(proposerInitializer)
          .initializeProposal(PROPOSAL_ID, [], ethers.ZeroHash);

        await mockAdapter1.setWeight(voter1.address, 50n);
        await mockAdapter1.setWeight(voter2.address, 40n); // 90 total, < 100
        await qStrategy
          .connect(voter1)
          .vote(PROPOSAL_ID, 1 /* YES */, [await mockAdapter1.getAddress()], [ethers.ZeroHash]);
        await qStrategy
          .connect(voter2)
          .vote(PROPOSAL_ID, 2 /* ABSTAIN */, [await mockAdapter1.getAddress()], [ethers.ZeroHash]);

        void expect(await qStrategy.isQuorumMet(PROPOSAL_ID)).to.be.false;
      });

      it('should return true if quorum threshold is 0, even with no votes contributing to quorum count', async () => {
        const qStrategy = await deployStrategyProxy(
          proposerInitializer.address,
          DEFAULT_VOTING_PERIOD,
          0n /* quorum */,
          DEFAULT_BASIS_NUMERATOR,
          defaultInitialVotingAdapters,
          defaultInitialProposerAdapters,
          lightAccountFactoryMockAddress,
        );
        await qStrategy
          .connect(proposerInitializer)
          .initializeProposal(PROPOSAL_ID, [], ethers.ZeroHash);

        await mockAdapter1.setWeight(voter1.address, 10n); // Only NO votes
        await qStrategy
          .connect(voter1)
          .vote(PROPOSAL_ID, 0 /* NO */, [await mockAdapter1.getAddress()], [ethers.ZeroHash]);

        void expect(await qStrategy.isQuorumMet(PROPOSAL_ID)).to.be.true;
      });

      it('should return false if only NO votes are cast and quorum threshold > 0', async () => {
        await mockAdapter1.setWeight(voter1.address, 150n);
        await strategy
          .connect(voter1)
          .vote(PROPOSAL_ID, 0 /* NO */, [await mockAdapter1.getAddress()], [ethers.ZeroHash]);
        void expect(await strategy.isQuorumMet(PROPOSAL_ID)).to.be.false;
      });
    });

    describe('isBasisMet', () => {
      it('should revert if proposal not initialized', async () => {
        await expect(strategy.isBasisMet(999)).to.be.revertedWithCustomError(
          strategy,
          'ProposalNotInitialized',
        );
      });

      it('should return true if basis is met (yes > no for >50% basis)', async () => {
        await mockAdapter1.setWeight(voter1.address, 101n);
        await mockAdapter1.setWeight(voter2.address, 100n);
        await strategy
          .connect(voter1)
          .vote(PROPOSAL_ID, 1 /* YES */, [await mockAdapter1.getAddress()], [ethers.ZeroHash]);
        await strategy
          .connect(voter2)
          .vote(PROPOSAL_ID, 0 /* NO */, [await mockAdapter1.getAddress()], [ethers.ZeroHash]);
        void expect(await strategy.isBasisMet(PROPOSAL_ID)).to.be.true;
      });

      it('should return false if basis is not met (yes == no for >50% basis)', async () => {
        await mockAdapter1.setWeight(voter1.address, 100n);
        await mockAdapter1.setWeight(voter2.address, 100n);
        await strategy
          .connect(voter1)
          .vote(PROPOSAL_ID, 1 /* YES */, [await mockAdapter1.getAddress()], [ethers.ZeroHash]);
        await strategy
          .connect(voter2)
          .vote(PROPOSAL_ID, 0 /* NO */, [await mockAdapter1.getAddress()], [ethers.ZeroHash]);
        void expect(await strategy.isBasisMet(PROPOSAL_ID)).to.be.false;
      });

      it('should return false if basis is not met (yes < no for >50% basis)', async () => {
        await mockAdapter1.setWeight(voter1.address, 99n);
        await mockAdapter1.setWeight(voter2.address, 100n);
        await strategy
          .connect(voter1)
          .vote(PROPOSAL_ID, 1 /* YES */, [await mockAdapter1.getAddress()], [ethers.ZeroHash]);
        await strategy
          .connect(voter2)
          .vote(PROPOSAL_ID, 0 /* NO */, [await mockAdapter1.getAddress()], [ethers.ZeroHash]);
        void expect(await strategy.isBasisMet(PROPOSAL_ID)).to.be.false;
      });

      it('should return false if totalYesAndNoVotes is 0 (only abstain)', async () => {
        await mockAdapter1.setWeight(voter1.address, 100n);
        await strategy
          .connect(voter1)
          .vote(PROPOSAL_ID, 2 /* ABSTAIN */, [await mockAdapter1.getAddress()], [ethers.ZeroHash]);
        void expect(await strategy.isBasisMet(PROPOSAL_ID)).to.be.false;
      });

      it('should return true if basisNumerator is 500,000 (50%) and yes > no', async () => {
        const bStrategy = await deployStrategyProxy(
          proposerInitializer.address,
          DEFAULT_VOTING_PERIOD,
          DEFAULT_QUORUM_THRESHOLD,
          500_000n /* basis */,
          defaultInitialVotingAdapters,
          defaultInitialProposerAdapters,
          lightAccountFactoryMockAddress,
        );
        await bStrategy
          .connect(proposerInitializer)
          .initializeProposal(PROPOSAL_ID, [], ethers.ZeroHash);

        await mockAdapter1.setWeight(voter1.address, 101n);
        await mockAdapter1.setWeight(voter2.address, 100n);
        await bStrategy
          .connect(voter1)
          .vote(PROPOSAL_ID, 1 /* YES */, [await mockAdapter1.getAddress()], [ethers.ZeroHash]);
        await bStrategy
          .connect(voter2)
          .vote(PROPOSAL_ID, 0 /* NO */, [await mockAdapter1.getAddress()], [ethers.ZeroHash]);
        void expect(await bStrategy.isBasisMet(PROPOSAL_ID)).to.be.true;
      });

      it('should return false if basisNumerator is 500,000 (50%) and yes == no', async () => {
        const bStrategy = await deployStrategyProxy(
          proposerInitializer.address,
          DEFAULT_VOTING_PERIOD,
          DEFAULT_QUORUM_THRESHOLD,
          500_000n /* basis */,
          defaultInitialVotingAdapters,
          defaultInitialProposerAdapters,
          lightAccountFactoryMockAddress,
        );
        await bStrategy
          .connect(proposerInitializer)
          .initializeProposal(PROPOSAL_ID, [], ethers.ZeroHash);

        await mockAdapter1.setWeight(voter1.address, 100n);
        await mockAdapter1.setWeight(voter2.address, 100n);
        await bStrategy
          .connect(voter1)
          .vote(PROPOSAL_ID, 1 /* YES */, [await mockAdapter1.getAddress()], [ethers.ZeroHash]);
        await bStrategy
          .connect(voter2)
          .vote(PROPOSAL_ID, 0 /* NO */, [await mockAdapter1.getAddress()], [ethers.ZeroHash]);
        void expect(await bStrategy.isBasisMet(PROPOSAL_ID)).to.be.false;
      });

      it('should return true if basisNumerator is max valid (DENOMINATOR - 1) and yes > 0, no == 0', async () => {
        const maxValidBasis = 1_000_000n - 1n;
        const bStrategy = await deployStrategyProxy(
          proposerInitializer.address,
          DEFAULT_VOTING_PERIOD,
          DEFAULT_QUORUM_THRESHOLD,
          maxValidBasis,
          defaultInitialVotingAdapters,
          defaultInitialProposerAdapters,
          lightAccountFactoryMockAddress,
        );
        await bStrategy
          .connect(proposerInitializer)
          .initializeProposal(PROPOSAL_ID, [], ethers.ZeroHash);

        await mockAdapter1.setWeight(voter1.address, 100n);
        await bStrategy
          .connect(voter1)
          .vote(PROPOSAL_ID, 1 /* YES */, [await mockAdapter1.getAddress()], [ethers.ZeroHash]);
        void expect(await bStrategy.isBasisMet(PROPOSAL_ID)).to.be.true;
      });

      it('should return false if basisNumerator is max valid (DENOMINATOR - 1) and yes > 0, no > 0', async () => {
        const maxValidBasis = 1_000_000n - 1n;
        const bStrategy = await deployStrategyProxy(
          proposerInitializer.address,
          DEFAULT_VOTING_PERIOD,
          DEFAULT_QUORUM_THRESHOLD,
          maxValidBasis,
          defaultInitialVotingAdapters,
          defaultInitialProposerAdapters,
          lightAccountFactoryMockAddress,
        );
        await bStrategy
          .connect(proposerInitializer)
          .initializeProposal(PROPOSAL_ID, [], ethers.ZeroHash);

        await mockAdapter1.setWeight(voter1.address, 100n);
        await mockAdapter1.setWeight(voter2.address, 1n);
        await bStrategy
          .connect(voter1)
          .vote(PROPOSAL_ID, 1 /* YES */, [await mockAdapter1.getAddress()], [ethers.ZeroHash]);
        await bStrategy
          .connect(voter2)
          .vote(PROPOSAL_ID, 0 /* NO */, [await mockAdapter1.getAddress()], [ethers.ZeroHash]);

        void expect(await bStrategy.isBasisMet(PROPOSAL_ID)).to.be.false;
      });
    });
  });
});
