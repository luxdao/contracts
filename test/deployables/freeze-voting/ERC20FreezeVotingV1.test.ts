import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { time } from '@nomicfoundation/hardhat-network-helpers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  ERC1967Proxy__factory,
  ERC20FreezeVotingV1,
  ERC20FreezeVotingV1__factory,
  IBaseFreezeVotingV1__factory,
  IERC165__factory,
  IERC20FreezeVotingV1__factory,
  IVersion__factory,
  MockERC20Votes,
  MockERC20Votes__factory,
} from '../../../typechain-types';
import { calculateInterfaceId } from '../../helpers/utils';

// Helper function for deploying ERC20FreezeVotingV1 instances using ERC1967Proxy
async function deployERC20FreezeVotingProxy(
  proxyDeployer: SignerWithAddress,
  implementation: string,
  owner: SignerWithAddress,
  freezeVotesThreshold: number,
  freezeProposalPeriod: number,
  freezePeriod: number,
  votesERC20: MockERC20Votes,
): Promise<ERC20FreezeVotingV1> {
  // Combine selector and encoded params
  const fullInitData =
    ERC20FreezeVotingV1__factory.createInterface().getFunction('initialize').selector +
    ethers.AbiCoder.defaultAbiCoder()
      .encode(
        ['address', 'uint256', 'uint32', 'uint32', 'address'],
        [
          owner.address,
          freezeVotesThreshold,
          freezeProposalPeriod,
          freezePeriod,
          await votesERC20.getAddress(),
        ],
      )
      .slice(2);

  // Deploy the proxy with the implementation
  const proxy = await new ERC1967Proxy__factory(proxyDeployer).deploy(implementation, fullInitData);

  // Return a contract instance connected to the proxy
  return ERC20FreezeVotingV1__factory.connect(await proxy.getAddress(), owner);
}

