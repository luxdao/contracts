import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { mine, time } from '@nomicfoundation/hardhat-network-helpers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  ERC20FreezeVotingV1,
  ERC20FreezeVotingV1__factory,
  MockERC20Votes,
  MockERC20Votes__factory,
} from '../../../typechain-types';
import { getModuleProxyFactory } from '../../global/GlobalSafeDeployments.test';
import { calculateProxyAddress } from '../../helpers';

// Helper function for deploying ERC20FreezeVotingV1 instances
async function deployERC20FreezeVotingProxy(
  erc20FreezeVotingMastercopy: ERC20FreezeVotingV1,
  owner: SignerWithAddress,
  freezeVotesThreshold: number,
  freezeProposalPeriod: number,
  freezePeriod: number,
  votesERC20: MockERC20Votes,
): Promise<ERC20FreezeVotingV1> {
  const moduleProxyFactory = getModuleProxyFactory();
  const salt = ethers.hexlify(ethers.randomBytes(32));

  const erc20FreezeVotingSetupCalldata =
    ERC20FreezeVotingV1__factory.createInterface().encodeFunctionData('setUp', [
      ethers.AbiCoder.defaultAbiCoder().encode(
        ['address', 'uint256', 'uint32', 'uint32', 'address'],
        [
          owner.address,
          freezeVotesThreshold,
          freezeProposalPeriod,
          freezePeriod,
          await votesERC20.getAddress(),
        ],
      ),
    ]);

  await moduleProxyFactory.deployModule(
    await erc20FreezeVotingMastercopy.getAddress(),
    erc20FreezeVotingSetupCalldata,
    salt,
  );

  const predictedAddress = await calculateProxyAddress(
    moduleProxyFactory,
    await erc20FreezeVotingMastercopy.getAddress(),
    erc20FreezeVotingSetupCalldata,
    salt,
  );

  return ERC20FreezeVotingV1__factory.connect(predictedAddress, owner);
}

