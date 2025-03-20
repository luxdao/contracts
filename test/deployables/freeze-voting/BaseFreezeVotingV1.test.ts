import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { mine } from '@nomicfoundation/hardhat-network-helpers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  ConcreteBaseFreezeVotingV1,
  ConcreteBaseFreezeVotingV1__factory,
  ERC1967Proxy__factory,
  IBaseFreezeVotingV1__factory,
  IERC165__factory,
} from '../../../typechain-types';
import { calculateInterfaceId } from '../../helpers/utils';
import { runUUPSUpgradeabilityTests } from '../../helpers/uupsUpgradeabilityTests';

// Helper function for deploying ConcreteBaseFreezeVoting instances using ERC1967Proxy
async function deployConcreteBaseFreezeVotingProxy(
  proxyDeployer: SignerWithAddress,
  implementation: string,
  owner: SignerWithAddress,
  freezeVotesThreshold: number,
  freezeProposalPeriod: number,
  freezePeriod: number,
): Promise<ConcreteBaseFreezeVotingV1> {
  // Combine selector and encoded params
  const fullInitData =
    ConcreteBaseFreezeVotingV1__factory.createInterface().getFunction('initialize').selector +
    ethers.AbiCoder.defaultAbiCoder()
      .encode(
        ['address', 'uint256', 'uint32', 'uint32'],
        [owner.address, freezeVotesThreshold, freezeProposalPeriod, freezePeriod],
      )
      .slice(2);

  // Deploy the proxy with the implementation
  const proxy = await new ERC1967Proxy__factory(proxyDeployer).deploy(implementation, fullInitData);

  // Return a contract instance connected to the proxy
  return ConcreteBaseFreezeVotingV1__factory.connect(await proxy.getAddress(), owner);
}

