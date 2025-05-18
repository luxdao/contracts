import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { mine, time } from '@nomicfoundation/hardhat-network-helpers';
import { expect } from 'chai';
import type { BigNumberish } from 'ethers';
import { ethers } from 'hardhat';
import {
  ERC1967Proxy__factory,
  IBaseQuorumPercentV1__factory,
  IBaseStrategyV1__factory,
  IBaseVotingBasisPercentV1__factory,
  IERC165__factory,
  IVersion__factory,
  LinearERC20VotingV1,
  LinearERC20VotingV1__factory,
  MockERC20Votes,
  MockERC20Votes__factory,
  MockLightAccountFactory,
  MockLightAccountFactory__factory,
  MockOwnership,
  MockOwnership__factory,
} from '../../../typechain-types';
import { calculateInterfaceId } from '../../helpers/utils';
import { runUUPSUpgradeabilityTests } from '../../helpers/uupsUpgradeabilityTests';

describe('LinearERC20VotingV1', () => {
  // Signers
  let deployer: SignerWithAddress;
  let owner: SignerWithAddress;
  let nonOwner: SignerWithAddress;
  let proposalInitializer: SignerWithAddress;
  let tokenHolder1: SignerWithAddress;
  let tokenHolder2: SignerWithAddress;
  let tokenHolder3: SignerWithAddress;

  // Contracts
  let linearERC20VotingImplementation: LinearERC20VotingV1;
  let mockToken: MockERC20Votes;
  let lightAccountFactoryMock: MockLightAccountFactory;

  // Constants
  const VOTING_PERIOD = 100; // seconds
  const REQUIRED_PROPOSER_WEIGHT = 100; // 100 tokens to propose
  const QUORUM_NUMERATOR = 300000; // 30% of 1000000
  const BASIS_NUMERATOR = 500000; // 50% of 1000000
  const BASIS_DENOMINATOR = 1_000_000; // From contract

  enum ClockMode {
    Timestamp = 0,
    BlockNumber = 1,
  }

  enum VoteType {
    NO = 0,
    YES = 1,
    ABSTAIN = 2,
  }

  async function deployLinearERC20Voting(
    strategyOwner: SignerWithAddress,
    governanceTokenAddress: string,
    azoriusAddr: string,
    lightAccountFactoryAddress: string,
    customVotingPeriod: number = VOTING_PERIOD,
    customRequiredProposerWeight: BigNumberish = REQUIRED_PROPOSER_WEIGHT,
    customQuorumNumerator: number = QUORUM_NUMERATOR,
    customBasisNumerator: number = BASIS_NUMERATOR,
  ): Promise<LinearERC20VotingV1> {
    const initializeCalldata = LinearERC20VotingV1__factory.createInterface().encodeFunctionData(
      'initialize(address,address,address,uint32,uint256,uint256,uint256,address)',
      [
        strategyOwner.address,
        governanceTokenAddress,
        azoriusAddr,
        customVotingPeriod,
        customRequiredProposerWeight,
        customQuorumNumerator,
        customBasisNumerator,
        lightAccountFactoryAddress,
      ],
    );

    const proxy = await new ERC1967Proxy__factory(strategyOwner).deploy(
      await linearERC20VotingImplementation.getAddress(),
      initializeCalldata,
    );

    return LinearERC20VotingV1__factory.connect(await proxy.getAddress(), strategyOwner);
  }

  beforeEach(async () => {
    [deployer, owner, nonOwner, proposalInitializer, tokenHolder1, tokenHolder2, tokenHolder3] =
      await ethers.getSigners();

    mockToken = await new MockERC20Votes__factory(deployer).deploy();

    linearERC20VotingImplementation = await new LinearERC20VotingV1__factory(deployer).deploy();

    // Deploy the MockLightAccountFactory
    lightAccountFactoryMock = await new MockLightAccountFactory__factory(deployer).deploy();
  });

  describe('ERC165', function () {
    let linearERC20Voting: LinearERC20VotingV1;
    let iBaseStrategyV1InterfaceId: string;
    let iBaseQuorumPercentV1InterfaceId: string;
    let iBaseVotingBasisPercentV1InterfaceId: string;
    let iVersionInterfaceId: string;
    let iERC165InterfaceId: string;

    beforeEach(async function () {
      linearERC20Voting = await deployLinearERC20Voting(
        owner,
        await mockToken.getAddress(),
        proposalInitializer.address,
        lightAccountFactoryMock.target as string,
      );

      const IBaseQuorumPercentV1Interface = IBaseQuorumPercentV1__factory.createInterface();
      iBaseQuorumPercentV1InterfaceId = calculateInterfaceId(IBaseQuorumPercentV1Interface);

      const IBaseVotingBasisPercentV1Interface =
        IBaseVotingBasisPercentV1__factory.createInterface();
      iBaseVotingBasisPercentV1InterfaceId = calculateInterfaceId(
        IBaseVotingBasisPercentV1Interface,
      );

      const IBaseStrategyV1Interface = IBaseStrategyV1__factory.createInterface();
      iBaseStrategyV1InterfaceId = calculateInterfaceId(IBaseStrategyV1Interface);

      const IVersionInterface = IVersion__factory.createInterface();
      iVersionInterfaceId = calculateInterfaceId(IVersionInterface);

      const IERC165Interface = IERC165__factory.createInterface();
      iERC165InterfaceId = calculateInterfaceId(IERC165Interface);
    });

    it('Should support IERC165 interface', async function () {
      const supported = await linearERC20Voting.supportsInterface(iERC165InterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should support IBaseQuorumPercentV1 interface', async function () {
      const supported = await linearERC20Voting.supportsInterface(iBaseQuorumPercentV1InterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should support IBaseVotingBasisPercentV1 interface', async function () {
      const supported = await linearERC20Voting.supportsInterface(
        iBaseVotingBasisPercentV1InterfaceId,
      );
      void expect(supported).to.be.true;
    });

    it('Should support IBaseStrategyV1 interface', async function () {
      const supported = await linearERC20Voting.supportsInterface(iBaseStrategyV1InterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should support IVersion interface', async function () {
      const supported = await linearERC20Voting.supportsInterface(iVersionInterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should not support random interface', async function () {
      const randomInterfaceId = '0x12345678';
      const supported = await linearERC20Voting.supportsInterface(randomInterfaceId);
      void expect(supported).to.be.false;
    });
  });

  describe('UUPS Upgradeability', function () {
    let linearERC20Voting: LinearERC20VotingV1;

    beforeEach(async function () {
      linearERC20Voting = await deployLinearERC20Voting(
        owner,
        await mockToken.getAddress(),
        proposalInitializer.address,
        lightAccountFactoryMock.target as string,
      );
    });

    runUUPSUpgradeabilityTests({
      getContract: () => linearERC20Voting,
      createNewImplementation: async () => {
        const newImplementation = await new LinearERC20VotingV1__factory(owner).deploy();
        return newImplementation;
      },
      owner: () => owner,
      nonOwner: () => nonOwner,
    });
  });

  describe('Version', () => {
    let linearERC20Voting: LinearERC20VotingV1;

    beforeEach(async function () {
      linearERC20Voting = await deployLinearERC20Voting(
        owner,
        await mockToken.getAddress(),
        proposalInitializer.address,
        lightAccountFactoryMock.target as string,
      );
    });

    it('should return the correct version number', async () => {
      expect(await linearERC20Voting.getVersion()).to.equal(1);
    });
  });

  describe('initialization function', () => {
    it('should emit StrategySetUp event with correct parameters on successful initialization', async () => {
      const testOwner = owner;
      const testProposalInitializer = proposalInitializer;

      const initializeCalldata = LinearERC20VotingV1__factory.createInterface().encodeFunctionData(
        'initialize(address,address,address,uint32,uint256,uint256,uint256,address)',
        [
          testOwner.address,
          await mockToken.getAddress(),
          testProposalInitializer.address,
          VOTING_PERIOD,
          REQUIRED_PROPOSER_WEIGHT,
          QUORUM_NUMERATOR,
          BASIS_NUMERATOR,
          lightAccountFactoryMock.target as string,
        ],
      );

      const proxyFactory = new ERC1967Proxy__factory(testOwner);
      const proxy = await proxyFactory.deploy(
        await linearERC20VotingImplementation.getAddress(),
        initializeCalldata,
      );
      await proxy.waitForDeployment();

      const deploymentTx = proxy.deploymentTransaction();
      if (!deploymentTx) throw new Error('Deployment transaction not found for proxy');

      const proxyAsLinearVoting = LinearERC20VotingV1__factory.connect(
        await proxy.getAddress(),
        testOwner,
      );

      await expect(deploymentTx)
        .to.emit(proxyAsLinearVoting, 'StrategySetUp')
        .withArgs(testProposalInitializer.address, testOwner.address);
    });

    it('should initialize with correct parameters', async () => {
      const linearERC20Voting = await deployLinearERC20Voting(
        owner,
        await mockToken.getAddress(),
        proposalInitializer.address,
        lightAccountFactoryMock.target as string,
      );
      expect(await linearERC20Voting.owner()).to.equal(owner.address);
      expect(await linearERC20Voting.governanceToken()).to.equal(await mockToken.getAddress());
      expect(await linearERC20Voting.proposalInitializer()).to.equal(proposalInitializer.address);
      expect(await linearERC20Voting.votingPeriod()).to.equal(VOTING_PERIOD);
      expect(await linearERC20Voting.requiredProposerWeight()).to.equal(REQUIRED_PROPOSER_WEIGHT);
      expect(await linearERC20Voting.quorumNumerator()).to.equal(QUORUM_NUMERATOR);
      expect(await linearERC20Voting.basisNumerator()).to.equal(BASIS_NUMERATOR);
      expect(await linearERC20Voting.lightAccountFactory()).to.equal(
        lightAccountFactoryMock.target as string,
      );
      expect(await linearERC20Voting.governanceClockMode()).to.equal(ClockMode.Timestamp);
    });

    it('should initialize with block number clock mode when governance token has block number clock mode', async () => {
      await mockToken.setClockMode(ClockMode.BlockNumber);
      const newInstance = await deployLinearERC20Voting(
        owner,
        await mockToken.getAddress(),
        proposalInitializer.address,
        lightAccountFactoryMock.target as string,
      );
      expect(await newInstance.governanceClockMode()).to.equal(ClockMode.BlockNumber);
    });

    it('should not allow reinitialization', async () => {
      const linearERC20Voting = await deployLinearERC20Voting(
        owner,
        await mockToken.getAddress(),
        proposalInitializer.address,
        lightAccountFactoryMock.target as string,
      );
      await expect(
        linearERC20Voting[
          'initialize(address,address,address,uint32,uint256,uint256,uint256,address)'
        ](
          owner.address,
          await mockToken.getAddress(),
          proposalInitializer.address,
          VOTING_PERIOD,
          REQUIRED_PROPOSER_WEIGHT,
          QUORUM_NUMERATOR,
          BASIS_NUMERATOR,
          lightAccountFactoryMock.target as string,
        ),
      ).to.be.revertedWithCustomError(linearERC20Voting, 'InvalidInitialization');
    });

    it('should revert when initializing with zero token address', async () => {
      const initializeCalldata = LinearERC20VotingV1__factory.createInterface().encodeFunctionData(
        'initialize(address,address,address,uint32,uint256,uint256,uint256,address)',
        [
          owner.address,
          ethers.ZeroAddress,
          proposalInitializer.address,
          VOTING_PERIOD,
          REQUIRED_PROPOSER_WEIGHT,
          QUORUM_NUMERATOR,
          BASIS_NUMERATOR,
          lightAccountFactoryMock.target as string,
        ],
      );
      await expect(
        new ERC1967Proxy__factory(owner).deploy(
          await linearERC20VotingImplementation.getAddress(),
          initializeCalldata,
        ),
      ).to.be.revertedWithCustomError(linearERC20VotingImplementation, 'InvalidTokenAddress');
    });

    it('should revert if _quorumNumerator > 1_000_000 during initialization', async () => {
      const invalidQuorumNumerator = 1_000_001;
      await expect(
        deployLinearERC20Voting(
          owner,
          await mockToken.getAddress(),
          proposalInitializer.address,
          lightAccountFactoryMock.target as string,
          VOTING_PERIOD,
          REQUIRED_PROPOSER_WEIGHT,
          invalidQuorumNumerator,
          BASIS_NUMERATOR,
        ),
      ).to.be.revertedWithCustomError(linearERC20VotingImplementation, 'InvalidQuorumNumerator');
    });

    it('should revert if _basisNumerator > BASIS_DENOMINATOR during initialization', async () => {
      const invalidBasisNumerator = 1_000_001;
      await expect(
        deployLinearERC20Voting(
          owner,
          await mockToken.getAddress(),
          proposalInitializer.address,
          lightAccountFactoryMock.target as string,
          VOTING_PERIOD,
          REQUIRED_PROPOSER_WEIGHT,
          QUORUM_NUMERATOR,
          invalidBasisNumerator,
        ),
      ).to.be.revertedWithCustomError(linearERC20VotingImplementation, 'InvalidBasisNumerator');
    });

    it('should revert if _basisNumerator < BASIS_DENOMINATOR / 2 during initialization', async () => {
      const invalidBasisNumerator = BASIS_DENOMINATOR / 2 - 1;
      await expect(
        deployLinearERC20Voting(
          owner,
          await mockToken.getAddress(),
          proposalInitializer.address,
          lightAccountFactoryMock.target as string,
          VOTING_PERIOD,
          REQUIRED_PROPOSER_WEIGHT,
          QUORUM_NUMERATOR,
          invalidBasisNumerator,
        ),
      ).to.be.revertedWithCustomError(linearERC20VotingImplementation, 'InvalidBasisNumerator');
    });

    it('should allow _basisNumerator to be BASIS_DENOMINATOR / 2 during initialization', async () => {
      const validBasisNumerator = BASIS_DENOMINATOR / 2;
      const instance = await deployLinearERC20Voting(
        owner,
        await mockToken.getAddress(),
        proposalInitializer.address,
        lightAccountFactoryMock.target as string,
        VOTING_PERIOD,
        REQUIRED_PROPOSER_WEIGHT,
        QUORUM_NUMERATOR,
        validBasisNumerator,
      );
      expect(await instance.basisNumerator()).to.equal(validBasisNumerator);
    });

    it('should allow _basisNumerator to be BASIS_DENOMINATOR during initialization', async () => {
      const validBasisNumerator = BASIS_DENOMINATOR;
      const instance = await deployLinearERC20Voting(
        owner,
        await mockToken.getAddress(),
        proposalInitializer.address,
        lightAccountFactoryMock.target as string,
        VOTING_PERIOD,
        REQUIRED_PROPOSER_WEIGHT,
        QUORUM_NUMERATOR,
        validBasisNumerator,
      );
      expect(await instance.basisNumerator()).to.equal(validBasisNumerator);
    });

    it('should allow _quorumNumerator to be 0 during initialization', async () => {
      const validQuorumNumerator = 0;
      const instance = await deployLinearERC20Voting(
        owner,
        await mockToken.getAddress(),
        proposalInitializer.address,
        lightAccountFactoryMock.target as string,
        VOTING_PERIOD,
        REQUIRED_PROPOSER_WEIGHT,
        validQuorumNumerator,
        BASIS_NUMERATOR,
      );
      expect(await instance.quorumNumerator()).to.equal(validQuorumNumerator);
    });

    it('should allow _quorumNumerator to be 1_000_000 during initialization', async () => {
      const validQuorumNumerator = 1_000_000;
      const instance = await deployLinearERC20Voting(
        owner,
        await mockToken.getAddress(),
        proposalInitializer.address,
        lightAccountFactoryMock.target as string,
        VOTING_PERIOD,
        REQUIRED_PROPOSER_WEIGHT,
        validQuorumNumerator,
        BASIS_NUMERATOR,
      );
      expect(await instance.quorumNumerator()).to.equal(validQuorumNumerator);
    });
  });

  describe('updateVotingPeriod function', () => {
    let linearERC20Voting: LinearERC20VotingV1;

    beforeEach(async () => {
      linearERC20Voting = await deployLinearERC20Voting(
        owner, // contract owner
        await mockToken.getAddress(),
        proposalInitializer.address,
        lightAccountFactoryMock.target as string,
      );
    });

    it('should allow the owner to update the voting period and emit VotingPeriodUpdated event', async () => {
      const newVotingPeriod = VOTING_PERIOD + 100;
      await expect(linearERC20Voting.connect(owner).updateVotingPeriod(newVotingPeriod))
        .to.emit(linearERC20Voting, 'VotingPeriodUpdated')
        .withArgs(newVotingPeriod);
      expect(await linearERC20Voting.votingPeriod()).to.equal(newVotingPeriod);
    });

    it('should not allow a non-owner to update the voting period', async () => {
      const newVotingPeriod = VOTING_PERIOD + 100;
      await expect(
        linearERC20Voting.connect(nonOwner).updateVotingPeriod(newVotingPeriod),
      ).to.be.revertedWithCustomError(linearERC20Voting, 'OwnableUnauthorizedAccount');
    });
  });

  describe('updateRequiredProposerWeight function', () => {
    let linearERC20Voting: LinearERC20VotingV1;

    beforeEach(async () => {
      linearERC20Voting = await deployLinearERC20Voting(
        owner,
        await mockToken.getAddress(),
        proposalInitializer.address,
        lightAccountFactoryMock.target as string,
      );
    });

    it('should allow the owner to update the required proposer weight and emit RequiredProposerWeightUpdated event', async () => {
      const newWeight = REQUIRED_PROPOSER_WEIGHT + 100;
      await expect(linearERC20Voting.connect(owner).updateRequiredProposerWeight(newWeight))
        .to.emit(linearERC20Voting, 'RequiredProposerWeightUpdated')
        .withArgs(newWeight);
      expect(await linearERC20Voting.requiredProposerWeight()).to.equal(newWeight);
    });

    it('should not allow a non-owner to update the required proposer weight', async () => {
      const newWeight = REQUIRED_PROPOSER_WEIGHT + 100;
      await expect(
        linearERC20Voting.connect(nonOwner).updateRequiredProposerWeight(newWeight),
      ).to.be.revertedWithCustomError(linearERC20Voting, 'OwnableUnauthorizedAccount');
    });
  });

  describe('updateQuorumNumerator function', () => {
    let linearERC20Voting: LinearERC20VotingV1;
    const QUORUM_DENOMINATOR_FROM_CONTRACT = 1_000_000; // Matching contract constant

    beforeEach(async () => {
      linearERC20Voting = await deployLinearERC20Voting(
        owner,
        await mockToken.getAddress(),
        proposalInitializer.address,
        lightAccountFactoryMock.target as string,
      );
    });

    it('should allow the owner to update the quorum numerator and emit QuorumNumeratorUpdated event', async () => {
      const newQuorumNumerator = QUORUM_NUMERATOR + 10000; // e.g., 31%
      await expect(linearERC20Voting.connect(owner).updateQuorumNumerator(newQuorumNumerator))
        .to.emit(linearERC20Voting, 'QuorumNumeratorUpdated')
        .withArgs(newQuorumNumerator);
      expect(await linearERC20Voting.quorumNumerator()).to.equal(newQuorumNumerator);
    });

    it('should not allow a non-owner to update the quorum numerator', async () => {
      const newQuorumNumerator = QUORUM_NUMERATOR + 10000;
      await expect(
        linearERC20Voting.connect(nonOwner).updateQuorumNumerator(newQuorumNumerator),
      ).to.be.revertedWithCustomError(linearERC20Voting, 'OwnableUnauthorizedAccount');
    });

    it('should revert if quorumNumerator is greater than QUORUM_DENOMINATOR', async () => {
      const invalidQuorumNumerator = QUORUM_DENOMINATOR_FROM_CONTRACT + 1;
      await expect(
        linearERC20Voting.connect(owner).updateQuorumNumerator(invalidQuorumNumerator),
      ).to.be.revertedWithCustomError(linearERC20Voting, 'InvalidQuorumNumerator');
    });

    it('should allow quorumNumerator to be 0', async () => {
      const zeroQuorumNumerator = 0;
      await expect(linearERC20Voting.connect(owner).updateQuorumNumerator(zeroQuorumNumerator))
        .to.emit(linearERC20Voting, 'QuorumNumeratorUpdated')
        .withArgs(zeroQuorumNumerator);
      expect(await linearERC20Voting.quorumNumerator()).to.equal(zeroQuorumNumerator);
    });

    it('should allow quorumNumerator to be equal to QUORUM_DENOMINATOR', async () => {
      const fullQuorumNumerator = QUORUM_DENOMINATOR_FROM_CONTRACT;
      await expect(linearERC20Voting.connect(owner).updateQuorumNumerator(fullQuorumNumerator))
        .to.emit(linearERC20Voting, 'QuorumNumeratorUpdated')
        .withArgs(fullQuorumNumerator);
      expect(await linearERC20Voting.quorumNumerator()).to.equal(fullQuorumNumerator);
    });
  });

  describe('updateBasisNumerator function', () => {
    let linearERC20Voting: LinearERC20VotingV1;
    // BASIS_DENOMINATOR is already defined at the top level of the describe block

    beforeEach(async () => {
      linearERC20Voting = await deployLinearERC20Voting(
        owner,
        await mockToken.getAddress(),
        proposalInitializer.address,
        lightAccountFactoryMock.target as string,
      );
    });

    it('should allow the owner to update the basis numerator and emit BasisNumeratorUpdated event', async () => {
      const newBasisNumerator = BASIS_NUMERATOR + 10000; // e.g., 51%
      await expect(linearERC20Voting.connect(owner).updateBasisNumerator(newBasisNumerator))
        .to.emit(linearERC20Voting, 'BasisNumeratorUpdated')
        .withArgs(newBasisNumerator);
      expect(await linearERC20Voting.basisNumerator()).to.equal(newBasisNumerator);
    });

    it('should not allow a non-owner to update the basis numerator', async () => {
      const newBasisNumerator = BASIS_NUMERATOR + 10000;
      await expect(
        linearERC20Voting.connect(nonOwner).updateBasisNumerator(newBasisNumerator),
      ).to.be.revertedWithCustomError(linearERC20Voting, 'OwnableUnauthorizedAccount');
    });

    it('should revert if basisNumerator is greater than BASIS_DENOMINATOR', async () => {
      const invalidBasisNumerator = BASIS_DENOMINATOR + 1;
      await expect(
        linearERC20Voting.connect(owner).updateBasisNumerator(invalidBasisNumerator),
      ).to.be.revertedWithCustomError(linearERC20Voting, 'InvalidBasisNumerator');
    });

    it('should revert if basisNumerator is less than BASIS_DENOMINATOR / 2', async () => {
      const invalidBasisNumerator = BASIS_DENOMINATOR / 2 - 1;
      await expect(
        linearERC20Voting.connect(owner).updateBasisNumerator(invalidBasisNumerator),
      ).to.be.revertedWithCustomError(linearERC20Voting, 'InvalidBasisNumerator');
    });

    it('should allow basisNumerator to be equal to BASIS_DENOMINATOR / 2', async () => {
      const halfBasisNumerator = BASIS_DENOMINATOR / 2;
      await expect(linearERC20Voting.connect(owner).updateBasisNumerator(halfBasisNumerator))
        .to.emit(linearERC20Voting, 'BasisNumeratorUpdated')
        .withArgs(halfBasisNumerator);
      expect(await linearERC20Voting.basisNumerator()).to.equal(halfBasisNumerator);
    });

    it('should allow basisNumerator to be equal to BASIS_DENOMINATOR', async () => {
      const fullBasisNumerator = BASIS_DENOMINATOR;
      await expect(linearERC20Voting.connect(owner).updateBasisNumerator(fullBasisNumerator))
        .to.emit(linearERC20Voting, 'BasisNumeratorUpdated')
        .withArgs(fullBasisNumerator);
      expect(await linearERC20Voting.basisNumerator()).to.equal(fullBasisNumerator);
    });
  });

  describe('vote function', () => {
    let linearERC20Voting: LinearERC20VotingV1;
    const PROPOSAL_ID = 1;
    const DEFAULT_VOTING_WEIGHT = ethers.parseUnits('1000', 18);

    async function initializeProposalForVoting(proposalId: number) {
      const initializeData = ethers.AbiCoder.defaultAbiCoder().encode(['uint32'], [proposalId]);
      // Use the proposalInitializer account (mock Azorius) to initialize
      await linearERC20Voting.connect(proposalInitializer).initializeProposal(initializeData);
    }

    beforeEach(async () => {
      linearERC20Voting = await deployLinearERC20Voting(
        owner,
        await mockToken.getAddress(),
        proposalInitializer.address,
        lightAccountFactoryMock.target as string,
      );

      // Mint tokens and delegate for each token holder
      for (const holder of [tokenHolder1, tokenHolder2, tokenHolder3]) {
        await mockToken.mint(holder.address, DEFAULT_VOTING_WEIGHT);
        await mockToken.connect(holder).delegate(holder.address);
      }
    });

    it('should revert when voting on an uninitialized proposal (InvalidProposal)', async () => {
      const nonExistentProposalId = 999;
      await expect(
        linearERC20Voting.connect(tokenHolder1).vote(nonExistentProposalId, VoteType.YES),
      ).to.be.revertedWithCustomError(linearERC20Voting, 'InvalidProposal');
    });

    describe('when voting period has ended', () => {
      let endTimestamp: bigint;

      beforeEach(async () => {
        await initializeProposalForVoting(PROPOSAL_ID);
        const [, , , , , propEndTimestamp] = await linearERC20Voting.getProposalVotes(PROPOSAL_ID);
        endTimestamp = propEndTimestamp;
        // Advance time to just after the voting period ends
        await time.increaseTo(Number(endTimestamp) + 1);
      });

      it('should handle the first vote after period ends: emit VotingPeriodEnded, not count vote, not mark as voted (return early)', async () => {
        const tx = await linearERC20Voting.connect(tokenHolder1).vote(PROPOSAL_ID, VoteType.YES);
        const receipt = await tx.wait();
        if (!receipt) throw new Error('Transaction receipt not found');

        const block = await ethers.provider.getBlock(receipt.blockNumber);
        if (!block) throw new Error('Block not found for receipt');
        const actualBlockTimestamp = block.timestamp;

        await expect(tx)
          .to.emit(linearERC20Voting, 'VotingPeriodEnded')
          .withArgs(PROPOSAL_ID, endTimestamp, actualBlockTimestamp);

        // Verify vote was not counted
        const [noVotes, yesVotes, abstainVotes, , ,] =
          await linearERC20Voting.getProposalVotes(PROPOSAL_ID);
        expect(yesVotes).to.equal(0);
        expect(noVotes).to.equal(0);
        expect(abstainVotes).to.equal(0);

        // Verify not marked as voted
        void expect(await linearERC20Voting.hasVoted(PROPOSAL_ID, tokenHolder1.address)).to.be
          .false;
        // Verify _votingPeriodEnded internal flag is set
        void expect(await linearERC20Voting.votingPeriodEnded(PROPOSAL_ID)).to.be.true;
      });

      it('should revert on subsequent votes after period is marked ended (VotingEnded)', async () => {
        // First vote marks it as ended
        await linearERC20Voting.connect(tokenHolder1).vote(PROPOSAL_ID, VoteType.YES);

        // Subsequent vote
        await expect(
          linearERC20Voting.connect(tokenHolder2).vote(PROPOSAL_ID, VoteType.NO),
        ).to.be.revertedWithCustomError(linearERC20Voting, 'VotingEnded');
      });
    });

    it('should revert when voting twice on the same proposal (AlreadyVoted)', async () => {
      await initializeProposalForVoting(PROPOSAL_ID);
      await linearERC20Voting.connect(tokenHolder1).vote(PROPOSAL_ID, VoteType.YES);
      await expect(
        linearERC20Voting.connect(tokenHolder1).vote(PROPOSAL_ID, VoteType.NO),
      ).to.be.revertedWithCustomError(linearERC20Voting, 'AlreadyVoted');
    });

    it('should revert when voting with an invalid _voteType (InvalidVote)', async () => {
      await initializeProposalForVoting(PROPOSAL_ID);
      const invalidVoteType = 3;
      await expect(
        linearERC20Voting.connect(tokenHolder1).vote(PROPOSAL_ID, invalidVoteType as VoteType),
      ).to.be.revertedWithCustomError(linearERC20Voting, 'InvalidVote');
    });

    // Tests for successful votes (YES, NO, ABSTAIN)
    describe('when a vote is cast successfully', () => {
      beforeEach(async () => {
        // Ensure a proposal is initialized before each successful vote test
        await initializeProposalForVoting(PROPOSAL_ID);
      });

      it('should correctly record a YES vote, emit Voted event, and update hasVoted status', async () => {
        const voter = tokenHolder1;
        const expectedWeight = await linearERC20Voting.getVotingWeight(voter.address, PROPOSAL_ID);
        expect(expectedWeight).to.equal(DEFAULT_VOTING_WEIGHT); // Sanity check weight

        await expect(linearERC20Voting.connect(voter).vote(PROPOSAL_ID, VoteType.YES))
          .to.emit(linearERC20Voting, 'Voted')
          .withArgs(voter.address, PROPOSAL_ID, VoteType.YES, expectedWeight);

        const [noVotes, yesVotes, abstainVotes, , ,] =
          await linearERC20Voting.getProposalVotes(PROPOSAL_ID);
        expect(yesVotes).to.equal(expectedWeight);
        expect(noVotes).to.equal(0);
        expect(abstainVotes).to.equal(0);
        void expect(await linearERC20Voting.hasVoted(PROPOSAL_ID, voter.address)).to.be.true;
      });

      it('should correctly record a NO vote, emit Voted event, and update hasVoted status', async () => {
        const voter = tokenHolder2;
        const expectedWeight = await linearERC20Voting.getVotingWeight(voter.address, PROPOSAL_ID);
        expect(expectedWeight).to.equal(DEFAULT_VOTING_WEIGHT); // Sanity check weight

        await expect(linearERC20Voting.connect(voter).vote(PROPOSAL_ID, VoteType.NO))
          .to.emit(linearERC20Voting, 'Voted')
          .withArgs(voter.address, PROPOSAL_ID, VoteType.NO, expectedWeight);

        const [noVotes, yesVotes, abstainVotes, , ,] =
          await linearERC20Voting.getProposalVotes(PROPOSAL_ID);
        expect(noVotes).to.equal(expectedWeight);
        expect(yesVotes).to.equal(0);
        expect(abstainVotes).to.equal(0);
        void expect(await linearERC20Voting.hasVoted(PROPOSAL_ID, voter.address)).to.be.true;
      });

      it('should correctly record an ABSTAIN vote, emit Voted event, and update hasVoted status', async () => {
        const voter = tokenHolder3;
        const expectedWeight = await linearERC20Voting.getVotingWeight(voter.address, PROPOSAL_ID);
        expect(expectedWeight).to.equal(DEFAULT_VOTING_WEIGHT); // Sanity check weight

        await expect(linearERC20Voting.connect(voter).vote(PROPOSAL_ID, VoteType.ABSTAIN))
          .to.emit(linearERC20Voting, 'Voted')
          .withArgs(voter.address, PROPOSAL_ID, VoteType.ABSTAIN, expectedWeight);

        const [noVotes, yesVotes, abstainVotes, , ,] =
          await linearERC20Voting.getProposalVotes(PROPOSAL_ID);
        expect(abstainVotes).to.equal(expectedWeight);
        expect(noVotes).to.equal(0);
        expect(yesVotes).to.equal(0);
        void expect(await linearERC20Voting.hasVoted(PROPOSAL_ID, voter.address)).to.be.true;
      });

      it('should use voting weight snapshotted at proposal creation (Timestamp mode)', async () => {
        const voter = tokenHolder1;
        // Initialize proposal for this specific test to get its unique start time
        const specificProposalId = PROPOSAL_ID + 100; // Ensure a fresh proposal ID
        await initializeProposalForVoting(specificProposalId);
        const [, , , propStartTimestamp, , ,] = // Read supply before explicit set for logging
          await linearERC20Voting.getProposalVotes(specificProposalId);

        // Explicitly set past votes and total supply for the proposal's start timestamp
        const currentTotalSupply = await mockToken.totalSupply();
        await mockToken.setPastVotes(voter.address, propStartTimestamp, DEFAULT_VOTING_WEIGHT);
        await mockToken.setPastTotalSupply(propStartTimestamp, currentTotalSupply);

        const initialWeight = await linearERC20Voting.getVotingWeight(
          voter.address,
          specificProposalId,
        );
        expect(initialWeight).to.equal(DEFAULT_VOTING_WEIGHT);

        // Mint more tokens to the voter *after* proposal initialization
        const extraTokens = ethers.parseUnits('500', 18);
        await mockToken.mint(voter.address, extraTokens);
        // Note: No need to re-delegate for ERC20Votes if already delegated to self for balance to be picked up by getVotes.
        // getPastVotes relies on checkpoints created by transfers/delegations.

        // Vote
        await linearERC20Voting.connect(voter).vote(specificProposalId, VoteType.YES);

        // Check that the vote used the initial weight, not the new total balance
        const [, yesVotes, , , ,] = await linearERC20Voting.getProposalVotes(specificProposalId);
        expect(yesVotes).to.equal(initialWeight); // Should still be DEFAULT_VOTING_WEIGHT
      });
    });

    describe('when governance token is in BlockNumber clock mode', () => {
      let blockNumberVotingStrategy: LinearERC20VotingV1;
      const VOTE_START_BLOCK_WEIGHT = ethers.parseUnits('700', 18);
      const LATER_BLOCK_WEIGHT = ethers.parseUnits('1200', 18);

      beforeEach(async () => {
        // Revert to using global mockToken and remove dedicated blockNumberMockToken logic
        await mockToken.setClockMode(ClockMode.BlockNumber);

        await mockToken.mint(tokenHolder1.address, VOTE_START_BLOCK_WEIGHT);
        await mockToken.connect(tokenHolder1).delegate(tokenHolder1.address);

        blockNumberVotingStrategy = await deployLinearERC20Voting(
          owner,
          await mockToken.getAddress(), // Use global mockToken
          proposalInitializer.address,
          lightAccountFactoryMock.target as string,
        );

        // Initialize a proposal. The startBlock will be captured here.
        const initializeData = ethers.AbiCoder.defaultAbiCoder().encode(['uint32'], [PROPOSAL_ID]);
        await blockNumberVotingStrategy
          .connect(proposalInitializer)
          .initializeProposal(initializeData);
        const [, , , , propStartBlock, ,] = // Read supply before explicit set for logging
          await blockNumberVotingStrategy.getProposalVotes(PROPOSAL_ID);

        // Explicitly set past votes and total supply for the proposal's start block
        const currentTotalSupply = await mockToken.totalSupply(); // Use global mockToken
        await mockToken.setPastVotes(
          // Use global mockToken
          tokenHolder1.address,
          propStartBlock,
          VOTE_START_BLOCK_WEIGHT,
        );
        await mockToken.setPastTotalSupply(propStartBlock, currentTotalSupply); // Use global mockToken

        const additionalTokens = LATER_BLOCK_WEIGHT - VOTE_START_BLOCK_WEIGHT;
        await mockToken.mint(tokenHolder1.address, additionalTokens); // Use global mockToken
      });

      it('should use voting weight snapshotted at proposal startBlock (BlockNumber mode)', async () => {
        const voter = tokenHolder1;

        const weightFromStrategy = await blockNumberVotingStrategy.getVotingWeight(
          voter.address,
          PROPOSAL_ID,
        );

        expect(weightFromStrategy).to.equal(VOTE_START_BLOCK_WEIGHT);
        await expect(blockNumberVotingStrategy.connect(voter).vote(PROPOSAL_ID, VoteType.YES))
          .to.emit(blockNumberVotingStrategy, 'Voted')
          .withArgs(voter.address, PROPOSAL_ID, VoteType.YES, VOTE_START_BLOCK_WEIGHT);

        const [, yesVotes, , , ,] = await blockNumberVotingStrategy.getProposalVotes(PROPOSAL_ID);
        expect(yesVotes).to.equal(VOTE_START_BLOCK_WEIGHT);
      });
    });

    describe('when voter is a smart contract (Ownable)', () => {
      let mockOwnershipInstance: MockOwnership;
      let contractVotingStrategy: LinearERC20VotingV1;
      let eoaOwnerOfMockOwnership: SignerWithAddress;
      let scTestMockToken: MockERC20Votes; // Isolated token for this suite
      const CONTRACT_VOTER_PROPOSAL_ID = 2;
      const EOA_OWNER_VOTE_WEIGHT = ethers.parseUnits('300', 18);

      beforeEach(async () => {
        eoaOwnerOfMockOwnership = tokenHolder1;

        // Deploy a new mock token for this test suite to avoid state interference
        scTestMockToken = await new MockERC20Votes__factory(deployer).deploy();

        mockOwnershipInstance = await new MockOwnership__factory(deployer).deploy(
          eoaOwnerOfMockOwnership.address,
        );
        await mockOwnershipInstance.waitForDeployment();

        // Configure the MockLightAccountFactory to return the mockOwnershipInstance address
        // when getAddress is called with eoaOwnerOfMockOwnership.address and salt 0.
        // Salt 0 is what SmartAccountValidationV1 uses.
        await lightAccountFactoryMock.setAccountAddress(
          eoaOwnerOfMockOwnership.address,
          0, // salt
          await mockOwnershipInstance.getAddress(),
        );

        contractVotingStrategy = await deployLinearERC20Voting(
          owner,
          await scTestMockToken.getAddress(),
          proposalInitializer.address,
          lightAccountFactoryMock.target as string,
        );

        await scTestMockToken.mint(eoaOwnerOfMockOwnership.address, EOA_OWNER_VOTE_WEIGHT);
        await scTestMockToken
          .connect(eoaOwnerOfMockOwnership)
          .delegate(eoaOwnerOfMockOwnership.address);

        const initializeData = ethers.AbiCoder.defaultAbiCoder().encode(
          ['uint32'],
          [CONTRACT_VOTER_PROPOSAL_ID],
        );
        await contractVotingStrategy
          .connect(proposalInitializer)
          .initializeProposal(initializeData);

        // Have the smart contract (MockOwnership) cast the vote
        await expect(
          mockOwnershipInstance
            .connect(eoaOwnerOfMockOwnership)
            .callExternalVote(
              await contractVotingStrategy.getAddress(),
              CONTRACT_VOTER_PROPOSAL_ID,
              VoteType.YES,
            ),
        )
          .to.emit(contractVotingStrategy, 'Voted')
          .withArgs(
            eoaOwnerOfMockOwnership.address,
            CONTRACT_VOTER_PROPOSAL_ID,
            VoteType.YES,
            EOA_OWNER_VOTE_WEIGHT,
          );
      });

      it("should correctly attribute vote to EOA owner of the contract and use EOA's weight", async () => {
        const mockOwnershipAddress = await mockOwnershipInstance.getAddress();

        const hasVotedEOA = await contractVotingStrategy.hasVoted(
          CONTRACT_VOTER_PROPOSAL_ID,
          eoaOwnerOfMockOwnership.address,
        );
        const hasVotedContract = await contractVotingStrategy.hasVoted(
          CONTRACT_VOTER_PROPOSAL_ID,
          mockOwnershipAddress,
        );

        void expect(hasVotedEOA).to.be.true;
        void expect(hasVotedContract).to.be.false;
      });
    });
  });

  describe('getProposalVotes function', () => {
    let linearERC20Voting: LinearERC20VotingV1;
    const PROPOSAL_ID = 3;
    const WEIGHT_1 = ethers.parseUnits('100', 18);
    const WEIGHT_2 = ethers.parseUnits('200', 18);
    const WEIGHT_3 = ethers.parseUnits('300', 18);

    beforeEach(async () => {
      // Ensure mockToken is in a known state (e.g., Timestamp mode) if using global
      await mockToken.setClockMode(ClockMode.Timestamp); // Explicitly set for these tests

      // Deploy a new instance for this test suite to avoid interference
      linearERC20Voting = await deployLinearERC20Voting(
        owner,
        await mockToken.getAddress(),
        proposalInitializer.address,
        lightAccountFactoryMock.target as string,
      );

      await mockToken.mint(tokenHolder1.address, WEIGHT_1);
      await mockToken.connect(tokenHolder1).delegate(tokenHolder1.address);

      await mockToken.mint(tokenHolder2.address, WEIGHT_2);
      await mockToken.connect(tokenHolder2).delegate(tokenHolder2.address);

      await mockToken.mint(tokenHolder3.address, WEIGHT_3);
      await mockToken.connect(tokenHolder3).delegate(tokenHolder3.address);
    });

    it('should return all zero values for an uninitialized proposal', async () => {
      const uninitializedProposalId = PROPOSAL_ID + 999;
      const [noVotes, yesVotes, abstainVotes, startTimestamp, startBlock, endTimestamp, ,] =
        await linearERC20Voting.getProposalVotes(uninitializedProposalId);

      expect(noVotes).to.equal(0);
      expect(yesVotes).to.equal(0);
      expect(abstainVotes).to.equal(0);
      expect(startTimestamp).to.equal(0);
      expect(startBlock).to.equal(0);
      expect(endTimestamp).to.equal(0);
      // For an uninitialized proposal, proposalVotes[id].startBlock/Timestamp is 0.
      // MockERC20Votes.getPastTotalSupply(0) without prior setPastTotalSupply(0, x)
      // will return current mockToken.totalSupply() due to its fallback.
      // This might be non-zero if tokens were minted. A stricter check might involve
      // ensuring the strategy *intends* for supply to be 0 for an uninitialized proposal.
      // However, the key is that timestamps/blocks are 0.
      // Let's set mock past total supply for 0 to 0 for a clean test of this case.
      await mockToken.setPastTotalSupply(0, 0);
      const [, , , , , , newVotingSupply] =
        await linearERC20Voting.getProposalVotes(uninitializedProposalId);
      expect(newVotingSupply).to.equal(0);
    });

    it('should return correct values for an initialized proposal, before any votes', async () => {
      const initializeData = ethers.AbiCoder.defaultAbiCoder().encode(['uint32'], [PROPOSAL_ID]);

      // Predict start block/timestamp. Actual values will be from the transaction receipt.
      const tx = await linearERC20Voting
        .connect(proposalInitializer)
        .initializeProposal(initializeData);
      const receipt = await tx.wait();
      if (!receipt) throw new Error('Transaction receipt not found for proposal initialization');

      const block = await ethers.provider.getBlock(receipt.blockNumber);
      if (!block) throw new Error('Block not found for receipt');

      const actualStartTimestamp = block.timestamp;
      const actualStartBlock = receipt.blockNumber;
      const expectedEndTimestamp = actualStartTimestamp + VOTING_PERIOD;

      // Set past total supply at the actual start block/timestamp
      // The mock will use timestamp or block based on its CLOCK_MODE setting
      const initialTotalSupply = await mockToken.totalSupply(); // Supply at time of initialization
      const timepointForSupply =
        (await mockToken.CLOCK_MODE()) === 'mode=timestamp'
          ? actualStartTimestamp
          : actualStartBlock;
      await mockToken.setPastTotalSupply(timepointForSupply, initialTotalSupply);

      const [
        noVotes,
        yesVotes,
        abstainVotes,
        startTimestamp,
        startBlock,
        endTimestamp,
        votingSupply,
      ] = await linearERC20Voting.getProposalVotes(PROPOSAL_ID);

      expect(noVotes).to.equal(0);
      expect(yesVotes).to.equal(0);
      expect(abstainVotes).to.equal(0);
      expect(startTimestamp).to.equal(actualStartTimestamp);
      expect(startBlock).to.equal(actualStartBlock);
      expect(endTimestamp).to.equal(expectedEndTimestamp);
      expect(votingSupply).to.equal(initialTotalSupply);
    });

    it('should return correct values for an initialized proposal, after some votes', async () => {
      const initializeData = ethers.AbiCoder.defaultAbiCoder().encode(['uint32'], [PROPOSAL_ID]);
      const initTx = await linearERC20Voting
        .connect(proposalInitializer)
        .initializeProposal(initializeData);
      const receipt = await initTx.wait();
      if (!receipt) throw new Error('Receipt not found');
      const block = await ethers.provider.getBlock(receipt.blockNumber);
      if (!block) throw new Error('Block not found');

      const proposalCreationTimestamp = block.timestamp;
      const proposalCreationBlock = receipt.blockNumber;
      const expectedEndTimestamp = proposalCreationTimestamp + VOTING_PERIOD;

      // Determine the correct timepoint for historical queries based on token's clock mode
      const tokenClockMode = await mockToken.CLOCK_MODE();
      const timepoint =
        tokenClockMode === 'mode=timestamp' ? proposalCreationTimestamp : proposalCreationBlock;

      // Set historical total supply
      const initialTotalSupply = await mockToken.totalSupply(); // Total supply just after proposal init
      await mockToken.setPastTotalSupply(timepoint, initialTotalSupply);

      // Set historical votes for each voter at the proposal creation timepoint
      // These are the weights that should be used for voting
      await mockToken.setPastVotes(tokenHolder1.address, timepoint, WEIGHT_1);
      await mockToken.setPastVotes(tokenHolder2.address, timepoint, WEIGHT_2);
      await mockToken.setPastVotes(tokenHolder3.address, timepoint, WEIGHT_3);

      // Cast votes
      await linearERC20Voting.connect(tokenHolder1).vote(PROPOSAL_ID, VoteType.YES);
      await linearERC20Voting.connect(tokenHolder2).vote(PROPOSAL_ID, VoteType.NO);
      await linearERC20Voting.connect(tokenHolder3).vote(PROPOSAL_ID, VoteType.ABSTAIN);

      const [
        noVotes,
        yesVotes,
        abstainVotes,
        startTimestamp,
        startBlock,
        endTimestamp,
        votingSupply,
      ] = await linearERC20Voting.getProposalVotes(PROPOSAL_ID);

      expect(yesVotes).to.equal(WEIGHT_1);
      expect(noVotes).to.equal(WEIGHT_2);
      expect(abstainVotes).to.equal(WEIGHT_3);
      expect(startTimestamp).to.equal(proposalCreationTimestamp);
      expect(startBlock).to.equal(proposalCreationBlock);
      expect(endTimestamp).to.equal(expectedEndTimestamp);
      expect(votingSupply).to.equal(initialTotalSupply);
    });

    it('should retrieve the same correct values after voting period has ended (no new votes)', async () => {
      const initializeData = ethers.AbiCoder.defaultAbiCoder().encode(['uint32'], [PROPOSAL_ID]);
      const initTx = await linearERC20Voting
        .connect(proposalInitializer)
        .initializeProposal(initializeData);
      const receipt = await initTx.wait();
      if (!receipt) throw new Error('Receipt not found');
      const block = await ethers.provider.getBlock(receipt.blockNumber);
      if (!block) throw new Error('Block not found');

      const proposalCreationTimestamp = block.timestamp;
      const proposalCreationBlock = receipt.blockNumber;
      const expectedEndTimestamp = proposalCreationTimestamp + VOTING_PERIOD;

      const tokenClockMode = await mockToken.CLOCK_MODE();
      const timepoint =
        tokenClockMode === 'mode=timestamp' ? proposalCreationTimestamp : proposalCreationBlock;

      const initialTotalSupply = await mockToken.totalSupply();
      await mockToken.setPastTotalSupply(timepoint, initialTotalSupply);

      await mockToken.setPastVotes(tokenHolder1.address, timepoint, WEIGHT_1);
      await mockToken.setPastVotes(tokenHolder2.address, timepoint, WEIGHT_2);
      await mockToken.setPastVotes(tokenHolder3.address, timepoint, WEIGHT_3);

      await linearERC20Voting.connect(tokenHolder1).vote(PROPOSAL_ID, VoteType.YES);
      await linearERC20Voting.connect(tokenHolder2).vote(PROPOSAL_ID, VoteType.NO);
      await linearERC20Voting.connect(tokenHolder3).vote(PROPOSAL_ID, VoteType.ABSTAIN);

      // Advance time past voting period
      await time.increaseTo(expectedEndTimestamp + 1);

      const [
        noVotes,
        yesVotes,
        abstainVotes,
        startTimestamp,
        startBlock,
        endTimestamp,
        votingSupply,
      ] = await linearERC20Voting.getProposalVotes(PROPOSAL_ID);

      expect(yesVotes).to.equal(WEIGHT_1);
      expect(noVotes).to.equal(WEIGHT_2);
      expect(abstainVotes).to.equal(WEIGHT_3);
      expect(startTimestamp).to.equal(proposalCreationTimestamp);
      expect(startBlock).to.equal(proposalCreationBlock);
      expect(endTimestamp).to.equal(expectedEndTimestamp);
      expect(votingSupply).to.equal(initialTotalSupply);
    });
  });

  describe('initializeProposal function', () => {
    let linearERC20Voting: LinearERC20VotingV1;
    const PROPOSAL_ID = 1; // A non-zero proposal ID
    let encodedProposalIdData: string;

    beforeEach(async () => {
      // Deploy with proposalInitializer as the one who can initialize proposals
      linearERC20Voting = await deployLinearERC20Voting(
        owner,
        await mockToken.getAddress(),
        proposalInitializer.address, // azorius address
        lightAccountFactoryMock.target as string,
        VOTING_PERIOD,
      );
      encodedProposalIdData = ethers.AbiCoder.defaultAbiCoder().encode(['uint32'], [PROPOSAL_ID]);
    });

    it('should revert if called by an address other than the proposalInitializer', async () => {
      await expect(
        linearERC20Voting.connect(nonOwner).initializeProposal(encodedProposalIdData),
      ).to.be.revertedWithCustomError(linearERC20Voting, 'ProposalInitializerUnauthorizedAccount');
    });

    it('should successfully initialize a proposal, set timestamps/block, and emit ProposalInitialized event', async () => {
      // Ensure mockToken is in Timestamp mode for consistent interaction if any part of it relies on it,
      // though initializeProposal itself is mode-agnostic for start/end times.
      await mockToken.setClockMode(ClockMode.Timestamp);

      const tx = await linearERC20Voting
        .connect(proposalInitializer)
        .initializeProposal(encodedProposalIdData);
      const receipt = await tx.wait();
      if (!receipt) throw new Error('No receipt');
      const block = await ethers.provider.getBlock(receipt.blockNumber);
      if (!block) throw new Error('No block');
      const currentBlockTimestamp = block.timestamp;
      const currentBlockNumber = receipt.blockNumber;

      const expectedEndTimestamp = currentBlockTimestamp + VOTING_PERIOD;

      const [
        ,
        ,
        ,
        // noVotes, yesVotes, abstainVotes are 0 initially
        retrievedStartTimestamp,
        retrievedStartBlock,
        retrievedEndTimestamp,
        // votingSupply (tested separately)
        ,
      ] = await linearERC20Voting.getProposalVotes(PROPOSAL_ID);

      expect(retrievedStartTimestamp).to.equal(currentBlockTimestamp);
      expect(retrievedEndTimestamp).to.equal(expectedEndTimestamp);
      expect(retrievedStartBlock).to.equal(currentBlockNumber);

      // Check proposal is marked as initialized (e.g., endTimestamp is not 0)
      expect(retrievedEndTimestamp).to.not.equal(0);
      // Check voting period not ended - this checks the _votingPeriodEnded flag via a view function
      // votingPeriodEnded is a mapping in BaseStrategyV1.sol, false by default
      void expect(await linearERC20Voting.votingPeriodEnded(PROPOSAL_ID)).to.be.false;

      await expect(tx)
        .to.emit(linearERC20Voting, 'ProposalInitialized')
        .withArgs(PROPOSAL_ID, expectedEndTimestamp);
    });

    it('should allow re-initializing an existing proposal, overwriting its details and re-emitting the event', async () => {
      // Initial initialization
      await linearERC20Voting
        .connect(proposalInitializer)
        .initializeProposal(encodedProposalIdData);
      const [, , , initialStartTimestamp, initialStartBlock, initialEndTimestamp, ,] =
        await linearERC20Voting.getProposalVotes(PROPOSAL_ID);

      // Advance time to ensure subsequent block.timestamp and block number are different
      await time.increase(VOTING_PERIOD / 2);

      // Re-initialize the same proposal
      const reinitTx = await linearERC20Voting
        .connect(proposalInitializer)
        .initializeProposal(encodedProposalIdData);
      const reinitReceipt = await reinitTx.wait();
      if (!reinitReceipt) throw new Error('No receipt for re-initialization');
      const reinitBlock = await ethers.provider.getBlock(reinitReceipt.blockNumber);
      if (!reinitBlock) throw new Error('No block for re-initialization');
      const newBlockTimestamp = reinitBlock.timestamp;
      const newBlockNumber = reinitReceipt.blockNumber;

      const newExpectedEndTimestamp = newBlockTimestamp + VOTING_PERIOD;

      const [
        ,
        ,
        ,
        // votes
        newStartTimestamp,
        newStartBlock,
        newEndTimestamp, // supply
        ,
      ] = await linearERC20Voting.getProposalVotes(PROPOSAL_ID);

      expect(newStartTimestamp).to.not.equal(initialStartTimestamp);
      expect(newStartTimestamp).to.equal(newBlockTimestamp);
      expect(newEndTimestamp).to.not.equal(initialEndTimestamp);
      expect(newEndTimestamp).to.equal(newExpectedEndTimestamp);
      expect(newStartBlock).to.not.equal(initialStartBlock);
      expect(newStartBlock).to.equal(newBlockNumber);

      await expect(reinitTx)
        .to.emit(linearERC20Voting, 'ProposalInitialized')
        .withArgs(PROPOSAL_ID, newExpectedEndTimestamp);
    });
  });

  describe('hasVoted function', () => {
    let linearERC20Voting: LinearERC20VotingV1;
    const PROPOSAL_ID_1 = 1;
    const PROPOSAL_ID_2 = 2;
    let encodedProposalId1Data: string;
    let encodedProposalId2Data: string;
    const DEFAULT_VOTING_WEIGHT = ethers.parseUnits('100', 18);

    beforeEach(async () => {
      linearERC20Voting = await deployLinearERC20Voting(
        owner,
        await mockToken.getAddress(),
        proposalInitializer.address,
        lightAccountFactoryMock.target as string,
      );

      encodedProposalId1Data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['uint32'],
        [PROPOSAL_ID_1],
      );
      encodedProposalId2Data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['uint32'],
        [PROPOSAL_ID_2],
      );

      // Mint and delegate for tokenHolder1 for voting
      await mockToken.mint(tokenHolder1.address, DEFAULT_VOTING_WEIGHT);
      await mockToken.connect(tokenHolder1).delegate(tokenHolder1.address);
    });

    it('should return false for an uninitialized proposal', async () => {
      const uninitializedProposalId = 999;
      void expect(await linearERC20Voting.hasVoted(uninitializedProposalId, tokenHolder1.address))
        .to.be.false;
    });

    it('should return false for an initialized proposal if the address has not voted', async () => {
      await linearERC20Voting
        .connect(proposalInitializer)
        .initializeProposal(encodedProposalId1Data);
      void expect(await linearERC20Voting.hasVoted(PROPOSAL_ID_1, tokenHolder1.address)).to.be
        .false;
    });

    it('should return true for an initialized proposal after the address has voted', async () => {
      await linearERC20Voting
        .connect(proposalInitializer)
        .initializeProposal(encodedProposalId1Data);
      await linearERC20Voting.connect(tokenHolder1).vote(PROPOSAL_ID_1, VoteType.YES);
      void expect(await linearERC20Voting.hasVoted(PROPOSAL_ID_1, tokenHolder1.address)).to.be.true;
    });

    it('should return false if checking the smart contract address after its EOA owner voted via the contract', async () => {
      // Setup for smart contract voting (similar to 'vote function' tests)
      const eoaOwnerOfMock = tokenHolder2; // Use a different holder for clarity
      await mockToken.mint(eoaOwnerOfMock.address, DEFAULT_VOTING_WEIGHT);
      await mockToken.connect(eoaOwnerOfMock).delegate(eoaOwnerOfMock.address);

      const mockOwnershipInstance = await new MockOwnership__factory(deployer).deploy(
        eoaOwnerOfMock.address,
      );
      await mockOwnershipInstance.waitForDeployment();
      const mockOwnershipAddress = await mockOwnershipInstance.getAddress();

      await lightAccountFactoryMock.setAccountAddress(
        eoaOwnerOfMock.address,
        0, // salt
        mockOwnershipAddress,
      );

      // Initialize proposal
      await linearERC20Voting
        .connect(proposalInitializer)
        .initializeProposal(encodedProposalId1Data);

      // EOA owner calls the smart contract to vote
      await mockOwnershipInstance
        .connect(eoaOwnerOfMock)
        .callExternalVote(await linearERC20Voting.getAddress(), PROPOSAL_ID_1, VoteType.YES);

      // hasVoted for the EOA owner should be true
      void expect(await linearERC20Voting.hasVoted(PROPOSAL_ID_1, eoaOwnerOfMock.address)).to.be
        .true;
      // hasVoted for the smart contract itself should be false, as the EOA is the voter
      void expect(await linearERC20Voting.hasVoted(PROPOSAL_ID_1, mockOwnershipAddress)).to.be
        .false;
    });

    it('should correctly distinguish voted status between multiple proposals for the same voter', async () => {
      // Initialize both proposals
      await linearERC20Voting
        .connect(proposalInitializer)
        .initializeProposal(encodedProposalId1Data);
      await linearERC20Voting
        .connect(proposalInitializer)
        .initializeProposal(encodedProposalId2Data);

      // Vote on PROPOSAL_ID_1 only
      await linearERC20Voting.connect(tokenHolder1).vote(PROPOSAL_ID_1, VoteType.YES);

      // Check voted status
      void expect(await linearERC20Voting.hasVoted(PROPOSAL_ID_1, tokenHolder1.address)).to.be.true;
      void expect(await linearERC20Voting.hasVoted(PROPOSAL_ID_2, tokenHolder1.address)).to.be
        .false;

      // Now vote on PROPOSAL_ID_2
      await linearERC20Voting.connect(tokenHolder1).vote(PROPOSAL_ID_2, VoteType.NO);
      void expect(await linearERC20Voting.hasVoted(PROPOSAL_ID_2, tokenHolder1.address)).to.be.true;
    });
  });

  describe('isPassed function', () => {
    let linearERC20Voting: LinearERC20VotingV1;
    const PROPOSAL_ID = 4;
    let encodedProposalIdData: string;

    // Default weights for voters
    const WEIGHT_VOTER_YES = ethers.parseUnits('600', 18); // 60%
    const WEIGHT_VOTER_NO = ethers.parseUnits('300', 18); // 30%
    const WEIGHT_VOTER_ABSTAIN = ethers.parseUnits('100', 18); // 10%
    // Total supply from these three default voters = 1000

    // Default constants for strategy, can be overridden in specific tests by re-deploying or using setters
    const DEFAULT_TEST_QUORUM_NUMERATOR = 300_000; // 30% of 1,000,000 (i.e., 30% of total supply)
    const DEFAULT_TEST_BASIS_NUMERATOR = 500_001; // >50% (e.g. 50.0001% requires YES > NO)
    const DEFAULT_TEST_VOTING_PERIOD = 100;

    // Helper to initialize and set up mock past votes/supply for a proposal
    async function setupProposalForPassingTests(
      proposalId: number,
      config: {
        voter1Weight?: bigint;
        voter2Weight?: bigint;
        voter3Weight?: bigint;
        totalSupply: bigint;
        quorumNumerator?: number;
        basisNumerator?: number;
        votingPeriod?: number;
      },
    ) {
      linearERC20Voting = await deployLinearERC20Voting(
        owner,
        await mockToken.getAddress(),
        proposalInitializer.address,
        lightAccountFactoryMock.target as string,
        config.votingPeriod ?? DEFAULT_TEST_VOTING_PERIOD,
        REQUIRED_PROPOSER_WEIGHT,
        config.quorumNumerator ?? DEFAULT_TEST_QUORUM_NUMERATOR,
        config.basisNumerator ?? DEFAULT_TEST_BASIS_NUMERATOR,
      );

      encodedProposalIdData = ethers.AbiCoder.defaultAbiCoder().encode(['uint32'], [proposalId]);
      const initTx = await linearERC20Voting
        .connect(proposalInitializer)
        .initializeProposal(encodedProposalIdData);
      const receipt = await initTx.wait();
      if (!receipt) throw new Error('Proposal initialization failed');
      const block = await ethers.provider.getBlock(receipt.blockNumber);
      if (!block) throw new Error('Block not found');

      const timepoint =
        (await mockToken.CLOCK_MODE()) === 'mode=timestamp' ? block.timestamp : receipt.blockNumber;

      await mockToken.setPastTotalSupply(timepoint, config.totalSupply);
      await mockToken.setPastVotes(tokenHolder1.address, timepoint, config.voter1Weight ?? 0n);
      await mockToken.setPastVotes(tokenHolder2.address, timepoint, config.voter2Weight ?? 0n);
      await mockToken.setPastVotes(tokenHolder3.address, timepoint, config.voter3Weight ?? 0n);

      // Ensure other potential signers (if any used in a test) have 0 past votes unless specified by config for tokenHolders 1-3
      const allSigners = await ethers.getSigners();
      for (const signer of allSigners) {
        if (
          ![tokenHolder1.address, tokenHolder2.address, tokenHolder3.address].includes(
            signer.address,
          )
        ) {
          await mockToken.setPastVotes(signer.address, timepoint, 0n);
        }
      }

      return {
        startTimestamp: block.timestamp,
        endTimestamp: block.timestamp + (config.votingPeriod ?? DEFAULT_TEST_VOTING_PERIOD),
      };
    }

    beforeEach(async () => {
      // Standard deployment, but past votes are set by the helper for proposal-specific snapshots
      linearERC20Voting = await deployLinearERC20Voting(
        owner,
        await mockToken.getAddress(),
        proposalInitializer.address,
        lightAccountFactoryMock.target as string,
        DEFAULT_TEST_VOTING_PERIOD,
        REQUIRED_PROPOSER_WEIGHT,
        DEFAULT_TEST_QUORUM_NUMERATOR,
        DEFAULT_TEST_BASIS_NUMERATOR,
      );

      // Mint tokens for default voters. These weights are used for setPastVotes in helper.
      await mockToken.mint(tokenHolder1.address, WEIGHT_VOTER_YES);
      await mockToken.connect(tokenHolder1).delegate(tokenHolder1.address);
      await mockToken.mint(tokenHolder2.address, WEIGHT_VOTER_NO);
      await mockToken.connect(tokenHolder2).delegate(tokenHolder2.address);
      await mockToken.mint(tokenHolder3.address, WEIGHT_VOTER_ABSTAIN);
      await mockToken.connect(tokenHolder3).delegate(tokenHolder3.address);
    });

    it('should return false for an uninitialized proposal', async () => {
      const uninitializedProposalId = 999;
      void expect(await linearERC20Voting.isPassed(uninitializedProposalId)).to.be.false;
    });

    it('should return false if voting period has not ended, even if other conditions met', async () => {
      const totalSupply = WEIGHT_VOTER_YES + WEIGHT_VOTER_NO + WEIGHT_VOTER_ABSTAIN;
      await setupProposalForPassingTests(PROPOSAL_ID, {
        totalSupply,
        voter1Weight: WEIGHT_VOTER_YES, // Voter1 will vote YES
      });

      await linearERC20Voting.connect(tokenHolder1).vote(PROPOSAL_ID, VoteType.YES);
      // Not advancing time
      void expect(await linearERC20Voting.isPassed(PROPOSAL_ID)).to.be.false;
    });

    describe('after voting period has ended', () => {
      it('should PASS if quorum and basis are met (YES > NO)', async () => {
        const totalSupply = WEIGHT_VOTER_YES + WEIGHT_VOTER_NO + WEIGHT_VOTER_ABSTAIN; // 1000
        const { endTimestamp } = await setupProposalForPassingTests(PROPOSAL_ID, {
          totalSupply,
          voter1Weight: WEIGHT_VOTER_YES,
          voter2Weight: WEIGHT_VOTER_NO,
          voter3Weight: WEIGHT_VOTER_ABSTAIN,
        });

        await linearERC20Voting.connect(tokenHolder1).vote(PROPOSAL_ID, VoteType.YES);
        await linearERC20Voting.connect(tokenHolder2).vote(PROPOSAL_ID, VoteType.NO);
        await linearERC20Voting.connect(tokenHolder3).vote(PROPOSAL_ID, VoteType.ABSTAIN);

        await time.increaseTo(endTimestamp + 1);
        void expect(await linearERC20Voting.isPassed(PROPOSAL_ID)).to.be.true;
      });

      it('should FAIL if quorum is not met, even if basis is met', async () => {
        const smallWeight = ethers.parseUnits('100', 18);
        const totalSupplyForTest = ethers.parseUnits('600', 18); // Quorum will be 30% of this = 180

        // Voter1 has smallWeight, which is less than quorum
        const { endTimestamp } = await setupProposalForPassingTests(PROPOSAL_ID, {
          totalSupply: totalSupplyForTest,
          voter1Weight: smallWeight,
          // voter2Weight, voter3Weight default to 0n by helper if not specified
        });

        await linearERC20Voting.connect(tokenHolder1).vote(PROPOSAL_ID, VoteType.YES); // 100 YES

        await time.increaseTo(endTimestamp + 1);
        void expect(await linearERC20Voting.isPassed(PROPOSAL_ID)).to.be.false;
      });

      it('should FAIL if basis is not met (e.g. YES <= NO), even if quorum is met', async () => {
        const totalSupply = WEIGHT_VOTER_YES + WEIGHT_VOTER_NO + WEIGHT_VOTER_ABSTAIN; // 1000
        const { endTimestamp } = await setupProposalForPassingTests(PROPOSAL_ID, {
          totalSupply,
          // For this test, tokenHolder2 (normally NO voter) will vote YES with NO_WEIGHT
          // And tokenHolder1 (normally YES voter) will vote NO with YES_WEIGHT
          voter1Weight: WEIGHT_VOTER_YES, // This will be used for NO vote by tokenHolder1
          voter2Weight: WEIGHT_VOTER_NO, // This will be used for YES vote by tokenHolder2
          voter3Weight: WEIGHT_VOTER_ABSTAIN,
        });

        // tokenHolder2 votes YES with its configured WEIGHT_VOTER_NO
        await linearERC20Voting.connect(tokenHolder2).vote(PROPOSAL_ID, VoteType.YES);
        // tokenHolder1 votes NO with its configured WEIGHT_VOTER_YES
        await linearERC20Voting.connect(tokenHolder1).vote(PROPOSAL_ID, VoteType.NO);
        await linearERC20Voting.connect(tokenHolder3).vote(PROPOSAL_ID, VoteType.ABSTAIN);

        await time.increaseTo(endTimestamp + 1);
        void expect(await linearERC20Voting.isPassed(PROPOSAL_ID)).to.be.false;
      });

      it('should PASS if quorum is 0%, basis met, and period ended', async () => {
        const totalSupply = WEIGHT_VOTER_YES + WEIGHT_VOTER_NO; // 900
        const { endTimestamp } = await setupProposalForPassingTests(PROPOSAL_ID, {
          totalSupply,
          voter1Weight: WEIGHT_VOTER_YES,
          voter2Weight: WEIGHT_VOTER_NO,
          quorumNumerator: 0, // 0% quorum
        });

        await linearERC20Voting.connect(tokenHolder1).vote(PROPOSAL_ID, VoteType.YES);
        await linearERC20Voting.connect(tokenHolder2).vote(PROPOSAL_ID, VoteType.NO);
        // No abstain votes, total votes = 900. Quorum 0% of 900 = 0. Meets quorum.
        // Basis: >50%. YES(600) / (YES(600)+NO(300)) = 66.6%. Meets basis.

        await time.increaseTo(endTimestamp + 1);
        void expect(await linearERC20Voting.isPassed(PROPOSAL_ID)).to.be.true;
      });

      it('should FAIL if basis is 100% and any NO votes exist, even if quorum met', async () => {
        const totalSupply = WEIGHT_VOTER_YES + WEIGHT_VOTER_NO; // 900
        const { endTimestamp } = await setupProposalForPassingTests(PROPOSAL_ID, {
          totalSupply,
          voter1Weight: WEIGHT_VOTER_YES,
          voter2Weight: WEIGHT_VOTER_NO,
          basisNumerator: BASIS_DENOMINATOR, // 100% basis
        });

        await linearERC20Voting.connect(tokenHolder1).vote(PROPOSAL_ID, VoteType.YES);
        await linearERC20Voting.connect(tokenHolder2).vote(PROPOSAL_ID, VoteType.NO);
        // Quorum: 30% of 900 = 270. YES(600) + ABSTAIN(0) = 600. Meets quorum.
        // Basis: 100%. YES(600) / (YES(600)+NO(300)) = 66.6%. Fails 100% basis.

        await time.increaseTo(endTimestamp + 1);
        void expect(await linearERC20Voting.isPassed(PROPOSAL_ID)).to.be.false;
      });

      it('should FAIL if basis is 50% (requires YES > NO) and YES == NO, even if quorum met', async () => {
        const equalWeight = ethers.parseUnits('300', 18);
        const totalSupply = equalWeight + equalWeight; // 600

        const { endTimestamp } = await setupProposalForPassingTests(PROPOSAL_ID, {
          totalSupply,
          voter1Weight: equalWeight,
          voter2Weight: equalWeight,
          basisNumerator: BASIS_DENOMINATOR / 2, // 50% basis
        });

        await linearERC20Voting.connect(tokenHolder1).vote(PROPOSAL_ID, VoteType.YES);
        await linearERC20Voting.connect(tokenHolder2).vote(PROPOSAL_ID, VoteType.NO);
        // Quorum: 30% of 600 = 180. YES(300) + ABSTAIN(0) = 300. Meets quorum.
        // Basis: 50%. YES(300) / (YES(300)+NO(300)) = 50%. Does NOT meet basis (requires >50%).

        await time.increaseTo(endTimestamp + 1);
        void expect(await linearERC20Voting.isPassed(PROPOSAL_ID)).to.be.false;
      });

      it('should PASS if basis is 50% (requires YES > NO) and YES > NO slightly, and quorum met', async () => {
        const yesSlightlyMore = ethers.parseUnits('301', 18);
        const noSlightlyLess = ethers.parseUnits('300', 18);
        const totalSupply = yesSlightlyMore + noSlightlyLess; // 601

        const { endTimestamp } = await setupProposalForPassingTests(PROPOSAL_ID, {
          totalSupply,
          voter1Weight: yesSlightlyMore,
          voter2Weight: noSlightlyLess,
          basisNumerator: BASIS_DENOMINATOR / 2, // 50% basis
        });

        await linearERC20Voting.connect(tokenHolder1).vote(PROPOSAL_ID, VoteType.YES);
        await linearERC20Voting.connect(tokenHolder2).vote(PROPOSAL_ID, VoteType.NO);
        // Quorum: 30% of 601 = 180.3. YES(301) + ABSTAIN(0) = 301. Meets quorum.
        // Basis: 50%. YES(301) > (YES(301)+NO(300))*0.5 = 300.5. Meets basis.

        await time.increaseTo(endTimestamp + 1);
        void expect(await linearERC20Voting.isPassed(PROPOSAL_ID)).to.be.true;
      });

      it('should FAIL if basis is 100% and any NO votes exist, even if quorum met', async () => {
        const totalSupply = WEIGHT_VOTER_YES + WEIGHT_VOTER_NO; // 900
        const { endTimestamp } = await setupProposalForPassingTests(PROPOSAL_ID, {
          totalSupply,
          voter1Weight: WEIGHT_VOTER_YES,
          voter2Weight: WEIGHT_VOTER_NO,
          basisNumerator: BASIS_DENOMINATOR, // 100% basis
        });

        await linearERC20Voting.connect(tokenHolder1).vote(PROPOSAL_ID, VoteType.YES);
        await linearERC20Voting.connect(tokenHolder2).vote(PROPOSAL_ID, VoteType.NO);
        // Quorum: 30% of 900 = 270. YES(600) + ABSTAIN(0) = 600. Meets quorum.
        // Basis: 100%. YES(600) / (YES(600)+NO(300)) = 66.6%. Fails 100% basis.

        await time.increaseTo(endTimestamp + 1);
        void expect(await linearERC20Voting.isPassed(PROPOSAL_ID)).to.be.false;
      });

      it('should FAIL if basis is 100% and only YES votes exist (due to strict `>` in meetsBasis), even if quorum met', async () => {
        const totalSupply = WEIGHT_VOTER_YES; // 600
        const { endTimestamp } = await setupProposalForPassingTests(PROPOSAL_ID, {
          totalSupply,
          voter1Weight: WEIGHT_VOTER_YES,
          basisNumerator: BASIS_DENOMINATOR, // 100% basis
        });
        // Quorum: DEFAULT_TEST_QUORUM_NUMERATOR (30%) of 600 = 180. YES(600) + ABSTAIN(0) = 600. Meets quorum.
        // Basis: 100%. Contract is `YES > (YES+NO)*100%/100%` => `YES > YES+NO`.
        // If NO=0, this is `YES > YES` which is false.

        await linearERC20Voting.connect(tokenHolder1).vote(PROPOSAL_ID, VoteType.YES); // 600 YES

        await time.increaseTo(endTimestamp + 1);
        void expect(await linearERC20Voting.isPassed(PROPOSAL_ID)).to.be.false; // Corrected expectation from true to false
      });

      it('should FAIL if basis is 50% (requires YES > NO) and YES == NO, even if quorum met', async () => {
        const equalWeight = ethers.parseUnits('300', 18);
        const totalSupply = equalWeight + equalWeight; // 600

        const { endTimestamp } = await setupProposalForPassingTests(PROPOSAL_ID, {
          totalSupply,
          voter1Weight: equalWeight,
          voter2Weight: equalWeight,
          basisNumerator: BASIS_DENOMINATOR / 2, // 50% basis
        });

        await linearERC20Voting.connect(tokenHolder1).vote(PROPOSAL_ID, VoteType.YES);
        await linearERC20Voting.connect(tokenHolder2).vote(PROPOSAL_ID, VoteType.NO);
        // Quorum: 30% of 600 = 180. YES(300) + ABSTAIN(0) = 300. Meets quorum.
        // Basis: 50%. YES(300) / (YES(300)+NO(300)) = 50%. Does NOT meet basis (requires >50%).

        await time.increaseTo(endTimestamp + 1);
        void expect(await linearERC20Voting.isPassed(PROPOSAL_ID)).to.be.false;
      });
    });
  });

  describe('getProposalVotingSupply function', () => {
    const PROPOSAL_ID = 5;
    let encodedProposalIdData: string;
    const INITIAL_TOTAL_SUPPLY = ethers.parseUnits('1000', 18);
    const LATER_TOTAL_SUPPLY = ethers.parseUnits('2000', 18);

    beforeEach(() => {
      encodedProposalIdData = ethers.AbiCoder.defaultAbiCoder().encode(['uint32'], [PROPOSAL_ID]);
    });

    it('should return 0 for an uninitialized proposal (regardless of mode)', async () => {
      // Deploy a strategy instance (mode doesn't matter for uninitialized)
      const linearERC20Voting = await deployLinearERC20Voting(
        owner,
        await mockToken.getAddress(),
        proposalInitializer.address,
        lightAccountFactoryMock.target as string,
      );
      // For an uninitialized proposal, timestamps/blocks are 0.
      // MockERC20Votes.getPastTotalSupply(0) without prior setPastTotalSupply(0, x)
      // might return current mockToken.totalSupply(). So, explicitly set supply at 0 to 0.
      await mockToken.setPastTotalSupply(0, 0n);
      void expect(await linearERC20Voting.getProposalVotingSupply(PROPOSAL_ID)).to.equal(0);
    });

    describe('when token is in Timestamp mode', () => {
      let linearERC20Voting: LinearERC20VotingV1;
      let proposalStartTimestamp: number;

      beforeEach(async () => {
        await mockToken.setClockMode(ClockMode.Timestamp);
        linearERC20Voting = await deployLinearERC20Voting(
          owner,
          await mockToken.getAddress(),
          proposalInitializer.address,
          lightAccountFactoryMock.target as string,
        );

        // Mint initial supply
        await mockToken.mint(deployer.address, INITIAL_TOTAL_SUPPLY); // Mint to someone, total supply changes

        // Initialize proposal - this captures the current block.timestamp as votingStartTimestamp
        const initTx = await linearERC20Voting
          .connect(proposalInitializer)
          .initializeProposal(encodedProposalIdData);
        const receipt = await initTx.wait();
        if (!receipt) throw new Error('Proposal init failed');
        const block = await ethers.provider.getBlock(receipt.blockNumber);
        if (!block) throw new Error('Block not found');
        proposalStartTimestamp = block.timestamp;

        // Set the past total supply at the exact proposalStartTimestamp
        await mockToken.setPastTotalSupply(proposalStartTimestamp, INITIAL_TOTAL_SUPPLY);
      });

      it('should return the total supply snapshotted at proposal creation (votingStartTimestamp)', async () => {
        void expect(await linearERC20Voting.getProposalVotingSupply(PROPOSAL_ID)).to.equal(
          INITIAL_TOTAL_SUPPLY,
        );
      });

      it('should not be affected by total supply changes after proposal creation timestamp', async () => {
        // Verify initial snapshot first
        void expect(await linearERC20Voting.getProposalVotingSupply(PROPOSAL_ID)).to.equal(
          INITIAL_TOTAL_SUPPLY,
        );

        // Mint more tokens, advancing time beyond the snapshot point
        await time.increase(10); // Ensure we are past the proposalStartTimestamp if it was very recent
        await mockToken.mint(deployer.address, LATER_TOTAL_SUPPLY - INITIAL_TOTAL_SUPPLY); // Increase total supply

        // The supply for the proposal should still be the snapshotted one
        void expect(await linearERC20Voting.getProposalVotingSupply(PROPOSAL_ID)).to.equal(
          INITIAL_TOTAL_SUPPLY,
        );
      });
    });

    describe('when token is in BlockNumber mode', () => {
      let linearERC20Voting: LinearERC20VotingV1;
      let proposalStartBlock: number;
      let blockNumberMockToken: MockERC20Votes; // Use a dedicated token for block number mode tests for isolation

      beforeEach(async () => {
        blockNumberMockToken = await new MockERC20Votes__factory(deployer).deploy();
        await blockNumberMockToken.setClockMode(ClockMode.BlockNumber);

        linearERC20Voting = await deployLinearERC20Voting(
          owner,
          await blockNumberMockToken.getAddress(),
          proposalInitializer.address,
          lightAccountFactoryMock.target as string,
        );

        // Mint initial supply to the blockNumberMockToken
        await blockNumberMockToken.mint(deployer.address, INITIAL_TOTAL_SUPPLY);

        // Initialize proposal - this captures the current block.number as votingStartBlock
        const initTx = await linearERC20Voting
          .connect(proposalInitializer)
          .initializeProposal(encodedProposalIdData);
        const receipt = await initTx.wait();
        if (!receipt) throw new Error('Proposal init failed');
        proposalStartBlock = receipt.blockNumber;

        // Set the past total supply at the exact proposalStartBlock for the blockNumberMockToken
        await blockNumberMockToken.setPastTotalSupply(proposalStartBlock, INITIAL_TOTAL_SUPPLY);
      });

      it('should return the total supply snapshotted at proposal creation (votingStartBlock)', async () => {
        void expect(await linearERC20Voting.getProposalVotingSupply(PROPOSAL_ID)).to.equal(
          INITIAL_TOTAL_SUPPLY,
        );
      });

      it('should not be affected by total supply changes after proposal creation block', async () => {
        // Verify initial snapshot first
        void expect(await linearERC20Voting.getProposalVotingSupply(PROPOSAL_ID)).to.equal(
          INITIAL_TOTAL_SUPPLY,
        );

        // Mint more tokens, advancing blocks beyond the snapshot point
        await mine(); // Mine a block
        await blockNumberMockToken.mint(
          deployer.address,
          LATER_TOTAL_SUPPLY - INITIAL_TOTAL_SUPPLY,
        ); // Increase total supply
        await mine(); // Mine another to ensure mint transaction is processed and new block is queryable

        // The supply for the proposal should still be the snapshotted one
        void expect(await linearERC20Voting.getProposalVotingSupply(PROPOSAL_ID)).to.equal(
          INITIAL_TOTAL_SUPPLY,
        );
      });
    });
  });

  describe('getVotingWeight function', () => {
    const PROPOSAL_ID = 6;
    let encodedProposalIdData: string;
    const SNAPSHOT_VOTING_WEIGHT = ethers.parseUnits('500', 18);
    const LATER_VOTING_WEIGHT = ethers.parseUnits('1000', 18);

    beforeEach(() => {
      encodedProposalIdData = ethers.AbiCoder.defaultAbiCoder().encode(['uint32'], [PROPOSAL_ID]);
    });

    it('should return 0 for an uninitialized proposal (regardless of mode)', async () => {
      const linearERC20Voting = await deployLinearERC20Voting(
        owner,
        await mockToken.getAddress(),
        proposalInitializer.address,
        lightAccountFactoryMock.target as string,
      );
      // votingStartTimestamp/Block for uninitialized proposal is 0.
      // MockERC20Votes.getPastVotes(voter, 0) without prior setPastVotes(voter, 0, x) returns 0.
      void expect(
        await linearERC20Voting.getVotingWeight(tokenHolder1.address, PROPOSAL_ID),
      ).to.equal(0);
    });

    describe('when token is in Timestamp mode', () => {
      let linearERC20Voting: LinearERC20VotingV1;
      let proposalStartTimestamp: number;

      beforeEach(async () => {
        await mockToken.setClockMode(ClockMode.Timestamp);
        linearERC20Voting = await deployLinearERC20Voting(
          owner,
          await mockToken.getAddress(),
          proposalInitializer.address,
          lightAccountFactoryMock.target as string,
        );

        // Initialize proposal - this captures the current block.timestamp as votingStartTimestamp
        const initTx = await linearERC20Voting
          .connect(proposalInitializer)
          .initializeProposal(encodedProposalIdData);
        const receipt = await initTx.wait();
        if (!receipt) throw new Error('Proposal init failed');
        const block = await ethers.provider.getBlock(receipt.blockNumber);
        if (!block) throw new Error('Block not found');
        proposalStartTimestamp = block.timestamp;

        // Set the past votes for tokenHolder1 at the exact proposalStartTimestamp
        await mockToken.setPastVotes(
          tokenHolder1.address,
          proposalStartTimestamp,
          SNAPSHOT_VOTING_WEIGHT,
        );
        // Ensure tokenHolder2 has 0 votes at snapshot time for another test case
        await mockToken.setPastVotes(tokenHolder2.address, proposalStartTimestamp, 0n);
      });

      it('should return the voting weight snapshotted at proposal creation (votingStartTimestamp)', async () => {
        void expect(
          await linearERC20Voting.getVotingWeight(tokenHolder1.address, PROPOSAL_ID),
        ).to.equal(SNAPSHOT_VOTING_WEIGHT);
      });

      it('should not be affected by voting weight changes after proposal creation timestamp', async () => {
        // Verify initial snapshot first
        void expect(
          await linearERC20Voting.getVotingWeight(tokenHolder1.address, PROPOSAL_ID),
        ).to.equal(SNAPSHOT_VOTING_WEIGHT);

        // Mint more tokens and delegate to tokenHolder1 *after* the snapshot point
        await time.increase(10); // Ensure we are past the proposalStartTimestamp
        await mockToken.mint(tokenHolder1.address, LATER_VOTING_WEIGHT);
        await mockToken.connect(tokenHolder1).delegate(tokenHolder1.address); // Updates current votes
        // For ERC20Votes, getPastVotes relies on checkpoints. A transfer/delegate/mint that changes balance creates a checkpoint.
        // We can explicitly set a new past vote for a *new* timestamp if needed, but current `getVotes` would reflect LATER_VOTING_WEIGHT.

        // The weight for the proposal should still be the snapshotted one
        void expect(
          await linearERC20Voting.getVotingWeight(tokenHolder1.address, PROPOSAL_ID),
        ).to.equal(SNAPSHOT_VOTING_WEIGHT);
      });

      it('should return 0 for a voter with no votes at snapshot time, even if they get votes later', async () => {
        void expect(
          await linearERC20Voting.getVotingWeight(tokenHolder2.address, PROPOSAL_ID),
        ).to.equal(0);

        await time.increase(10);
        await mockToken.mint(tokenHolder2.address, LATER_VOTING_WEIGHT);
        await mockToken.connect(tokenHolder2).delegate(tokenHolder2.address);

        void expect(
          await linearERC20Voting.getVotingWeight(tokenHolder2.address, PROPOSAL_ID),
        ).to.equal(0);
      });
    });

    describe('when token is in BlockNumber mode', () => {
      let linearERC20Voting: LinearERC20VotingV1;
      let proposalStartBlock: number;
      let blockNumberMockToken: MockERC20Votes;

      beforeEach(async () => {
        blockNumberMockToken = await new MockERC20Votes__factory(deployer).deploy();
        await blockNumberMockToken.setClockMode(ClockMode.BlockNumber);

        linearERC20Voting = await deployLinearERC20Voting(
          owner,
          await blockNumberMockToken.getAddress(),
          proposalInitializer.address,
          lightAccountFactoryMock.target as string,
        );

        // Initialize proposal - this captures the current block.number as votingStartBlock
        const initTx = await linearERC20Voting
          .connect(proposalInitializer)
          .initializeProposal(encodedProposalIdData);
        const receipt = await initTx.wait();
        if (!receipt) throw new Error('Proposal init failed');
        proposalStartBlock = receipt.blockNumber;

        // Set past votes for tokenHolder1 at the exact proposalStartBlock
        await blockNumberMockToken.setPastVotes(
          tokenHolder1.address,
          proposalStartBlock,
          SNAPSHOT_VOTING_WEIGHT,
        );
        // Ensure tokenHolder2 has 0 votes at snapshot time
        await blockNumberMockToken.setPastVotes(tokenHolder2.address, proposalStartBlock, 0n);
      });

      it('should return the voting weight snapshotted at proposal creation (votingStartBlock)', async () => {
        void expect(
          await linearERC20Voting.getVotingWeight(tokenHolder1.address, PROPOSAL_ID),
        ).to.equal(SNAPSHOT_VOTING_WEIGHT);
      });

      it('should not be affected by voting weight changes after proposal creation block', async () => {
        void expect(
          await linearERC20Voting.getVotingWeight(tokenHolder1.address, PROPOSAL_ID),
        ).to.equal(SNAPSHOT_VOTING_WEIGHT);

        // Mint more tokens and delegate *after* the snapshot block
        await mine(); // Advance a block
        await blockNumberMockToken.mint(tokenHolder1.address, LATER_VOTING_WEIGHT);
        await blockNumberMockToken.connect(tokenHolder1).delegate(tokenHolder1.address);
        await mine(); // Ensure mint/delegate processed

        void expect(
          await linearERC20Voting.getVotingWeight(tokenHolder1.address, PROPOSAL_ID),
        ).to.equal(SNAPSHOT_VOTING_WEIGHT);
      });

      it('should return 0 for a voter with no votes at snapshot block, even if they get votes later', async () => {
        void expect(
          await linearERC20Voting.getVotingWeight(tokenHolder2.address, PROPOSAL_ID),
        ).to.equal(0);

        await mine();
        await blockNumberMockToken.mint(tokenHolder2.address, LATER_VOTING_WEIGHT);
        await blockNumberMockToken.connect(tokenHolder2).delegate(tokenHolder2.address);
        await mine();

        void expect(
          await linearERC20Voting.getVotingWeight(tokenHolder2.address, PROPOSAL_ID),
        ).to.equal(0);
      });
    });
  });

  describe('isProposer function', () => {
    const TEST_REQUIRED_PROPOSER_WEIGHT = ethers.parseUnits('100', 18);

    describe('when token is in Timestamp mode', () => {
      let linearERC20Voting: LinearERC20VotingV1;

      beforeEach(async () => {
        await mockToken.setClockMode(ClockMode.Timestamp);
        linearERC20Voting = await deployLinearERC20Voting(
          owner,
          await mockToken.getAddress(),
          proposalInitializer.address,
          lightAccountFactoryMock.target as string,
          VOTING_PERIOD, // Default voting period
          TEST_REQUIRED_PROPOSER_WEIGHT, // Specific required weight for these tests
        );
      });

      it('should return false if voter weight is less than requiredProposerWeight', async () => {
        await mockToken.mint(tokenHolder1.address, (TEST_REQUIRED_PROPOSER_WEIGHT - 1n).toString());
        await mockToken.connect(tokenHolder1).delegate(tokenHolder1.address);
        await time.increase(10); // Advance time so current timestamp is ahead of delegation
        void expect(await linearERC20Voting.isProposer(tokenHolder1.address)).to.be.false;
      });

      it('should return true if voter weight is equal to requiredProposerWeight', async () => {
        await mockToken.mint(tokenHolder1.address, TEST_REQUIRED_PROPOSER_WEIGHT);
        await mockToken.connect(tokenHolder1).delegate(tokenHolder1.address);
        await time.increase(10);
        void expect(await linearERC20Voting.isProposer(tokenHolder1.address)).to.be.true;
      });

      it('should return true if voter weight is greater than requiredProposerWeight', async () => {
        await mockToken.mint(tokenHolder1.address, (TEST_REQUIRED_PROPOSER_WEIGHT + 1n).toString());
        await mockToken.connect(tokenHolder1).delegate(tokenHolder1.address);
        await time.increase(10);
        void expect(await linearERC20Voting.isProposer(tokenHolder1.address)).to.be.true;
      });

      it('should reflect changes in voter weight over time', async () => {
        // Initially not a proposer
        await mockToken.mint(
          tokenHolder1.address,
          (TEST_REQUIRED_PROPOSER_WEIGHT - 10n).toString(),
        );
        await mockToken.connect(tokenHolder1).delegate(tokenHolder1.address);
        await time.increase(10);
        void expect(await linearERC20Voting.isProposer(tokenHolder1.address)).to.be.false;

        // Gains enough weight
        await mockToken.mint(tokenHolder1.address, 20n.toString()); // Total is now RPW + 10
        // delegate again to checkpoint the new balance for getPastVotes at current time - 1
        await mockToken.connect(tokenHolder1).delegate(tokenHolder1.address);
        await time.increase(10);
        void expect(await linearERC20Voting.isProposer(tokenHolder1.address)).to.be.true;
      });

      it('should return true if requiredProposerWeight is 0, even with 0 voter weight', async () => {
        const zeroWeightVoting = await deployLinearERC20Voting(
          owner,
          await mockToken.getAddress(),
          proposalInitializer.address,
          lightAccountFactoryMock.target as string,
          VOTING_PERIOD,
          0, // Zero required weight
        );
        // tokenHolder1 has 0 weight by default if no mint/delegate
        await time.increase(10);
        void expect(await zeroWeightVoting.isProposer(tokenHolder1.address)).to.be.true;
      });
    });

    describe('when token is in BlockNumber mode', () => {
      let linearERC20Voting: LinearERC20VotingV1;
      let blockNumberMockToken: MockERC20Votes;

      beforeEach(async () => {
        blockNumberMockToken = await new MockERC20Votes__factory(deployer).deploy();
        await blockNumberMockToken.setClockMode(ClockMode.BlockNumber);
        linearERC20Voting = await deployLinearERC20Voting(
          owner,
          await blockNumberMockToken.getAddress(),
          proposalInitializer.address,
          lightAccountFactoryMock.target as string,
          VOTING_PERIOD,
          TEST_REQUIRED_PROPOSER_WEIGHT,
        );
      });

      it('should return false if voter weight is less than required (checks block.number - 1)', async () => {
        await blockNumberMockToken.mint(
          tokenHolder1.address,
          (TEST_REQUIRED_PROPOSER_WEIGHT - 1n).toString(),
        );
        await blockNumberMockToken.connect(tokenHolder1).delegate(tokenHolder1.address);
        await mine(); // Mine block for mint/delegate
        await mine(); // Mine another block so isProposer checks previous block
        void expect(await linearERC20Voting.isProposer(tokenHolder1.address)).to.be.false;
      });

      it('should return true if voter weight is equal to required (checks block.number - 1)', async () => {
        await blockNumberMockToken.mint(tokenHolder1.address, TEST_REQUIRED_PROPOSER_WEIGHT);
        await blockNumberMockToken.connect(tokenHolder1).delegate(tokenHolder1.address);
        await mine();
        await mine();
        void expect(await linearERC20Voting.isProposer(tokenHolder1.address)).to.be.true;
      });

      it('should return true if voter weight is greater than required (checks block.number - 1)', async () => {
        await blockNumberMockToken.mint(
          tokenHolder1.address,
          (TEST_REQUIRED_PROPOSER_WEIGHT + 1n).toString(),
        );
        await blockNumberMockToken.connect(tokenHolder1).delegate(tokenHolder1.address);
        await mine();
        await mine();
        void expect(await linearERC20Voting.isProposer(tokenHolder1.address)).to.be.true;
      });

      it('should reflect changes in voter weight over blocks', async () => {
        await blockNumberMockToken.mint(
          tokenHolder1.address,
          (TEST_REQUIRED_PROPOSER_WEIGHT - 10n).toString(),
        );
        await blockNumberMockToken.connect(tokenHolder1).delegate(tokenHolder1.address);
        await mine(); // Block N: Mint/Delegate happens
        await mine(); // Block N+1: isProposer checks N (false)
        void expect(await linearERC20Voting.isProposer(tokenHolder1.address)).to.be.false;

        await blockNumberMockToken.mint(tokenHolder1.address, 20n.toString()); // Total is now RPW + 10
        await blockNumberMockToken.connect(tokenHolder1).delegate(tokenHolder1.address);
        await mine(); // Block N+2: New mint/delegate
        await mine(); // Block N+3: isProposer checks N+2 (true)
        void expect(await linearERC20Voting.isProposer(tokenHolder1.address)).to.be.true;
      });

      it('should return true if requiredProposerWeight is 0, even with 0 voter weight (BlockNumber mode)', async () => {
        const zeroWeightVoting = await deployLinearERC20Voting(
          owner,
          await blockNumberMockToken.getAddress(),
          proposalInitializer.address,
          lightAccountFactoryMock.target as string,
          VOTING_PERIOD,
          0, // Zero required weight
        );
        // tokenHolder1 has 0 weight by default if no mint/delegate
        await mine(); // Ensure a previous block exists
        void expect(await zeroWeightVoting.isProposer(tokenHolder1.address)).to.be.true;
      });
    });
  });

  describe('getVotingTimestamps function', () => {
    let linearERC20Voting: LinearERC20VotingV1;
    const PROPOSAL_ID = 7;
    let encodedProposalIdData: string;

    beforeEach(async () => {
      linearERC20Voting = await deployLinearERC20Voting(
        owner,
        await mockToken.getAddress(),
        proposalInitializer.address,
        lightAccountFactoryMock.target as string,
      );
      encodedProposalIdData = ethers.AbiCoder.defaultAbiCoder().encode(['uint32'], [PROPOSAL_ID]);
    });

    it('should return (0, 0) for an uninitialized proposal', async () => {
      const uninitializedProposalId = PROPOSAL_ID + 999;
      const [startTimestamp, endTimestamp] =
        await linearERC20Voting.getVotingTimestamps(uninitializedProposalId);
      expect(startTimestamp).to.equal(0);
      expect(endTimestamp).to.equal(0);
    });

    it('should return correct start and end timestamps for an initialized proposal', async () => {
      // Initialize the proposal
      const initTx = await linearERC20Voting
        .connect(proposalInitializer)
        .initializeProposal(encodedProposalIdData);
      const receipt = await initTx.wait();
      if (!receipt) throw new Error('Proposal initialization failed');
      const block = await ethers.provider.getBlock(receipt.blockNumber);
      if (!block) throw new Error('Block not found for proposal initialization');

      const expectedStartTimestamp = block.timestamp;
      const expectedEndTimestamp = expectedStartTimestamp + VOTING_PERIOD;

      const [actualStartTimestamp, actualEndTimestamp] =
        await linearERC20Voting.getVotingTimestamps(PROPOSAL_ID);

      expect(actualStartTimestamp).to.equal(expectedStartTimestamp);
      expect(actualEndTimestamp).to.equal(expectedEndTimestamp);
    });

    it('should return updated timestamps if a proposal is re-initialized', async () => {
      // Initial initialization
      await linearERC20Voting
        .connect(proposalInitializer)
        .initializeProposal(encodedProposalIdData);

      // Advance time and re-initialize
      await time.increase(VOTING_PERIOD / 2);
      const reinitTx = await linearERC20Voting
        .connect(proposalInitializer)
        .initializeProposal(encodedProposalIdData);
      const reinitReceipt = await reinitTx.wait();
      if (!reinitReceipt) throw new Error('Proposal re-initialization failed');
      const reinitBlock = await ethers.provider.getBlock(reinitReceipt.blockNumber);
      if (!reinitBlock) throw new Error('Block not found for re-initialization');

      const newExpectedStartTimestamp = reinitBlock.timestamp;
      const newExpectedEndTimestamp = newExpectedStartTimestamp + VOTING_PERIOD;

      const [newActualStartTimestamp, newActualEndTimestamp] =
        await linearERC20Voting.getVotingTimestamps(PROPOSAL_ID);

      expect(newActualStartTimestamp).to.equal(newExpectedStartTimestamp);
      expect(newActualEndTimestamp).to.equal(newExpectedEndTimestamp);
    });
  });

  describe('quorumVotes function', () => {
    const PROPOSAL_ID = 8;
    let encodedProposalIdData: string;
    const INITIAL_TOTAL_SUPPLY = ethers.parseUnits('10000', 18); // 10,000 tokens
    const DEFAULT_QUORUM_NUMERATOR = 300_000; // 30%
    const QUORUM_DENOMINATOR_FROM_CONTRACT = 1_000_000;

    beforeEach(() => {
      encodedProposalIdData = ethers.AbiCoder.defaultAbiCoder().encode(['uint32'], [PROPOSAL_ID]);
    });

    it('should return 0 for an uninitialized proposal', async () => {
      const linearERC20Voting = await deployLinearERC20Voting(
        owner,
        await mockToken.getAddress(),
        proposalInitializer.address,
        lightAccountFactoryMock.target as string,
      );
      // For uninitialized, proposalVotes[id].votingStartTimestamp/Block is 0.
      // mockToken.getPastTotalSupply(0) without prior set will give current supply.
      // So, set past total supply for timepoint 0 to 0 to ensure clean test.
      await mockToken.setPastTotalSupply(0, 0n);
      expect(await linearERC20Voting.quorumVotes(PROPOSAL_ID + 999)).to.equal(0);
    });

    describe('Timestamp mode', () => {
      let linearERC20Voting: LinearERC20VotingV1;
      let tokenTimestamp: MockERC20Votes;
      let proposalStartTimestamp: number;

      beforeEach(async () => {
        tokenTimestamp = await new MockERC20Votes__factory(deployer).deploy();
        await tokenTimestamp.setClockMode(ClockMode.Timestamp);
        await tokenTimestamp.mint(deployer.address, INITIAL_TOTAL_SUPPLY); // Mint to set total supply

        linearERC20Voting = await deployLinearERC20Voting(
          owner,
          await tokenTimestamp.getAddress(),
          proposalInitializer.address,
          lightAccountFactoryMock.target as string,
          VOTING_PERIOD,
          REQUIRED_PROPOSER_WEIGHT,
          DEFAULT_QUORUM_NUMERATOR,
        );

        const initTx = await linearERC20Voting
          .connect(proposalInitializer)
          .initializeProposal(encodedProposalIdData);
        const receipt = await initTx.wait();
        if (!receipt) throw new Error('Proposal init failed');
        const block = await ethers.provider.getBlock(receipt.blockNumber);
        if (!block) throw new Error('Block not found');
        proposalStartTimestamp = block.timestamp;

        await tokenTimestamp.setPastTotalSupply(proposalStartTimestamp, INITIAL_TOTAL_SUPPLY);
      });

      it('should correctly calculate quorum votes based on initial supply and quorum numerator', async () => {
        const expectedQuorumVotes =
          (BigInt(DEFAULT_QUORUM_NUMERATOR) * INITIAL_TOTAL_SUPPLY) /
          BigInt(QUORUM_DENOMINATOR_FROM_CONTRACT);
        expect(await linearERC20Voting.quorumVotes(PROPOSAL_ID)).to.equal(expectedQuorumVotes);
      });

      it('should reflect an updated quorumNumerator in calculation', async () => {
        const newQuorumNumerator = 400_000; // 40%
        await linearERC20Voting.connect(owner).updateQuorumNumerator(newQuorumNumerator);

        const expectedQuorumVotes =
          (BigInt(newQuorumNumerator) * INITIAL_TOTAL_SUPPLY) /
          BigInt(QUORUM_DENOMINATOR_FROM_CONTRACT);
        expect(await linearERC20Voting.quorumVotes(PROPOSAL_ID)).to.equal(expectedQuorumVotes);
      });

      it('should not be affected by total supply changes after proposal initialization', async () => {
        const expectedQuorumVotes =
          (BigInt(DEFAULT_QUORUM_NUMERATOR) * INITIAL_TOTAL_SUPPLY) /
          BigInt(QUORUM_DENOMINATOR_FROM_CONTRACT);
        expect(await linearERC20Voting.quorumVotes(PROPOSAL_ID)).to.equal(expectedQuorumVotes);

        await time.increase(10);
        await tokenTimestamp.mint(deployer.address, ethers.parseUnits('5000', 18)); // Increase total supply

        expect(await linearERC20Voting.quorumVotes(PROPOSAL_ID)).to.equal(expectedQuorumVotes);
      });
    });

    describe('BlockNumber mode', () => {
      let linearERC20Voting: LinearERC20VotingV1;
      let tokenBlockNumber: MockERC20Votes;
      let proposalStartBlock: number;

      beforeEach(async () => {
        tokenBlockNumber = await new MockERC20Votes__factory(deployer).deploy();
        await tokenBlockNumber.setClockMode(ClockMode.BlockNumber);
        await tokenBlockNumber.mint(deployer.address, INITIAL_TOTAL_SUPPLY);

        linearERC20Voting = await deployLinearERC20Voting(
          owner,
          await tokenBlockNumber.getAddress(),
          proposalInitializer.address,
          lightAccountFactoryMock.target as string,
          VOTING_PERIOD,
          REQUIRED_PROPOSER_WEIGHT,
          DEFAULT_QUORUM_NUMERATOR,
        );

        const initTx = await linearERC20Voting
          .connect(proposalInitializer)
          .initializeProposal(encodedProposalIdData);
        const receipt = await initTx.wait();
        if (!receipt) throw new Error('Proposal init failed');
        proposalStartBlock = receipt.blockNumber;

        await tokenBlockNumber.setPastTotalSupply(proposalStartBlock, INITIAL_TOTAL_SUPPLY);
      });

      it('should correctly calculate quorum votes based on initial supply and quorum numerator', async () => {
        const expectedQuorumVotes =
          (BigInt(DEFAULT_QUORUM_NUMERATOR) * INITIAL_TOTAL_SUPPLY) /
          BigInt(QUORUM_DENOMINATOR_FROM_CONTRACT);
        expect(await linearERC20Voting.quorumVotes(PROPOSAL_ID)).to.equal(expectedQuorumVotes);
      });

      it('should reflect an updated quorumNumerator in calculation', async () => {
        const newQuorumNumerator = 600_000; // 60%
        await linearERC20Voting.connect(owner).updateQuorumNumerator(newQuorumNumerator);

        const expectedQuorumVotes =
          (BigInt(newQuorumNumerator) * INITIAL_TOTAL_SUPPLY) /
          BigInt(QUORUM_DENOMINATOR_FROM_CONTRACT);
        expect(await linearERC20Voting.quorumVotes(PROPOSAL_ID)).to.equal(expectedQuorumVotes);
      });

      it('should not be affected by total supply changes after proposal initialization', async () => {
        const expectedQuorumVotes =
          (BigInt(DEFAULT_QUORUM_NUMERATOR) * INITIAL_TOTAL_SUPPLY) /
          BigInt(QUORUM_DENOMINATOR_FROM_CONTRACT);
        expect(await linearERC20Voting.quorumVotes(PROPOSAL_ID)).to.equal(expectedQuorumVotes);

        await mine();
        await tokenBlockNumber.mint(deployer.address, ethers.parseUnits('5000', 18));
        await mine();

        expect(await linearERC20Voting.quorumVotes(PROPOSAL_ID)).to.equal(expectedQuorumVotes);
      });
    });
  });

  describe('meetsQuorum function', () => {
    let linearERC20Voting: LinearERC20VotingV1;
    const TOTAL_SUPPLY = ethers.parseUnits('10000', 18); // 10,000 tokens
    const DEFAULT_QUORUM_NUMERATOR = 300_000; // 30%
    const QUORUM_DENOMINATOR_FROM_CONTRACT = 1_000_000;

    beforeEach(async () => {
      linearERC20Voting = await deployLinearERC20Voting(
        owner,
        await mockToken.getAddress(), // mockToken is suitable as its address is needed, not its state
        proposalInitializer.address,
        lightAccountFactoryMock.target as string,
        VOTING_PERIOD,
        REQUIRED_PROPOSER_WEIGHT,
        DEFAULT_QUORUM_NUMERATOR, // Set the default quorum for the strategy instance
      );
    });

    it('should return true if (yes + abstain) votes are greater than required quorum votes', async () => {
      // Required: 10000 * 30% = 3000
      const yesVotes = ethers.parseUnits('2000', 18);
      const abstainVotes = ethers.parseUnits('1001', 18);
      // Total: 3001 > 3000
      void expect(await linearERC20Voting.meetsQuorum(TOTAL_SUPPLY, yesVotes, abstainVotes)).to.be
        .true;
    });

    it('should return true if (yes + abstain) votes are equal to required quorum votes', async () => {
      // Required: 10000 * 30% = 3000
      const yesVotes = ethers.parseUnits('1500', 18);
      const abstainVotes = ethers.parseUnits('1500', 18);
      // Total: 3000 == 3000
      void expect(await linearERC20Voting.meetsQuorum(TOTAL_SUPPLY, yesVotes, abstainVotes)).to.be
        .true;
    });

    it('should return false if (yes + abstain) votes are less than required quorum votes', async () => {
      // Required: 10000 * 30% = 3000
      const yesVotes = ethers.parseUnits('1000', 18);
      const abstainVotes = ethers.parseUnits('1999', 18);
      // Total: 2999 < 3000
      void expect(await linearERC20Voting.meetsQuorum(TOTAL_SUPPLY, yesVotes, abstainVotes)).to.be
        .false;
    });

    it('should return true if quorumNumerator is 0, even with zero votes', async () => {
      await linearERC20Voting.connect(owner).updateQuorumNumerator(0);
      // Required: 10000 * 0% = 0
      const yesVotes = 0n;
      const abstainVotes = 0n;
      // Total: 0 == 0
      void expect(await linearERC20Voting.meetsQuorum(TOTAL_SUPPLY, yesVotes, abstainVotes)).to.be
        .true;
    });

    it('should return false if quorumNumerator is 100% and (yes + abstain) < total supply', async () => {
      await linearERC20Voting
        .connect(owner)
        .updateQuorumNumerator(QUORUM_DENOMINATOR_FROM_CONTRACT);
      // Required: 10000 * 100% = 10000
      const yesVotes = ethers.parseUnits('5000', 18);
      const abstainVotes = ethers.parseUnits('4999', 18);
      // Total: 9999 < 10000
      void expect(await linearERC20Voting.meetsQuorum(TOTAL_SUPPLY, yesVotes, abstainVotes)).to.be
        .false;
    });

    it('should return true if quorumNumerator is 100% and (yes + abstain) == total supply', async () => {
      await linearERC20Voting
        .connect(owner)
        .updateQuorumNumerator(QUORUM_DENOMINATOR_FROM_CONTRACT);
      // Required: 10000 * 100% = 10000
      const yesVotes = ethers.parseUnits('5000', 18);
      const abstainVotes = ethers.parseUnits('5000', 18);
      // Total: 10000 == 10000
      void expect(await linearERC20Voting.meetsQuorum(TOTAL_SUPPLY, yesVotes, abstainVotes)).to.be
        .true;
    });

    it('should return true if total supply is 0 and quorumNumerator is > 0 (0 votes required)', async () => {
      // Required: 0 * 30% = 0
      const yesVotes = 0n;
      const abstainVotes = 0n;
      void expect(await linearERC20Voting.meetsQuorum(0n, yesVotes, abstainVotes)).to.be.true;
    });

    it('should handle large vote and supply numbers correctly within uint256 limits', async () => {
      const testQuorumNumerator = 500_000n; // 50%
      await linearERC20Voting.connect(owner).updateQuorumNumerator(testQuorumNumerator);

      // Choose largeSupply such that largeSupply * testQuorumNumerator does not overflow ethers.MaxUint256.
      // The largest such supply is ethers.MaxUint256 / testQuorumNumerator.
      const largeSupply = ethers.MaxUint256 / testQuorumNumerator;

      // Calculate the expected required votes threshold.
      // The intermediate product (largeSupply * testQuorumNumerator) in the contract will be approximately ethers.MaxUint256
      // (specifically, ethers.MaxUint256 - (ethers.MaxUint256 % testQuorumNumerator)), which does not overflow.
      const calculatedRequiredVotes =
        (largeSupply * testQuorumNumerator) / BigInt(QUORUM_DENOMINATOR_FROM_CONTRACT);

      // Sanity check: calculatedRequiredVotes should be large and positive as MaxUint256 / DENOMINATOR is large.
      expect(calculatedRequiredVotes).to.be.gt(0n);

      // Case 1: Votes (_yesVotes + _abstainVotes) exactly meet the threshold.
      void expect(await linearERC20Voting.meetsQuorum(largeSupply, calculatedRequiredVotes, 0n)).to
        .be.true;

      // Case 2: Votes barely meet the threshold using a combination.
      // (_yesVotes = calculatedRequiredVotes - 1) + (_abstainVotes = 1) == calculatedRequiredVotes.
      // This sum (calculatedRequiredVotes) will not overflow as it's derived from MaxUint256 / DENOMINATOR.
      void expect(
        await linearERC20Voting.meetsQuorum(largeSupply, calculatedRequiredVotes - 1n, 1n),
      ).to.be.true;

      // Case 3: Votes are one less than the threshold.
      // (_yesVotes = calculatedRequiredVotes - 1) + (_abstainVotes = 0) == calculatedRequiredVotes - 1.
      void expect(
        await linearERC20Voting.meetsQuorum(largeSupply, calculatedRequiredVotes - 1n, 0n),
      ).to.be.false;
    });

    it('should handle scenarios with only YES votes meeting quorum', async () => {
      // Required: 10000 * 30% = 3000
      const yesVotes = ethers.parseUnits('3000', 18);
      const abstainVotes = 0n;
      void expect(await linearERC20Voting.meetsQuorum(TOTAL_SUPPLY, yesVotes, abstainVotes)).to.be
        .true;
    });

    it('should handle scenarios with only ABSTAIN votes meeting quorum', async () => {
      // Required: 10000 * 30% = 3000
      const yesVotes = 0n;
      const abstainVotes = ethers.parseUnits('3000', 18);
      void expect(await linearERC20Voting.meetsQuorum(TOTAL_SUPPLY, yesVotes, abstainVotes)).to.be
        .true;
    });
  });

  describe('meetsBasis function', () => {
    let linearERC20Voting: LinearERC20VotingV1;
    const BASIS_DENOMINATOR_FROM_CONTRACT = 1_000_000;

    async function deployStrategyWithBasis(basisNumerator: number) {
      return deployLinearERC20Voting(
        owner,
        await mockToken.getAddress(),
        proposalInitializer.address,
        lightAccountFactoryMock.target as string,
        VOTING_PERIOD,
        REQUIRED_PROPOSER_WEIGHT,
        QUORUM_NUMERATOR, // Default quorum, not relevant for meetsBasis directly
        basisNumerator,
      );
    }

    it('should return true if yesVotes > ( (yesVotes + noVotes) * basisNumerator / DENOMINATOR ) ', async () => {
      linearERC20Voting = await deployStrategyWithBasis(BASIS_DENOMINATOR_FROM_CONTRACT / 2); // 50% basis
      const yesVotes = ethers.parseUnits('51', 18);
      const noVotes = ethers.parseUnits('49', 18);
      // 51 > ( (51+49) * 0.5 ) => 51 > 50. TRUE
      void expect(await linearERC20Voting.meetsBasis(yesVotes, noVotes)).to.be.true;
    });

    it('should return false if yesVotes == ( (yesVotes + noVotes) * basisNumerator / DENOMINATOR ) due to strict >', async () => {
      linearERC20Voting = await deployStrategyWithBasis(BASIS_DENOMINATOR_FROM_CONTRACT / 2); // 50% basis
      const yesVotes = ethers.parseUnits('50', 18);
      const noVotes = ethers.parseUnits('50', 18);
      // 50 > ( (50+50) * 0.5 ) => 50 > 50. FALSE
      void expect(await linearERC20Voting.meetsBasis(yesVotes, noVotes)).to.be.false;
    });

    it('should return false if yesVotes < ( (yesVotes + noVotes) * basisNumerator / DENOMINATOR ) ', async () => {
      linearERC20Voting = await deployStrategyWithBasis(BASIS_DENOMINATOR_FROM_CONTRACT / 2); // 50% basis
      const yesVotes = ethers.parseUnits('49', 18);
      const noVotes = ethers.parseUnits('51', 18);
      // 49 > ( (49+51) * 0.5 ) => 49 > 50. FALSE
      void expect(await linearERC20Voting.meetsBasis(yesVotes, noVotes)).to.be.false;
    });

    it('should return false with 0 yesVotes and 0 noVotes (0 > 0 is false)', async () => {
      linearERC20Voting = await deployStrategyWithBasis(BASIS_DENOMINATOR_FROM_CONTRACT / 2); // 50% basis
      void expect(await linearERC20Voting.meetsBasis(0n, 0n)).to.be.false;
    });

    it('should return true if only yesVotes exist and basis is < 100%', async () => {
      linearERC20Voting = await deployStrategyWithBasis(BASIS_DENOMINATOR_FROM_CONTRACT / 2); // 50% basis
      const yesVotes = ethers.parseUnits('100', 18);
      // 100 > ( (100+0) * 0.5 ) => 100 > 50. TRUE
      void expect(await linearERC20Voting.meetsBasis(yesVotes, 0n)).to.be.true;
    });

    it('should return false if only noVotes exist (and yesVotes is 0)', async () => {
      linearERC20Voting = await deployStrategyWithBasis(BASIS_DENOMINATOR_FROM_CONTRACT / 2); // 50% basis
      const noVotes = ethers.parseUnits('100', 18);
      // 0 > ( (0+100) * 0.5 ) => 0 > 50. FALSE
      void expect(await linearERC20Voting.meetsBasis(0n, noVotes)).to.be.false;
    });

    describe('with 75% basisNumerator', () => {
      beforeEach(async () => {
        linearERC20Voting = await deployStrategyWithBasis(
          (BASIS_DENOMINATOR_FROM_CONTRACT * 3) / 4,
        ); // 75% basis
      });

      it('should pass if yes are 76, no are 24 (76 > 75)', async () => {
        const yesVotes = ethers.parseUnits('76', 18);
        const noVotes = ethers.parseUnits('24', 18);
        // 76 > ( (76+24) * 0.75 ) => 76 > 75. TRUE
        void expect(await linearERC20Voting.meetsBasis(yesVotes, noVotes)).to.be.true;
      });

      it('should fail if yes are 75, no are 25 (75 > 75 is false)', async () => {
        const yesVotes = ethers.parseUnits('75', 18);
        const noVotes = ethers.parseUnits('25', 18);
        // 75 > ( (75+25) * 0.75 ) => 75 > 75. FALSE
        void expect(await linearERC20Voting.meetsBasis(yesVotes, noVotes)).to.be.false;
      });
    });

    describe('with 100% basisNumerator', () => {
      beforeEach(async () => {
        linearERC20Voting = await deployStrategyWithBasis(BASIS_DENOMINATOR_FROM_CONTRACT); // 100% basis
      });

      it('should fail if only yesVotes exist (e.g., 100 YES, 0 NO -> 100 > 100 is false)', async () => {
        const yesVotes = ethers.parseUnits('100', 18);
        // 100 > ( (100+0) * 1.0 ) => 100 > 100. FALSE
        void expect(await linearERC20Voting.meetsBasis(yesVotes, 0n)).to.be.false;
      });

      it('should fail if any noVotes exist (e.g., 100 YES, 1 NO -> 100 > 101 is false)', async () => {
        const yesVotes = ethers.parseUnits('100', 18);
        const noVotes = ethers.parseUnits('1', 18);
        // 100 > ( (100+1) * 1.0 ) => 100 > 101. FALSE
        void expect(await linearERC20Voting.meetsBasis(yesVotes, noVotes)).to.be.false;
      });

      it('should fail with 0 yesVotes and 0 noVotes (0 > 0 is false)', async () => {
        void expect(await linearERC20Voting.meetsBasis(0n, 0n)).to.be.false;
      });
    });
  });
});