describe('ERC20FreezeVotingV1', () => {
  // signers
  let deployer: SignerWithAddress;
  let owner: SignerWithAddress;
  let voter1: SignerWithAddress;
  let voter2: SignerWithAddress;
  let voter3: SignerWithAddress;
  let nonVoter: SignerWithAddress;

  // contracts
  let erc20FreezeVotingMastercopy: ERC20FreezeVotingV1;
  let freezeVoting: ERC20FreezeVotingV1;
  let votesToken: MockERC20Votes;

  // constants
  const FREEZE_VOTES_THRESHOLD = 300; // For ERC20, we use larger numbers
  const FREEZE_PROPOSAL_PERIOD = 5;
  const FREEZE_PERIOD = 10;

  // voter token balances
  const VOTER1_TOKENS = 100;
  const VOTER2_TOKENS = 150;
  const VOTER3_TOKENS = 200;

  beforeEach(async () => {
    // Get signers
    [deployer, owner, voter1, voter2, voter3, nonVoter] = await ethers.getSigners();

    // Deploy the voting token
    votesToken = await new MockERC20Votes__factory(deployer).deploy();

    // Mint tokens to voters
    await votesToken.mint(voter1.address, VOTER1_TOKENS);
    await votesToken.mint(voter2.address, VOTER2_TOKENS);
    await votesToken.mint(voter3.address, VOTER3_TOKENS);

    // Let them delegate to themselves for voting power
    await votesToken.connect(voter1).delegate(voter1.address);
    await votesToken.connect(voter2).delegate(voter2.address);
    await votesToken.connect(voter3).delegate(voter3.address);

    // Deploy mastercopy
    erc20FreezeVotingMastercopy = await new ERC20FreezeVotingV1__factory(deployer).deploy();

    // Deploy proxy
    freezeVoting = await deployERC20FreezeVotingProxy(
      erc20FreezeVotingMastercopy,
      owner,
      FREEZE_VOTES_THRESHOLD,
      FREEZE_PROPOSAL_PERIOD,
      FREEZE_PERIOD,
      votesToken,
    );
  });

  describe('Initialization', () => {
    it('should initialize with correct parameters', async () => {
      expect(await freezeVoting.owner()).to.equal(owner.address);
      expect(await freezeVoting.freezeVotesThreshold()).to.equal(FREEZE_VOTES_THRESHOLD);
      expect(await freezeVoting.freezeProposalPeriod()).to.equal(FREEZE_PROPOSAL_PERIOD);
      expect(await freezeVoting.freezePeriod()).to.equal(FREEZE_PERIOD);
      expect(await freezeVoting.votesERC20()).to.equal(await votesToken.getAddress());
    });

    it('should not allow reinitialization', async () => {
      const setupData = ethers.AbiCoder.defaultAbiCoder().encode(
        ['address', 'uint256', 'uint32', 'uint32', 'address'],
        [
          owner.address,
          FREEZE_VOTES_THRESHOLD,
          FREEZE_PROPOSAL_PERIOD,
          FREEZE_PERIOD,
          await votesToken.getAddress(),
        ],
      );

      await expect(freezeVoting.setUp(setupData)).to.be.revertedWithCustomError(
        freezeVoting,
        'InvalidInitialization',
      );
    });
  });

  describe('Freeze Voting Process', () => {
    it('should reject votes from users with no voting power', async () => {
      await expect(freezeVoting.connect(nonVoter).castFreezeVote()).to.be.revertedWithCustomError(
        freezeVoting,
        'NoVotes',
      );
    });

    it('should create a freeze proposal when first user votes', async () => {
      // Set up mock past votes for the block
      const voteBlock = await time.latestBlock();
      await votesToken.setPastVotes(voter1.address, voteBlock, VOTER1_TOKENS);

      // Cast the first vote
      await expect(freezeVoting.connect(voter1).castFreezeVote())
        .to.emit(freezeVoting, 'FreezeProposalCreated')
        .withArgs(voter1.address)
        .and.to.emit(freezeVoting, 'FreezeVoteCast')
        .withArgs(voter1.address, VOTER1_TOKENS);

      // Check state after vote
      expect(await freezeVoting.freezeProposalCreatedBlock()).to.be.gt(0); // Just check that a block was recorded
      expect(await freezeVoting.freezeProposalVoteCount()).to.equal(VOTER1_TOKENS);
    });

    it('should accumulate votes correctly based on token balances', async () => {
      // Set up mock past votes for voters
      const voteBlock = await time.latestBlock();
      await votesToken.setPastVotes(voter1.address, voteBlock, VOTER1_TOKENS);
      await votesToken.setPastVotes(voter2.address, voteBlock, VOTER2_TOKENS);
      await votesToken.setPastVotes(voter3.address, voteBlock, VOTER3_TOKENS);

      // First vote
      await freezeVoting.connect(voter1).castFreezeVote();
      expect(await freezeVoting.freezeProposalVoteCount()).to.equal(VOTER1_TOKENS);

      // Second vote
      await freezeVoting.connect(voter2).castFreezeVote();
      expect(await freezeVoting.freezeProposalVoteCount()).to.equal(VOTER1_TOKENS + VOTER2_TOKENS);

      // Third vote
      await freezeVoting.connect(voter3).castFreezeVote();
      expect(await freezeVoting.freezeProposalVoteCount()).to.equal(
        VOTER1_TOKENS + VOTER2_TOKENS + VOTER3_TOKENS,
      );
    });

    it('should prevent duplicate votes from the same user', async () => {
      // Set up mock past votes for the vote block
      const voteBlock = await time.latestBlock();
      await votesToken.setPastVotes(voter1.address, voteBlock, VOTER1_TOKENS);

      // First vote
      await freezeVoting.connect(voter1).castFreezeVote();

      // Attempting to vote again should fail
      await expect(freezeVoting.connect(voter1).castFreezeVote()).to.be.revertedWithCustomError(
        freezeVoting,
        'AlreadyVoted',
      );
    });

    it('should reject votes after proposal period expiry', async () => {
      // Set up mock past votes for voters
      const voteBlock = await time.latestBlock();
      await votesToken.setPastVotes(voter1.address, voteBlock, VOTER1_TOKENS);
      await votesToken.setPastVotes(voter2.address, voteBlock, VOTER2_TOKENS);

      // First vote to create proposal
      await freezeVoting.connect(voter1).castFreezeVote();

      // Mine blocks to pass the freeze proposal period
      await mine(FREEZE_PROPOSAL_PERIOD + 1);

      // Second vote should create a new proposal, not add to the expired one
      const voteBlock2 = await time.latestBlock();
      await votesToken.setPastVotes(voter2.address, voteBlock2, VOTER2_TOKENS);

      await expect(freezeVoting.connect(voter2).castFreezeVote())
        .to.emit(freezeVoting, 'FreezeProposalCreated')
        .withArgs(voter2.address);

      // Vote count should reset to just voter2's votes
      expect(await freezeVoting.freezeProposalVoteCount()).to.equal(VOTER2_TOKENS);
    });
  });

  describe('Freeze State', () => {
    beforeEach(async () => {
      // Set up mock past votes for all voters
      const voteBlock = await time.latestBlock();
      await votesToken.setPastVotes(voter1.address, voteBlock, VOTER1_TOKENS);
      await votesToken.setPastVotes(voter2.address, voteBlock, VOTER2_TOKENS);
      await votesToken.setPastVotes(voter3.address, voteBlock, VOTER3_TOKENS);
    });

    it('should not be frozen initially', async () => {
      void expect(await freezeVoting.isFrozen()).to.be.false;
    });

    it('should not be frozen when below threshold', async () => {
      // With threshold of 300, cast only 250 votes (voter1 + voter2)
      await freezeVoting.connect(voter1).castFreezeVote();
      await freezeVoting.connect(voter2).castFreezeVote();

      // Total votes: 100 + 150 = 250, below threshold of 300
      void expect(await freezeVoting.isFrozen()).to.be.false;
    });

    it('should be frozen once threshold is met', async () => {
      // With threshold of 300, cast all votes (voter1 + voter2 + voter3)
      await freezeVoting.connect(voter1).castFreezeVote();
      await freezeVoting.connect(voter2).castFreezeVote();
      await freezeVoting.connect(voter3).castFreezeVote();

      // Total votes: 100 + 150 + 200 = 450, above threshold of 300
      void expect(await freezeVoting.isFrozen()).to.be.true;
    });

    it('should automatically unfreeze after freeze period', async () => {
      // Cast enough votes to exceed threshold
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
      // Cast enough votes to exceed threshold
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
      // Cast enough votes to exceed threshold
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

      // Set up mock past votes for new proposal
      const newVoteBlock = await time.latestBlock();
      await votesToken.setPastVotes(voter1.address, newVoteBlock, VOTER1_TOKENS);
      await votesToken.setPastVotes(voter2.address, newVoteBlock, VOTER2_TOKENS);

      // Start a new proposal with not enough votes
      await freezeVoting.connect(voter1).castFreezeVote();
      await freezeVoting.connect(voter2).castFreezeVote();

      // DAO should not be frozen with only voter1 + voter2 votes
      void expect(await freezeVoting.isFrozen()).to.be.false;

      // Set up mock past votes for voter3
      const finalVoteBlock = await time.latestBlock();
      await votesToken.setPastVotes(voter3.address, finalVoteBlock, VOTER3_TOKENS);

      // Add the third vote to reach threshold
      await freezeVoting.connect(voter3).castFreezeVote();

      // DAO should be frozen again
      void expect(await freezeVoting.isFrozen()).to.be.true;
    });
  });

  describe('Parameter Updates', () => {
    it('should allow owner to update freezeVotesThreshold', async () => {
      const newThreshold = 500;

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
        freezeVoting.connect(voter1).updateFreezeVotesThreshold(500),
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
      // Set up mock past votes for all voters
      const voteBlock = await time.latestBlock();
      await votesToken.setPastVotes(voter1.address, voteBlock, VOTER1_TOKENS);
      await votesToken.setPastVotes(voter2.address, voteBlock, VOTER2_TOKENS);
      await votesToken.setPastVotes(voter3.address, voteBlock, VOTER3_TOKENS);

      // Cast votes to meet the threshold of 300
      await freezeVoting.connect(voter1).castFreezeVote();
      await freezeVoting.connect(voter2).castFreezeVote();
      await freezeVoting.connect(voter3).castFreezeVote();

      // Total votes: 100 + 150 + 200 = 450, above threshold of 300
      void expect(await freezeVoting.isFrozen()).to.be.true;

      // Increase threshold to 500
      await freezeVoting.connect(owner).updateFreezeVotesThreshold(500);

      // Should no longer be frozen as 450 < 500
      void expect(await freezeVoting.isFrozen()).to.be.false;
    });
  });

  describe('User Has Voted Tracking', () => {
    beforeEach(async () => {
      // Set up mock past votes for voter1
      const voteBlock = await time.latestBlock();
      await votesToken.setPastVotes(voter1.address, voteBlock, VOTER1_TOKENS);
    });

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

      // Set up mock past votes for the new block
      const newVoteBlock = await time.latestBlock();
      await votesToken.setPastVotes(voter1.address, newVoteBlock, VOTER1_TOKENS);

      // User should be able to vote again on a new proposal
      await freezeVoting.connect(voter1).castFreezeVote();

      // Get the new created block number
      const newCreatedBlock = await freezeVoting.freezeProposalCreatedBlock();

      // Check that user has voted on the new proposal
      void expect(await freezeVoting.userHasFreezeVoted(voter1.address, newCreatedBlock)).to.be
        .true;
    });
  });

  describe('Version', () => {
    it('should return correct version', async () => {
      expect(await freezeVoting.getVersion()).to.equal(1);
    });
  });
});
