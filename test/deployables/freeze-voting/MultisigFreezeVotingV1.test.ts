import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { mine } from '@nomicfoundation/hardhat-network-helpers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  MultisigFreezeVotingV1,
  MultisigFreezeVotingV1__factory,
  MockSafe,
  MockSafe__factory,
} from '../../../typechain-types';
import { getModuleProxyFactory } from '../../global/GlobalSafeDeployments.test';
import { calculateProxyAddress } from '../../helpers';

// Helper function for deploying MultisigFreezeVotingV1 proxy instances
async function deployMultisigFreezeVotingProxy(
  multisigFreezeVotingMastercopy: MultisigFreezeVotingV1,
  owner: SignerWithAddress,
  freezeVotesThreshold: number,
  freezeProposalPeriod: number,
  freezePeriod: number,
  parentGnosisSafe: MockSafe,
): Promise<MultisigFreezeVotingV1> {
  const moduleProxyFactory = getModuleProxyFactory();
  const salt = ethers.hexlify(ethers.randomBytes(32));

  const multisigFreezeVotingSetupCalldata =
    MultisigFreezeVotingV1__factory.createInterface().encodeFunctionData('setUp', [
      ethers.AbiCoder.defaultAbiCoder().encode(
        ['address', 'uint256', 'uint32', 'uint32', 'address'],
        [
          owner.address,
          freezeVotesThreshold,
          freezeProposalPeriod,
          freezePeriod,
          await parentGnosisSafe.getAddress(),
        ],
      ),
    ]);

  await moduleProxyFactory.deployModule(
    await multisigFreezeVotingMastercopy.getAddress(),
    multisigFreezeVotingSetupCalldata,
    salt,
  );

  const predictedAddress = await calculateProxyAddress(
    moduleProxyFactory,
    await multisigFreezeVotingMastercopy.getAddress(),
    multisigFreezeVotingSetupCalldata,
    salt,
  );

  return MultisigFreezeVotingV1__factory.connect(predictedAddress, owner);
}

