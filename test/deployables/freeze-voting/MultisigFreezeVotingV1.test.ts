import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { time } from '@nomicfoundation/hardhat-network-helpers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  ERC1967Proxy__factory,
  IBaseFreezeVotingV1__factory,
  IERC165__factory,
  IMultisigFreezeVotingV1__factory,
  IVersion__factory,
  MockSafe,
  MockSafe__factory,
  MultisigFreezeVotingV1,
  MultisigFreezeVotingV1__factory,
} from '../../../typechain-types';
import { calculateInterfaceId } from '../../helpers/utils';

// Helper function for deploying MultisigFreezeVotingV1 proxy instances using ERC1967Proxy
async function deployMultisigFreezeVotingProxy(
  proxyDeployer: SignerWithAddress,
  implementation: string,
  owner: SignerWithAddress,
  freezeVotesThreshold: number,
  freezeProposalPeriod: number,
  freezePeriod: number,
  parentGnosisSafe: MockSafe,
): Promise<MultisigFreezeVotingV1> {
  // Combine selector and encoded params
  const fullInitData =
    MultisigFreezeVotingV1__factory.createInterface().getFunction('initialize').selector +
    ethers.AbiCoder.defaultAbiCoder()
      .encode(
        ['address', 'uint256', 'uint32', 'uint32', 'address'],
        [
          owner.address,
          freezeVotesThreshold,
          freezeProposalPeriod,
          freezePeriod,
          await parentGnosisSafe.getAddress(),
        ],
      )
      .slice(2);

  // Deploy the proxy with the implementation
  const proxy = await new ERC1967Proxy__factory(proxyDeployer).deploy(implementation, fullInitData);

  // Return a contract instance connected to the proxy
  return MultisigFreezeVotingV1__factory.connect(await proxy.getAddress(), owner);
}

describe('MultisigFreezeVotingV1', () => {
  // signers
  let proxyDeployer: SignerWithAddress;
  let owner: SignerWithAddress;
  let safeOwner1: SignerWithAddress;
  let safeOwner2: SignerWithAddress;
  let nonSafeOwner: SignerWithAddress;

  // contracts
  let masterCopy: string;
  let freezeVoting: MultisigFreezeVotingV1;
  let mockSafe: MockSafe;

  // constants
  const FREEZE_VOTES_THRESHOLD = 2;
  const FREEZE_PROPOSAL_PERIOD = 5;
  const FREEZE_PERIOD = 10;

  beforeEach(async () => {
    // Get signers
    [proxyDeployer, owner, safeOwner1, safeOwner2, nonSafeOwner] = await ethers.getSigners();

    // Deploy mock Safe
    mockSafe = await new MockSafe__factory(proxyDeployer).deploy();

    // Set the owner of the mock Safe
    await mockSafe.setOwner(safeOwner1.address);

    // Deploy implementation
    const implementation = await new MultisigFreezeVotingV1__factory(proxyDeployer).deploy();
    masterCopy = await implementation.getAddress();

    // Deploy proxy
    freezeVoting = await deployMultisigFreezeVotingProxy(
      proxyDeployer,
      masterCopy,
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
      expect(await freezeVoting.parentSafe()).to.equal(await mockSafe.getAddress());
    });

    it('should not allow reinitialization', async () => {
      await expect(
        freezeVoting.initialize(
          owner.address,
          FREEZE_VOTES_THRESHOLD,
          FREEZE_PROPOSAL_PERIOD,
          FREEZE_PERIOD,
          await mockSafe.getAddress(),
        ),
      ).to.be.revertedWithCustomError(freezeVoting, 'InvalidInitialization');
    });

    it('Should have initialization disabled in the implementation', async function () {
      const implementationContract = MultisigFreezeVotingV1__factory.connect(
        masterCopy,
        proxyDeployer,
      );

      await expect(
        implementationContract.initialize(
          owner.address,
          FREEZE_VOTES_THRESHOLD,
          FREEZE_PROPOSAL_PERIOD,
          FREEZE_PERIOD,
          await mockSafe.getAddress(),
        ),
      ).to.be.revertedWithCustomError(implementationContract, 'InvalidInitialization');
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
      expect(await freezeVoting.freezeProposalCreated()).to.be.gt(0); // Just check that a timestamp was recorded
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
      const firstProposalTimestamp = await freezeVoting.freezeProposalCreated();

      // Increase time to pass the freeze proposal period
      await time.increase(FREEZE_PROPOSAL_PERIOD + 1);

      // Change Safe owner for second vote
      await mockSafe.setOwner(safeOwner2.address);

      // Second vote should create a new proposal
      await expect(freezeVoting.connect(safeOwner2).castFreezeVote())
        .to.emit(freezeVoting, 'FreezeProposalCreated')
        .withArgs(safeOwner2.address);

      // New proposal should have a different timestamp
      const secondProposalTimestamp = await freezeVoting.freezeProposalCreated();
      expect(secondProposalTimestamp).to.not.equal(firstProposalTimestamp);

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

      // Increase time to pass the freeze period
      await time.increase(FREEZE_PERIOD + 1);

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
      expect(await freezeVoting.freezeProposalCreated()).to.equal(0);
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

  describe('User Has Voted Tracking', () => {
    it('should correctly track if a user has voted on a proposal', async () => {
      // Set Safe owner
      await mockSafe.setOwner(safeOwner1.address);

      // Initial state - user has not voted
      const createdTimestamp = await freezeVoting.freezeProposalCreated();
      void expect(await freezeVoting.userHasFreezeVoted(safeOwner1.address, createdTimestamp)).to.be
        .false;

      // User votes
      await freezeVoting.connect(safeOwner1).castFreezeVote();

      // Get the new created timestamp
      const newCreatedTimestamp = await freezeVoting.freezeProposalCreated();

      // Updated state - user has voted
      void expect(await freezeVoting.userHasFreezeVoted(safeOwner1.address, newCreatedTimestamp)).to
        .be.true;
    });

    it('should reset user voting status when unfreeze is called', async () => {
      // Set Safe owner
      await mockSafe.setOwner(safeOwner1.address);

      // User votes
      await freezeVoting.connect(safeOwner1).castFreezeVote();

      // Get the created timestamp
      const createdTimestamp = await freezeVoting.freezeProposalCreated();

      // Check that user has voted
      void expect(await freezeVoting.userHasFreezeVoted(safeOwner1.address, createdTimestamp)).to.be
        .true;

      // Owner unfreezes
      await freezeVoting.connect(owner).unfreeze();

      // The created timestamp is now 0, so the voting status is reset
      expect(await freezeVoting.freezeProposalCreated()).to.equal(0);

      // User should be able to vote again
      await freezeVoting.connect(safeOwner1).castFreezeVote();
      const newCreatedTimestamp = await freezeVoting.freezeProposalCreated();

      // User has voted on the new proposal
      void expect(await freezeVoting.userHasFreezeVoted(safeOwner1.address, newCreatedTimestamp)).to
        .be.true;
    });
  });

  describe('Version', () => {
    it('should return the correct version number', async () => {
      expect(await freezeVoting.version()).to.equal(1);
    });
  });

  describe('ERC165', () => {
    it('should support the IERC721FreezeVotingV1 interface', async () => {
      void expect(
        await freezeVoting.supportsInterface(
          calculateInterfaceId(IMultisigFreezeVotingV1__factory.createInterface(), [
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