describe('BaseFreezeVotingV1', () => {
  // signers
  let proxyDeployer: SignerWithAddress;
  let owner: SignerWithAddress;
  let voter1: SignerWithAddress;
  let voter2: SignerWithAddress;
  let voter3: SignerWithAddress;
  let nonOwner: SignerWithAddress;

  // contracts
  let masterCopy: string;
  let freezeVoting: ConcreteBaseFreezeVotingV1;

  // constants
  const FREEZE_VOTES_THRESHOLD = 3;
  const FREEZE_PROPOSAL_PERIOD = 5;
  const FREEZE_PERIOD = 10;

  beforeEach(async () => {
    // Get signers
    [proxyDeployer, owner, voter1, voter2, voter3, nonOwner] = await ethers.getSigners();

    // Deploy implementation
    const implementation = await new ConcreteBaseFreezeVotingV1__factory(proxyDeployer).deploy();
    masterCopy = await implementation.getAddress();

    // Deploy proxy
    freezeVoting = await deployConcreteBaseFreezeVotingProxy(
      proxyDeployer,
      masterCopy,
      owner,
      FREEZE_VOTES_THRESHOLD,
      FREEZE_PROPOSAL_PERIOD,
      FREEZE_PERIOD,
    );
  });

  describe('Initialization', () => {
    it('should initialize with correct parameters', async () => {
      expect(await freezeVoting.owner()).to.equal(owner.address);
      expect(await freezeVoting.freezeVotesThreshold()).to.equal(FREEZE_VOTES_THRESHOLD);
      expect(await freezeVoting.freezeProposalPeriod()).to.equal(FREEZE_PROPOSAL_PERIOD);
      expect(await freezeVoting.freezePeriod()).to.equal(FREEZE_PERIOD);
    });

    it('should not allow reinitialization', async () => {
      await expect(
        freezeVoting.initialize(
          owner.address,
          FREEZE_VOTES_THRESHOLD,
          FREEZE_PROPOSAL_PERIOD,
          FREEZE_PERIOD,
        ),
      ).to.be.revertedWithCustomError(freezeVoting, 'InvalidInitialization');
    });

    it('Should have initialization disabled in the implementation', async function () {
      const implementationContract = ConcreteBaseFreezeVotingV1__factory.connect(
        masterCopy,
        proxyDeployer,
      ) as any;

      await expect(
        implementationContract.initialize(
          owner.address,
          FREEZE_VOTES_THRESHOLD,
          FREEZE_PROPOSAL_PERIOD,
          FREEZE_PERIOD,
        ),
      ).to.be.revertedWithCustomError(implementationContract, 'InvalidInitialization');
    });
  });

  describe('Freeze Voting Process', () => {
    it('should create a freeze proposal on first vote', async () => {
      // Initial state
      expect(await freezeVoting.freezeProposalCreatedBlock()).to.equal(0);
      expect(await freezeVoting.freezeProposalVoteCount()).to.equal(0);

      // First vote creates the proposal
      await expect(freezeVoting.connect(voter1).castFreezeVote())
        .to.emit(freezeVoting, 'FreezeProposalCreated')
        .withArgs(voter1.address)
        .and.to.emit(freezeVoting, 'FreezeVoteCast')
        .withArgs(voter1.address, 1);

      // Check state after first vote
      const currentBlock = await ethers.provider.getBlockNumber();
      expect(await freezeVoting.freezeProposalCreatedBlock()).to.equal(currentBlock);
      expect(await freezeVoting.freezeProposalVoteCount()).to.equal(1);
    });

    it('should accumulate votes correctly', async () => {
      // First vote
      await freezeVoting.connect(voter1).castFreezeVote();
      expect(await freezeVoting.freezeProposalVoteCount()).to.equal(1);

      // Second vote
      await freezeVoting.connect(voter2).castFreezeVote();
      expect(await freezeVoting.freezeProposalVoteCount()).to.equal(2);

      // Third vote
      await freezeVoting.connect(voter3).castFreezeVote();
      expect(await freezeVoting.freezeProposalVoteCount()).to.equal(3);
    });

    it('should prevent duplicate votes from the same user', async () => {
      // First vote
      await freezeVoting.connect(voter1).castFreezeVote();
      expect(await freezeVoting.freezeProposalVoteCount()).to.equal(1);

      // Attempting to vote again should fail
      await expect(freezeVoting.connect(voter1).castFreezeVote()).to.be.revertedWith(
        'Already voted',
      );

      // Vote count should remain unchanged
      expect(await freezeVoting.freezeProposalVoteCount()).to.equal(1);
    });

    it('should reject votes after proposal period expiry', async () => {
      // First vote to create proposal
      await freezeVoting.connect(voter1).castFreezeVote();

      // Mine blocks to pass the freeze proposal period
      await mine(FREEZE_PROPOSAL_PERIOD + 1);

      // New vote should be rejected
      await expect(freezeVoting.connect(voter2).castFreezeVote()).to.be.revertedWith(
        'Freeze proposal period expired',
      );
    });
  });

  describe('Freeze State', () => {
    it('should not be frozen initially', async () => {
      void expect(await freezeVoting.isFrozen()).to.be.false;
    });

    it('should not be frozen when below threshold', async () => {
      // With threshold of 3, cast only 2 votes
      await freezeVoting.connect(voter1).castFreezeVote();
      await freezeVoting.connect(voter2).castFreezeVote();

      // Should not be frozen yet
      void expect(await freezeVoting.isFrozen()).to.be.false;
    });

    it('should be frozen once threshold is met', async () => {
      // Cast enough votes to meet threshold
      await freezeVoting.connect(voter1).castFreezeVote();
      await freezeVoting.connect(voter2).castFreezeVote();
      await freezeVoting.connect(voter3).castFreezeVote();

      // Should now be frozen
      void expect(await freezeVoting.isFrozen()).to.be.true;
    });

    it('should automatically unfreeze after freeze period', async () => {
      // Cast enough votes to meet threshold
      await freezeVoting.connect(voter1).castFreezeVote();
      await freezeVoting.connect(voter2).castFreezeVote();
      await freezeVoting.connect(voter3).castFreezeVote();

      // Should be frozen initially
      void expect(await freezeVoting.isFrozen()).to.be.true;

      // Mine blocks to pass the freeze period
      await mine(FREEZE_PERIOD + 1);

      // Should no longer be frozen
      void expect(await freezeVoting.isFrozen()).to.be.false;
    });

    it('should allow owner to unfreeze manually', async () => {
      // Cast enough votes to meet threshold
      await freezeVoting.connect(voter1).castFreezeVote();
      await freezeVoting.connect(voter2).castFreezeVote();
      await freezeVoting.connect(voter3).castFreezeVote();

      // Should be frozen
      void expect(await freezeVoting.isFrozen()).to.be.true;

      // Owner unfreezes manually
      await freezeVoting.connect(owner).unfreeze();

      // Should no longer be frozen
      void expect(await freezeVoting.isFrozen()).to.be.false;

      // Check that state was reset
      expect(await freezeVoting.freezeProposalCreatedBlock()).to.equal(0);
      expect(await freezeVoting.freezeProposalVoteCount()).to.equal(0);
    });

    it('should not allow non-owner to unfreeze', async () => {
      // Cast enough votes to meet threshold
      await freezeVoting.connect(voter1).castFreezeVote();
      await freezeVoting.connect(voter2).castFreezeVote();
      await freezeVoting.connect(voter3).castFreezeVote();

      // Non-owner tries to unfreeze
      await expect(freezeVoting.connect(voter1).unfreeze()).to.be.revertedWithCustomError(
        freezeVoting,
        'OwnableUnauthorizedAccount',
      );

      // Should still be frozen
      void expect(await freezeVoting.isFrozen()).to.be.true;
    });

    it('should track freeze status across multiple proposals', async () => {
      // First proposal: get enough votes to freeze
      await freezeVoting.connect(voter1).castFreezeVote();
      await freezeVoting.connect(voter2).castFreezeVote();
      await freezeVoting.connect(voter3).castFreezeVote();

      // DAO should be frozen
      void expect(await freezeVoting.isFrozen()).to.be.true;

      // Owner unfreezes manually
      await freezeVoting.connect(owner).unfreeze();

      // DAO should not be frozen
      void expect(await freezeVoting.isFrozen()).to.be.false;

      // Start a new proposal with not enough votes
      await freezeVoting.connect(voter1).castFreezeVote();
      await freezeVoting.connect(voter2).castFreezeVote();

      // DAO should not be frozen with only 2 votes
      void expect(await freezeVoting.isFrozen()).to.be.false;

      // Add the third vote to reach threshold
      await freezeVoting.connect(voter3).castFreezeVote();

      // DAO should be frozen again
      void expect(await freezeVoting.isFrozen()).to.be.true;
    });
  });

  describe('Parameter Updates', () => {
    it('should allow owner to update freezeVotesThreshold', async () => {
      const newThreshold = 5;

      await expect(freezeVoting.connect(owner).updateFreezeVotesThreshold(newThreshold))
        .to.emit(freezeVoting, 'FreezeVotesThresholdUpdated')
        .withArgs(newThreshold);

      expect(await freezeVoting.freezeVotesThreshold()).to.equal(newThreshold);
    });

    it('should allow owner to update freezeProposalPeriod', async () => {
      const newPeriod = 15;

      await expect(freezeVoting.connect(owner).updateFreezeProposalPeriod(newPeriod))
        .to.emit(freezeVoting, 'FreezeProposalPeriodUpdated')
        .withArgs(newPeriod);

      expect(await freezeVoting.freezeProposalPeriod()).to.equal(newPeriod);
    });

    it('should allow owner to update freezePeriod', async () => {
      const newPeriod = 20;

      await expect(freezeVoting.connect(owner).updateFreezePeriod(newPeriod))
        .to.emit(freezeVoting, 'FreezePeriodUpdated')
        .withArgs(newPeriod);

      expect(await freezeVoting.freezePeriod()).to.equal(newPeriod);
    });

    it('should not allow non-owner to update freezeVotesThreshold', async () => {
      await expect(
        freezeVoting.connect(voter1).updateFreezeVotesThreshold(5),
      ).to.be.revertedWithCustomError(freezeVoting, 'OwnableUnauthorizedAccount');
    });

    it('should not allow non-owner to update freezeProposalPeriod', async () => {
      await expect(
        freezeVoting.connect(voter1).updateFreezeProposalPeriod(15),
      ).to.be.revertedWithCustomError(freezeVoting, 'OwnableUnauthorizedAccount');
    });

    it('should not allow non-owner to update freezePeriod', async () => {
      await expect(
        freezeVoting.connect(voter1).updateFreezePeriod(20),
      ).to.be.revertedWithCustomError(freezeVoting, 'OwnableUnauthorizedAccount');
    });

    it('should affect freeze status when threshold is updated', async () => {
      // Cast votes but below the new threshold we'll set
      await freezeVoting.connect(voter1).castFreezeVote();
      await freezeVoting.connect(voter2).castFreezeVote();
      await freezeVoting.connect(voter3).castFreezeVote();

      // Should be frozen with the default threshold of 3
      void expect(await freezeVoting.isFrozen()).to.be.true;

      // Increase threshold to 4
      await freezeVoting.connect(owner).updateFreezeVotesThreshold(4);

      // Should no longer be frozen as we're below the new threshold
      void expect(await freezeVoting.isFrozen()).to.be.false;
    });
  });

  describe('User Has Voted Tracking', () => {
    it('should correctly track if a user has voted on a proposal', async () => {
      // Initial state - user has not voted
      const createdBlock = await freezeVoting.freezeProposalCreatedBlock();
      void expect(await freezeVoting.userHasFreezeVoted(voter1.address, createdBlock)).to.be.false;

      // User votes
      await freezeVoting.connect(voter1).castFreezeVote();

      // Updated state - user has voted
      const newCreatedBlock = await freezeVoting.freezeProposalCreatedBlock();
      void expect(await freezeVoting.userHasFreezeVoted(voter1.address, newCreatedBlock)).to.be
        .true;
    });

    it('should reset user voting status when unfreeze is called', async () => {
      // User votes
      await freezeVoting.connect(voter1).castFreezeVote();

      // Get the created block number
      const createdBlock = await freezeVoting.freezeProposalCreatedBlock();

      // Check that user has voted
      void expect(await freezeVoting.userHasFreezeVoted(voter1.address, createdBlock)).to.be.true;

      // Owner unfreezes
      await freezeVoting.connect(owner).unfreeze();

      // The createdBlock is now 0, so the voting status should be reset
      expect(await freezeVoting.freezeProposalCreatedBlock()).to.equal(0);

      // User should be able to vote again on a new proposal
      await freezeVoting.connect(voter1).castFreezeVote();

      // Get the new created block number
      const newCreatedBlock = await freezeVoting.freezeProposalCreatedBlock();

      // Check that user has voted on the new proposal
      void expect(await freezeVoting.userHasFreezeVoted(voter1.address, newCreatedBlock)).to.be
        .true;
    });
  });

  describe('ERC165', function () {
    let iBaseFreezeVotingV1InterfaceId: string;
    let iERC165InterfaceId: string;

    beforeEach(async function () {
      // Dynamically calculate interface IDs
      const IBaseFreezeVotingV1Interface = IBaseFreezeVotingV1__factory.createInterface();
      iBaseFreezeVotingV1InterfaceId = calculateInterfaceId(IBaseFreezeVotingV1Interface);

      const IERC165Interface = IERC165__factory.createInterface();
      iERC165InterfaceId = calculateInterfaceId(IERC165Interface);
    });

    it('Should support IERC165 interface', async function () {
      // Cast the freezeVoting instance to any type to bypass TypeScript checking
      // since we know the actual contract implements supportsInterface
      const supported = await freezeVoting.supportsInterface(iERC165InterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should support IBaseFreezeVotingV1 interface', async function () {
      const supported = await freezeVoting.supportsInterface(iBaseFreezeVotingV1InterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should not support random interface', async function () {
      const randomInterfaceId = '0x12345678';
      const supported = await freezeVoting.supportsInterface(randomInterfaceId);
      void expect(supported).to.be.false;
    });
  });

  describe('UUPS Upgradeability', function () {
    runUUPSUpgradeabilityTests({
      getContract: () => freezeVoting,
      createNewImplementation: async () => {
        const newImplementation = await new ConcreteBaseFreezeVotingV1__factory(owner).deploy();
        return newImplementation;
      },
      owner: () => owner,
      nonOwner: () => nonOwner,
    });
  });
});
