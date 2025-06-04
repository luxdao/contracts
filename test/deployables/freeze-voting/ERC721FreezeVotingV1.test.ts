import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { time } from '@nomicfoundation/hardhat-network-helpers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  ERC1967Proxy__factory,
  ERC721FreezeVotingV1,
  ERC721FreezeVotingV1__factory,
  IBaseFreezeVotingV1__factory,
  IERC165__factory,
  IERC721FreezeVotingV1__factory,
  IVersion__factory,
  MockERC721,
  MockERC721__factory,
  MockERC721VotingStrategy,
  MockERC721VotingStrategy__factory,
} from '../../../typechain-types';
import { calculateInterfaceId } from '../../helpers/utils';

// Helper function for deploying ERC721FreezeVotingV1 proxy instances using ERC1967Proxy
async function deployERC721FreezeVotingProxy(
  proxyDeployer: SignerWithAddress,
  implementation: string,
  owner: SignerWithAddress,
  freezeVotesThreshold: number,
  freezeProposalPeriod: number,
  freezePeriod: number,
  strategy: MockERC721VotingStrategy,
): Promise<ERC721FreezeVotingV1> {
  // Combine selector and encoded params
  const fullInitData =
    ERC721FreezeVotingV1__factory.createInterface().getFunction('initialize').selector +
    ethers.AbiCoder.defaultAbiCoder()
      .encode(
        ['address', 'uint256', 'uint32', 'uint32', 'address'],
        [
          owner.address,
          freezeVotesThreshold,
          freezeProposalPeriod,
          freezePeriod,
          await strategy.getAddress(),
        ],
      )
      .slice(2);

  // Deploy the proxy with the implementation
  const proxy = await new ERC1967Proxy__factory(proxyDeployer).deploy(implementation, fullInitData);

  // Return a contract instance connected to the proxy
  return ERC721FreezeVotingV1__factory.connect(await proxy.getAddress(), owner);
}

// Helper function to mint an NFT
async function mintNFT(nftContract: MockERC721, to: SignerWithAddress): Promise<void> {
  await nftContract.mint(to.address);
}