describe('ERC20FreezeVotingV1', () => {
  // signers
  let proxyDeployer: SignerWithAddress;
  let owner: SignerWithAddress;
  let voter1: SignerWithAddress;
  let voter2: SignerWithAddress;
  let voter3: SignerWithAddress;
  let nonVoter: SignerWithAddress;

  // contracts
  let masterCopy: string;
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
    [proxyDeployer, owner, voter1, voter2, voter3, nonVoter] = await ethers.getSigners();

    // Deploy the voting token
    votesToken = await new MockERC20Votes__factory(proxyDeployer).deploy();

    // Mint tokens to voters
    await votesToken.mint(voter1.address, VOTER1_TOKENS);
    await votesToken.mint(voter2.address, VOTER2_TOKENS);
    await votesToken.mint(voter3.address, VOTER3_TOKENS);

    // Let them delegate to themselves for voting power
    await votesToken.connect(voter1).delegate(voter1.address);
    await votesToken.connect(voter2).delegate(voter2.address);
    await votesToken.connect(voter3).delegate(voter3.address);

    // Deploy implementation
    const implementation = await new ERC20FreezeVotingV1__factory(proxyDeployer).deploy();
    masterCopy = await implementation.getAddress();

    // Deploy proxy
    freezeVoting = await deployERC20FreezeVotingProxy(
      proxyDeployer,
      masterCopy,
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
      await expect(
        freezeVoting.initialize(
          owner.address,
          FREEZE_VOTES_THRESHOLD,
          FREEZE_PROPOSAL_PERIOD,
          FREEZE_PERIOD,
          await votesToken.getAddress(),
        ),
      ).to.be.revertedWithCustomError(freezeVoting, 'InvalidInitialization');
    });

    it('Should have initialization disabled in the implementation', async function () {
      const implementationContract = ERC20FreezeVotingV1__factory.connect(
        masterCopy,
        proxyDeployer,
      ) as any;

      await expect(
        implementationContract.initialize(
          owner.address,
          FREEZE_VOTES_THRESHOLD,
          FREEZE_PROPOSAL_PERIOD,
          FREEZE_PERIOD,
          await votesToken.getAddress(),
        ),
      ).to.be.revertedWithCustomError(implementationContract, 'InvalidInitialization');
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
      // Set up mock past votes for the timestamp
      const voteTimestamp = await time.latest();
      await votesToken.setPastVotes(voter1.address, voteTimestamp, VOTER1_TOKENS);

      // Cast the first vote
      await expect(freezeVoting.connect(voter1).castFreezeVote())
        .to.emit(freezeVoting, 'FreezeProposalCreated')
        .withArgs(voter1.address)
        .and.to.emit(freezeVoting, 'FreezeVoteCast')
        .withArgs(voter1.address, VOTER1_TOKENS);

      // Check state after vote
      expect(await freezeVoting.freezeProposalCreated()).to.be.gt(0); // Just check that a timestamp was recorded
      expect(await freezeVoting.freezeProposalVoteCount()).to.equal(VOTER1_TOKENS);
    });

    it('should accumulate votes correctly based on token balances', async () => {
      // Set up mock past votes for voters
      const voteTimestamp = await time.latest();
      await votesToken.setPastVotes(voter1.address, voteTimestamp, VOTER1_TOKENS);
      await votesToken.setPastVotes(voter2.address, voteTimestamp, VOTER2_TOKENS);
      await votesToken.setPastVotes(voter3.address, voteTimestamp, VOTER3_TOKENS);

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
      // Set up mock past votes for the vote timestamp
      const voteTimestamp = await time.latest();
      await votesToken.setPastVotes(voter1.address, voteTimestamp, VOTER1_TOKENS);

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
      const voteTimestamp = await time.latest();
      await votesToken.setPastVotes(voter1.address, voteTimestamp, VOTER1_TOKENS);
      await votesToken.setPastVotes(voter2.address, voteTimestamp, VOTER2_TOKENS);

      // First vote to create proposal
      await freezeVoting.connect(voter1).castFreezeVote();

      // Increase time to pass the freeze proposal period
      await time.increase(FREEZE_PROPOSAL_PERIOD + 1);

      // Second vote should create a new proposal, not add to the expired one
      const voteTimestamp2 = await time.latest();
      await votesToken.setPastVotes(voter2.address, voteTimestamp2, VOTER2_TOKENS);

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
      const voteTimestamp = await time.latest();
      await votesToken.setPastVotes(voter1.address, voteTimestamp, VOTER1_TOKENS);
      await votesToken.setPastVotes(voter2.address, voteTimestamp, VOTER2_TOKENS);
      await votesToken.setPastVotes(voter3.address, voteTimestamp, VOTER3_TOKENS);
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

      // Increase time to pass the freeze period
      await time.increase(FREEZE_PERIOD + 1);

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
      expect(await freezeVoting.freezeProposalCreated()).to.equal(0);
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
      const newVoteTimestamp = await time.latest();
      await votesToken.setPastVotes(voter1.address, newVoteTimestamp, VOTER1_TOKENS);
      await votesToken.setPastVotes(voter2.address, newVoteTimestamp, VOTER2_TOKENS);

      // Start a new proposal with not enough votes
      await freezeVoting.connect(voter1).castFreezeVote();
      await freezeVoting.connect(voter2).castFreezeVote();

      // DAO should not be frozen with only voter1 + voter2 votes
      void expect(await freezeVoting.isFrozen()).to.be.false;

      // Set up mock past votes for voter3
      const finalVoteTimestamp = await time.latest();
      await votesToken.setPastVotes(voter3.address, finalVoteTimestamp, VOTER3_TOKENS);

      // Add the third vote to reach threshold
      await freezeVoting.connect(voter3).castFreezeVote();

      // DAO should be frozen again
      void expect(await freezeVoting.isFrozen()).to.be.true;
    });
  });

  describe('User Has Voted Tracking', () => {
    beforeEach(async () => {
      // Set up mock past votes for voter1
      const voteTimestamp = await time.latest();
      await votesToken.setPastVotes(voter1.address, voteTimestamp, VOTER1_TOKENS);
    });

    it('should correctly track if a user has voted on a proposal', async () => {
      // Initial state - user has not voted
      const createdTimestamp = await freezeVoting.freezeProposalCreated();
      void expect(await freezeVoting.userHasFreezeVoted(voter1.address, createdTimestamp)).to.be
        .false;

      // User votes
      await freezeVoting.connect(voter1).castFreezeVote();

      // Updated state - user has voted
      const newCreatedTimestamp = await freezeVoting.freezeProposalCreated();
      void expect(await freezeVoting.userHasFreezeVoted(voter1.address, newCreatedTimestamp)).to.be
        .true;
    });

    it('should reset user voting status when unfreeze is called', async () => {
      // User votes
      await freezeVoting.connect(voter1).castFreezeVote();

      // Get the created timestamp
      const createdTimestamp = await freezeVoting.freezeProposalCreated();

      // Check that user has voted
      void expect(await freezeVoting.userHasFreezeVoted(voter1.address, createdTimestamp)).to.be
        .true;

      // Owner unfreezes
      await freezeVoting.connect(owner).unfreeze();

      // The created timestamp is now 0, so the voting status should be reset
      expect(await freezeVoting.freezeProposalCreated()).to.equal(0);

      // Set up mock past votes for the new timestamp
      const newVoteTimestamp = await time.latest();
      await votesToken.setPastVotes(voter1.address, newVoteTimestamp, VOTER1_TOKENS);

      // User should be able to vote again on a new proposal
      await freezeVoting.connect(voter1).castFreezeVote();

      // Get the new created timestamp
      const newCreatedTimestamp = await freezeVoting.freezeProposalCreated();

      // Check that user has voted on the new proposal
      void expect(await freezeVoting.userHasFreezeVoted(voter1.address, newCreatedTimestamp)).to.be
        .true;
    });
  });

  describe('Version', () => {
    // Use the shared version test utility
    it('should return the correct version number', async () => {
      expect(await freezeVoting.version()).to.equal(1);
    });
  });

  describe('ERC165', () => {
    it('should support the IERC20FreezeVotingV1 interface', async () => {
      void expect(
        await freezeVoting.supportsInterface(
          calculateInterfaceId(IERC20FreezeVotingV1__factory.createInterface(), [
            IBaseFreezeVotingV1__factory.createInterface(),
          ]),
        ),
      ).to.be.true;
    });

    it('should support the IBaseFreezeVotingV1 interface', async () => {
      void expect(
        await freezeVoting.supportsInterface(
          calculateInterfaceId(IBaseFreezeVotingV1__factory.createInterface()),
        ),
      ).to.be.true;
    });

    it('should support the IERC165 interface', async () => {
      void expect(
        await freezeVoting.supportsInterface(
          calculateInterfaceId(IERC165__factory.createInterface()),
        ),
      ).to.be.true;
    });

    it('should support the IVersion interface', async () => {
      void expect(
        await freezeVoting.supportsInterface(
          calculateInterfaceId(IVersion__factory.createInterface()),
        ),
      ).to.be.true;
    });

    it('should not support a random interface', async () => {
      void expect(await freezeVoting.supportsInterface('0x12345678')).to.be.false;
    });
  });
});