describe('MultisigFreezeVotingV1', () => {
  // signers
  let deployer: SignerWithAddress;
  let owner: SignerWithAddress;
  let safeOwner1: SignerWithAddress;
  let safeOwner2: SignerWithAddress;
  let nonSafeOwner: SignerWithAddress;

  // contracts
  let multisigFreezeVotingMastercopy: MultisigFreezeVotingV1;
  let freezeVoting: MultisigFreezeVotingV1;
  let mockSafe: MockSafe;

  // constants
  const FREEZE_VOTES_THRESHOLD = 2;
  const FREEZE_PROPOSAL_PERIOD = 5;
  const FREEZE_PERIOD = 10;

  beforeEach(async () => {
    // Get signers
    [deployer, owner, safeOwner1, safeOwner2, nonSafeOwner] = await ethers.getSigners();

    // Deploy mock Safe
    mockSafe = await new MockSafe__factory(deployer).deploy();

    // Set the owner of the mock Safe
    await mockSafe.setOwner(safeOwner1.address);

    // Deploy mastercopy
    multisigFreezeVotingMastercopy = await new MultisigFreezeVotingV1__factory(deployer).deploy();

    // Deploy proxy
    freezeVoting = await deployMultisigFreezeVotingProxy(
      multisigFreezeVotingMastercopy,
      owner,
      FREEZE_VOTES_THRESHOLD,
      FREEZE_PROPOSAL_PERIOD,
      FREEZE_PERIOD,
      mockSafe,
    );
  });

  describe('Initialization', () => {
    it('should initialize with correct parameters', async () => {
      expect(await freezeVoting.owner()).to.equal(owner.address);
      expect(await freezeVoting.freezeVotesThreshold()).to.equal(FREEZE_VOTES_THRESHOLD);
      expect(await freezeVoting.freezeProposalPeriod()).to.equal(FREEZE_PROPOSAL_PERIOD);
      expect(await freezeVoting.freezePeriod()).to.equal(FREEZE_PERIOD);
      expect(await freezeVoting.parentGnosisSafe()).to.equal(await mockSafe.getAddress());
    });

    it('should not allow reinitialization', async () => {
      const setupData = ethers.AbiCoder.defaultAbiCoder().encode(
        ['address', 'uint256', 'uint32', 'uint32', 'address'],
        [
          owner.address,
          FREEZE_VOTES_THRESHOLD,
          FREEZE_PROPOSAL_PERIOD,
          FREEZE_PERIOD,
          await mockSafe.getAddress(),
        ],
      );

      await expect(freezeVoting.setUp(setupData)).to.be.revertedWithCustomError(
        freezeVoting,
        'InvalidInitialization',
      );
    });
  });

  describe('Freeze Voting Process', () => {
    it('should reject votes from users not in the parent Safe', async () => {
      await expect(
        freezeVoting.connect(nonSafeOwner).castFreezeVote(),
      ).to.be.revertedWithCustomError(freezeVoting, 'NotOwner');
    });

    it('should create a freeze proposal when first user votes', async () => {
      // Set up mock Safe owner
      await mockSafe.setOwner(safeOwner1.address);

      // Cast the first vote
      await expect(freezeVoting.connect(safeOwner1).castFreezeVote())
        .to.emit(freezeVoting, 'FreezeProposalCreated')
        .withArgs(safeOwner1.address)
        .and.to.emit(freezeVoting, 'FreezeVoteCast')
        .withArgs(safeOwner1.address, 1);

      // Check state after vote
      expect(await freezeVoting.freezeProposalCreatedBlock()).to.be.gt(0); // Just check that a block was recorded
      expect(await freezeVoting.freezeProposalVoteCount()).to.equal(1);
    });

    it('should accumulate votes correctly from multiple Safe owners', async () => {
      // Set first Safe owner
      await mockSafe.setOwner(safeOwner1.address);

      // First vote
      await freezeVoting.connect(safeOwner1).castFreezeVote();
      expect(await freezeVoting.freezeProposalVoteCount()).to.equal(1);

      // Change Safe owner for second vote
      await mockSafe.setOwner(safeOwner2.address);

      // Second vote
      await freezeVoting.connect(safeOwner2).castFreezeVote();
      expect(await freezeVoting.freezeProposalVoteCount()).to.equal(2);
    });

    it('should prevent duplicate votes from the same user', async () => {
      // Set Safe owner
      await mockSafe.setOwner(safeOwner1.address);

      // First vote
      await freezeVoting.connect(safeOwner1).castFreezeVote();

      // Attempting to vote again should fail
      await expect(freezeVoting.connect(safeOwner1).castFreezeVote()).to.be.revertedWithCustomError(
        freezeVoting,
        'AlreadyVoted',
      );
    });

    it('should create a new proposal after proposal period expiry', async () => {
      // Set Safe owner
      await mockSafe.setOwner(safeOwner1.address);

      // First proposal
      await freezeVoting.connect(safeOwner1).castFreezeVote();
      const firstProposalBlock = await freezeVoting.freezeProposalCreatedBlock();

      // Mine blocks to pass the freeze proposal period
      await mine(FREEZE_PROPOSAL_PERIOD + 1);

      // Change Safe owner for second vote
      await mockSafe.setOwner(safeOwner2.address);

      // Second vote should create a new proposal
      await expect(freezeVoting.connect(safeOwner2).castFreezeVote())
        .to.emit(freezeVoting, 'FreezeProposalCreated')
        .withArgs(safeOwner2.address);

      // New proposal should have a different block number
      const secondProposalBlock = await freezeVoting.freezeProposalCreatedBlock();
      expect(secondProposalBlock).to.not.equal(firstProposalBlock);

      // Vote count should be reset to 1
      expect(await freezeVoting.freezeProposalVoteCount()).to.equal(1);
    });
  });

  describe('Freeze State', () => {
    it('should not be frozen initially', async () => {
      void expect(await freezeVoting.isFrozen()).to.be.false;
    });

    it('should not be frozen when below threshold', async () => {
      // Set Safe owner
      await mockSafe.setOwner(safeOwner1.address);

      // Cast first vote - not enough to reach threshold of 2
      await freezeVoting.connect(safeOwner1).castFreezeVote();

      // Total votes: 1, below threshold of 2
      void expect(await freezeVoting.isFrozen()).to.be.false;
    });

    it('should be frozen once threshold is met', async () => {
      // Set first Safe owner
      await mockSafe.setOwner(safeOwner1.address);

      // First vote
      await freezeVoting.connect(safeOwner1).castFreezeVote();

      // Change Safe owner for second vote
      await mockSafe.setOwner(safeOwner2.address);

      // Second vote to reach threshold
      await freezeVoting.connect(safeOwner2).castFreezeVote();

      // Total votes: 2, equal to threshold of 2
      void expect(await freezeVoting.isFrozen()).to.be.true;
    });

    it('should automatically unfreeze after freeze period', async () => {
      // Set first Safe owner
      await mockSafe.setOwner(safeOwner1.address);

      // First vote
      await freezeVoting.connect(safeOwner1).castFreezeVote();

      // Change Safe owner for second vote
      await mockSafe.setOwner(safeOwner2.address);

      // Second vote to reach threshold
      await freezeVoting.connect(safeOwner2).castFreezeVote();

      // Should be frozen initially
      void expect(await freezeVoting.isFrozen()).to.be.true;

      // Mine blocks to pass the freeze period
      await mine(FREEZE_PERIOD + 1);

      // Should no longer be frozen
      void expect(await freezeVoting.isFrozen()).to.be.false;
    });

    it('should allow owner to unfreeze manually', async () => {
      // Set first Safe owner
      await mockSafe.setOwner(safeOwner1.address);

      // First vote
      await freezeVoting.connect(safeOwner1).castFreezeVote();

      // Change Safe owner for second vote
      await mockSafe.setOwner(safeOwner2.address);

      // Second vote to reach threshold
      await freezeVoting.connect(safeOwner2).castFreezeVote();

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
      // Set first Safe owner
      await mockSafe.setOwner(safeOwner1.address);

      // First vote
      await freezeVoting.connect(safeOwner1).castFreezeVote();

      // Change Safe owner for second vote
      await mockSafe.setOwner(safeOwner2.address);

      // Second vote to reach threshold
      await freezeVoting.connect(safeOwner2).castFreezeVote();

      // Non-owner tries to unfreeze
      await expect(freezeVoting.connect(nonSafeOwner).unfreeze()).to.be.revertedWithCustomError(
        freezeVoting,
        'OwnableUnauthorizedAccount',
      );

      // Should still be frozen
      void expect(await freezeVoting.isFrozen()).to.be.true;
    });

    it('should track freeze status across multiple proposals', async () => {
      // Set first Safe owner
      await mockSafe.setOwner(safeOwner1.address);

      // First vote
      await freezeVoting.connect(safeOwner1).castFreezeVote();

      // Change Safe owner for second vote
      await mockSafe.setOwner(safeOwner2.address);

      // Second vote to reach threshold
      await freezeVoting.connect(safeOwner2).castFreezeVote();

      // DAO should be frozen
      void expect(await freezeVoting.isFrozen()).to.be.true;

      // Owner unfreezes manually
      await freezeVoting.connect(owner).unfreeze();

      // DAO should not be frozen
      void expect(await freezeVoting.isFrozen()).to.be.false;

      // Start new proposal
      await mockSafe.setOwner(safeOwner1.address);

      // First vote
      await freezeVoting.connect(safeOwner1).castFreezeVote();

      // DAO should not be frozen with only one vote
      void expect(await freezeVoting.isFrozen()).to.be.false;

      // Second vote to reach threshold
      await mockSafe.setOwner(safeOwner2.address);
      await freezeVoting.connect(safeOwner2).castFreezeVote();

      // DAO should be frozen again
      void expect(await freezeVoting.isFrozen()).to.be.true;
    });
  });

  describe('Parameter Updates', () => {
    it('should allow owner to update freezeVotesThreshold', async () => {
      const newThreshold = 3;

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
        freezeVoting.connect(nonSafeOwner).updateFreezeVotesThreshold(3),
      ).to.be.revertedWithCustomError(freezeVoting, 'OwnableUnauthorizedAccount');
    });

    it('should not allow non-owner to update freezeProposalPeriod', async () => {
      await expect(
        freezeVoting.connect(nonSafeOwner).updateFreezeProposalPeriod(15),
      ).to.be.revertedWithCustomError(freezeVoting, 'OwnableUnauthorizedAccount');
    });

    it('should not allow non-owner to update freezePeriod', async () => {
      await expect(
        freezeVoting.connect(nonSafeOwner).updateFreezePeriod(20),
      ).to.be.revertedWithCustomError(freezeVoting, 'OwnableUnauthorizedAccount');
    });

    it('should affect freeze status when threshold is updated', async () => {
      // Set first Safe owner
      await mockSafe.setOwner(safeOwner1.address);

      // First vote
      await freezeVoting.connect(safeOwner1).castFreezeVote();

      // Change Safe owner for second vote
      await mockSafe.setOwner(safeOwner2.address);

      // Second vote to reach threshold
      await freezeVoting.connect(safeOwner2).castFreezeVote();

      // DAO should be frozen with threshold of 2 and 2 votes
      void expect(await freezeVoting.isFrozen()).to.be.true;

      // Increase threshold to 3
      await freezeVoting.connect(owner).updateFreezeVotesThreshold(3);

      // Should no longer be frozen as 2 < 3
      void expect(await freezeVoting.isFrozen()).to.be.false;
    });
  });

  describe('User Has Voted Tracking', () => {
    it('should correctly track if a user has voted on a proposal', async () => {
      // Set Safe owner
      await mockSafe.setOwner(safeOwner1.address);

      // Initial state - user has not voted
      const createdBlock = await freezeVoting.freezeProposalCreatedBlock();
      void expect(await freezeVoting.userHasFreezeVoted(safeOwner1.address, createdBlock)).to.be
        .false;

      // User votes
      await freezeVoting.connect(safeOwner1).castFreezeVote();

      // Get the new created block number
      const newCreatedBlock = await freezeVoting.freezeProposalCreatedBlock();

      // Updated state - user has voted
      void expect(await freezeVoting.userHasFreezeVoted(safeOwner1.address, newCreatedBlock)).to.be
        .true;
    });

    it('should reset user voting status when unfreeze is called', async () => {
      // Set Safe owner
      await mockSafe.setOwner(safeOwner1.address);

      // User votes
      await freezeVoting.connect(safeOwner1).castFreezeVote();

      // Get the created block number
      const createdBlock = await freezeVoting.freezeProposalCreatedBlock();

      // Check that user has voted
      void expect(await freezeVoting.userHasFreezeVoted(safeOwner1.address, createdBlock)).to.be
        .true;

      // Owner unfreezes
      await freezeVoting.connect(owner).unfreeze();

      // The createdBlock is now 0, so the voting status is reset
      expect(await freezeVoting.freezeProposalCreatedBlock()).to.equal(0);

      // User should be able to vote again
      await freezeVoting.connect(safeOwner1).castFreezeVote();
      const newCreatedBlock = await freezeVoting.freezeProposalCreatedBlock();

      // User has voted on the new proposal
      void expect(await freezeVoting.userHasFreezeVoted(safeOwner1.address, newCreatedBlock)).to.be
        .true;
    });
  });

  describe('Version', () => {
    it('should return correct version', async () => {
      expect(await freezeVoting.getVersion()).to.equal(1);
    });
  });
});