describe('ERC721FreezeVotingV1', () => {
  // signers
  let proxyDeployer: SignerWithAddress;
  let owner: SignerWithAddress;
  let voter1: SignerWithAddress;
  let voter2: SignerWithAddress;
  let voter3: SignerWithAddress;
  let nonVoter: SignerWithAddress;

  // contracts
  let masterCopy: string;
  let freezeVoting: ERC721FreezeVotingV1;
  let votingStrategy: MockERC721VotingStrategy;
  let nftCollection1: MockERC721;
  let nftCollection2: MockERC721;

  // constants
  const FREEZE_VOTES_THRESHOLD = 3;
  const FREEZE_PROPOSAL_PERIOD = 5;
  const FREEZE_PERIOD = 10;

  // token weights
  const TOKEN1_WEIGHT = 1;
  const TOKEN2_WEIGHT = 2;

  // tokenIds arrays - to be populated during test setup
  let voter1TokenAddresses: string[] = [];
  let voter1TokenIds: bigint[] = [];
  let voter2TokenAddresses: string[] = [];
  let voter2TokenIds: bigint[] = [];
  let voter3TokenAddresses: string[] = [];
  let voter3TokenIds: bigint[] = [];

  beforeEach(async () => {
    // Get signers
    [proxyDeployer, owner, voter1, voter2, voter3, nonVoter] = await ethers.getSigners();

    // Deploy NFT collections
    nftCollection1 = await new MockERC721__factory(proxyDeployer).deploy();
    nftCollection2 = await new MockERC721__factory(proxyDeployer).deploy();

    // Deploy voting strategy
    votingStrategy = await new MockERC721VotingStrategy__factory(proxyDeployer).deploy(
      owner.address,
    );

    // Set token weights in the voting strategy
    await votingStrategy
      .connect(owner)
      .setTokenWeight(await nftCollection1.getAddress(), TOKEN1_WEIGHT);
    await votingStrategy
      .connect(owner)
      .setTokenWeight(await nftCollection2.getAddress(), TOKEN2_WEIGHT);

    // Mint NFTs to voters
    // Voter 1 gets 1 NFT from collection 1 (weight 1)
    await mintNFT(nftCollection1, voter1);
    const voter1NFTId = BigInt(0); // First minted token has id 0
    voter1TokenAddresses = [await nftCollection1.getAddress()];
    voter1TokenIds = [voter1NFTId];

    // Voter 2 gets 1 NFT from collection 2 (weight 2)
    await mintNFT(nftCollection2, voter2);
    const voter2NFTId = BigInt(0);
    voter2TokenAddresses = [await nftCollection2.getAddress()];
    voter2TokenIds = [voter2NFTId];

    // Voter 3 gets 1 NFT from collection 1 (weight 1) and 1 from collection 2 (weight 2) for total of 3
    await mintNFT(nftCollection1, voter3);
    await mintNFT(nftCollection2, voter3);
    const voter3NFT1Id = BigInt(1); // Second minted token from collection 1
    const voter3NFT2Id = BigInt(1); // Second minted token from collection 2
    voter3TokenAddresses = [await nftCollection1.getAddress(), await nftCollection2.getAddress()];
    voter3TokenIds = [voter3NFT1Id, voter3NFT2Id];

    // Deploy implementation
    const implementation = await new ERC721FreezeVotingV1__factory(proxyDeployer).deploy();
    masterCopy = await implementation.getAddress();

    // Deploy proxy
    freezeVoting = await deployERC721FreezeVotingProxy(
      proxyDeployer,
      masterCopy,
      owner,
      FREEZE_VOTES_THRESHOLD,
      FREEZE_PROPOSAL_PERIOD,
      FREEZE_PERIOD,
      votingStrategy,
    );
  });

  describe('Initialization', () => {
    it('should initialize with correct parameters', async () => {
      expect(await freezeVoting.owner()).to.equal(owner.address);
      expect(await freezeVoting.freezeVotesThreshold()).to.equal(FREEZE_VOTES_THRESHOLD);
      expect(await freezeVoting.freezeProposalPeriod()).to.equal(FREEZE_PROPOSAL_PERIOD);
      expect(await freezeVoting.freezePeriod()).to.equal(FREEZE_PERIOD);
      expect(await freezeVoting.strategy()).to.equal(await votingStrategy.getAddress());
    });

    it('should not allow reinitialization', async () => {
      await expect(
        freezeVoting.initialize(
          owner.address,
          FREEZE_VOTES_THRESHOLD,
          FREEZE_PROPOSAL_PERIOD,
          FREEZE_PERIOD,
          await votingStrategy.getAddress(),
        ),
      ).to.be.revertedWithCustomError(freezeVoting, 'InvalidInitialization');
    });

    it('Should have initialization disabled in the implementation', async function () {
      const implementationContract = ERC721FreezeVotingV1__factory.connect(
        masterCopy,
        proxyDeployer,
      ) as any;

      await expect(
        implementationContract.initialize(
          owner.address,
          FREEZE_VOTES_THRESHOLD,
          FREEZE_PROPOSAL_PERIOD,
          FREEZE_PERIOD,
          await votingStrategy.getAddress(),
        ),
      ).to.be.revertedWithCustomError(implementationContract, 'InvalidInitialization');
    });
  });

  describe('Freeze Voting Process', () => {
    it('should reject votes with no NFTs', async () => {
      await expect(
        freezeVoting.connect(nonVoter).castFreezeVote([], []),
      ).to.be.revertedWithCustomError(freezeVoting, 'NoVotes');
    });

    it('should reject votes with mismatched token arrays', async () => {
      await expect(
        freezeVoting.connect(voter1).castFreezeVote([await nftCollection1.getAddress()], []),
      ).to.be.revertedWithCustomError(freezeVoting, 'UnequalArrays');
    });

    it('should create a freeze proposal when first user votes', async () => {
      // Cast the first vote
      await expect(
        freezeVoting.connect(voter1).castFreezeVote(voter1TokenAddresses, voter1TokenIds),
      )
        .to.emit(freezeVoting, 'FreezeProposalCreated')
        .withArgs(voter1.address)
        .and.to.emit(freezeVoting, 'FreezeVoteCast')
        .withArgs(voter1.address, TOKEN1_WEIGHT);

      // Check state after vote
      expect(await freezeVoting.freezeProposalCreated()).to.be.gt(0); // Just check that a timestamp was recorded
      expect(await freezeVoting.freezeProposalVoteCount()).to.equal(TOKEN1_WEIGHT);
    });

    it('should accumulate votes correctly based on token weights', async () => {
      // First vote
      await freezeVoting.connect(voter1).castFreezeVote(voter1TokenAddresses, voter1TokenIds);
      expect(await freezeVoting.freezeProposalVoteCount()).to.equal(TOKEN1_WEIGHT);

      // Second vote
      await freezeVoting.connect(voter2).castFreezeVote(voter2TokenAddresses, voter2TokenIds);
      expect(await freezeVoting.freezeProposalVoteCount()).to.equal(TOKEN1_WEIGHT + TOKEN2_WEIGHT);
    });

    it('should prevent duplicate votes from the same token', async () => {
      // First vote with voter1's NFT
      await freezeVoting.connect(voter1).castFreezeVote(voter1TokenAddresses, voter1TokenIds);
      const initialVoteCount = await freezeVoting.freezeProposalVoteCount();

      // Voting again with the same NFT - we need to give a valid additional NFT to avoid NoVotes
      // First, mint a new NFT to voter1
      await mintNFT(nftCollection1, voter1);
      const newTokenId = BigInt(2); // Third minted token from collection 1

      // Try voting with both the already voted NFT and the new one
      const combinedAddresses = [
        await nftCollection1.getAddress(),
        await nftCollection1.getAddress(),
      ];
      const combinedIds = [voter1TokenIds[0], newTokenId];

      await freezeVoting.connect(voter1).castFreezeVote(combinedAddresses, combinedIds);

      // Only the new token's vote should be counted, so vote count should increase by TOKEN1_WEIGHT
      expect(await freezeVoting.freezeProposalVoteCount()).to.equal(
        initialVoteCount + BigInt(TOKEN1_WEIGHT),
      );
    });

    it('should not count votes from NFTs not owned by voter', async () => {
      // First create a proposal with voter1's NFT to avoid having empty votes
      await freezeVoting.connect(voter1).castFreezeVote(voter1TokenAddresses, voter1TokenIds);
      const initialVoteCount = await freezeVoting.freezeProposalVoteCount();

      // Mint a new NFT to voter2 to avoid NoVotes when trying to vote
      await mintNFT(nftCollection1, voter2);
      const validTokenId = BigInt(2); // Third minted token from collection 1

      // voter2 tries to vote with their own NFT and voter1's NFT
      const combinedAddresses = [
        await nftCollection1.getAddress(),
        await nftCollection1.getAddress(),
      ];
      const combinedIds = [voter1TokenIds[0], validTokenId];

      // Should process transaction but only count voter2's own NFT
      await freezeVoting.connect(voter2).castFreezeVote(combinedAddresses, combinedIds);

      // Only voter2's NFT vote should be counted, so vote count should increase by TOKEN1_WEIGHT
      expect(await freezeVoting.freezeProposalVoteCount()).to.equal(
        initialVoteCount + BigInt(TOKEN1_WEIGHT),
      );
    });

    it('should accept votes with multiple NFTs', async () => {
      // Voter3 votes with both NFTs
      await freezeVoting.connect(voter3).castFreezeVote(voter3TokenAddresses, voter3TokenIds);

      // Vote count should be sum of weights (1 + 2 = 3)
      expect(await freezeVoting.freezeProposalVoteCount()).to.equal(TOKEN1_WEIGHT + TOKEN2_WEIGHT);
    });

    it('should create a new proposal after proposal period expiry', async () => {
      // First proposal
      await freezeVoting.connect(voter1).castFreezeVote(voter1TokenAddresses, voter1TokenIds);
      const firstProposalTimestamp = await freezeVoting.freezeProposalCreated();

      // Increase time to pass the freeze proposal period
      await time.increase(FREEZE_PROPOSAL_PERIOD + 1);

      // Second vote should create a new proposal
      await expect(
        freezeVoting.connect(voter2).castFreezeVote(voter2TokenAddresses, voter2TokenIds),
      )
        .to.emit(freezeVoting, 'FreezeProposalCreated')
        .withArgs(voter2.address);

      // New proposal should have a different timestamp
      const secondProposalTimestamp = await freezeVoting.freezeProposalCreated();
      expect(secondProposalTimestamp).to.not.equal(firstProposalTimestamp);

      // Vote count should be just voter2's vote
      expect(await freezeVoting.freezeProposalVoteCount()).to.equal(TOKEN2_WEIGHT);
    });
  });

  describe('Freeze State', () => {
    it('should not be frozen initially', async () => {
      void expect(await freezeVoting.isFrozen()).to.be.false;
    });

    it('should not be frozen when below threshold', async () => {
      // With threshold of 3, cast only 1 vote (voter1)
      await freezeVoting.connect(voter1).castFreezeVote(voter1TokenAddresses, voter1TokenIds);

      // Total votes: 1, below threshold of 3
      void expect(await freezeVoting.isFrozen()).to.be.false;
    });

    it('should be frozen once threshold is met', async () => {
      // With threshold of 3, cast votes from both voter1 and voter2 (1 + 2 = 3)
      await freezeVoting.connect(voter1).castFreezeVote(voter1TokenAddresses, voter1TokenIds);
      await freezeVoting.connect(voter2).castFreezeVote(voter2TokenAddresses, voter2TokenIds);

      // Total votes: 3, equal to threshold of 3
      void expect(await freezeVoting.isFrozen()).to.be.true;
    });

    it('should automatically unfreeze after freeze period', async () => {
      // Cast enough votes to exceed threshold
      await freezeVoting.connect(voter3).castFreezeVote(voter3TokenAddresses, voter3TokenIds);

      // Should be frozen initially
      void expect(await freezeVoting.isFrozen()).to.be.true;

      // Increase time to pass the freeze period
      await time.increase(FREEZE_PERIOD + 1);

      // Should no longer be frozen
      void expect(await freezeVoting.isFrozen()).to.be.false;
    });

    it('should allow owner to unfreeze manually', async () => {
      // Cast enough votes to exceed threshold
      await freezeVoting.connect(voter3).castFreezeVote(voter3TokenAddresses, voter3TokenIds);

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
      await freezeVoting.connect(voter3).castFreezeVote(voter3TokenAddresses, voter3TokenIds);

      // Non-owner tries to unfreeze
      await expect(freezeVoting.connect(voter1).unfreeze()).to.be.revertedWithCustomError(
        freezeVoting,
        'OwnableUnauthorizedAccount',
      );

      // Should still be frozen
      void expect(await freezeVoting.isFrozen()).to.be.true;
    });

    it('should track freeze status across multiple proposals', async () => {
      // First proposal: voter3 votes with both NFTs to meet threshold
      await freezeVoting.connect(voter3).castFreezeVote(voter3TokenAddresses, voter3TokenIds);

      // DAO should be frozen
      void expect(await freezeVoting.isFrozen()).to.be.true;

      // Owner unfreezes manually
      await freezeVoting.connect(owner).unfreeze();

      // DAO should not be frozen
      void expect(await freezeVoting.isFrozen()).to.be.false;

      // Start a new proposal with not enough votes
      await freezeVoting.connect(voter1).castFreezeVote(voter1TokenAddresses, voter1TokenIds);

      // DAO should not be frozen with only voter1's vote
      void expect(await freezeVoting.isFrozen()).to.be.false;

      // Add voter2's vote to reach threshold
      await freezeVoting.connect(voter2).castFreezeVote(voter2TokenAddresses, voter2TokenIds);

      // DAO should be frozen again
      void expect(await freezeVoting.isFrozen()).to.be.true;
    });
  });

  describe('Token Has Voted Tracking', () => {
    it('should correctly track if a token has been used to vote', async () => {
      const createdTimestamp = 0; // Initial state

      // Initial state - token has not been used to vote
      void expect(
        await freezeVoting.idHasFreezeVoted(
          createdTimestamp,
          voter1TokenAddresses[0],
          voter1TokenIds[0],
        ),
      ).to.be.false;

      // User votes with token
      await freezeVoting.connect(voter1).castFreezeVote(voter1TokenAddresses, voter1TokenIds);

      // Get the proposal created timestamp
      const newCreatedTimestamp = await freezeVoting.freezeProposalCreated();

      // Updated state - token has been used to vote
      void expect(
        await freezeVoting.idHasFreezeVoted(
          newCreatedTimestamp,
          voter1TokenAddresses[0],
          voter1TokenIds[0],
        ),
      ).to.be.true;
    });

    it('should reset token voting status when unfreeze is called', async () => {
      // User votes with token
      await freezeVoting.connect(voter1).castFreezeVote(voter1TokenAddresses, voter1TokenIds);

      // Get the created timestamp
      const createdTimestamp = await freezeVoting.freezeProposalCreated();

      // Check that token has been used to vote
      void expect(
        await freezeVoting.idHasFreezeVoted(
          createdTimestamp,
          voter1TokenAddresses[0],
          voter1TokenIds[0],
        ),
      ).to.be.true;

      // Owner unfreezes
      await freezeVoting.connect(owner).unfreeze();

      // The created timestamp is now 0, so the voting status is implicitly reset
      expect(await freezeVoting.freezeProposalCreated()).to.equal(0);

      // User should be able to vote again with the same token
      await freezeVoting.connect(voter1).castFreezeVote(voter1TokenAddresses, voter1TokenIds);
      const newCreatedTimestamp = await freezeVoting.freezeProposalCreated();

      // The token should be marked as voted for the new proposal
      void expect(
        await freezeVoting.idHasFreezeVoted(
          newCreatedTimestamp,
          voter1TokenAddresses[0],
          voter1TokenIds[0],
        ),
      ).to.be.true;
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
          calculateInterfaceId(IERC721FreezeVotingV1__factory.createInterface(), [
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
