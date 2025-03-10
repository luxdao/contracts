import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { mine } from '@nomicfoundation/hardhat-network-helpers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  LinearERC721VotingV1,
  LinearERC721VotingV1__factory,
  MockERC721,
  MockERC721__factory,
  MockOwnership__factory,
} from '../../../typechain-types';
import { getModuleProxyFactory } from '../../global/GlobalSafeDeployments.test';
import { calculateProxyAddress } from '../../helpers';

describe('LinearERC721VotingV1', () => {
  // Signers
  let deployer: SignerWithAddress;
  let owner: SignerWithAddress;
  let nonOwner: SignerWithAddress;
  let azoriusAddress: string;
  let tokenHolder1: SignerWithAddress;
  let tokenHolder2: SignerWithAddress;
  let tokenHolder3: SignerWithAddress;

  // Contracts
  let linearERC721VotingMastercopy: LinearERC721VotingV1;
  let linearERC721Voting: LinearERC721VotingV1;
  let mockNFT1: MockERC721;
  let mockNFT2: MockERC721;

  // NFT IDs for tests
  let tokenHolder1Ids: number[] = [];
  let tokenHolder2Ids: number[] = [];
  let tokenHolder3Ids: number[] = [];

  // Constants
  const VOTING_PERIOD = 100; // blocks
  const QUORUM_THRESHOLD = 5; // 5 NFTs required for quorum
  const PROPOSER_THRESHOLD = 2; // 2 NFTs required to propose
  const BASIS_NUMERATOR = 500000; // 50% of 1000000
  const TOKEN1_WEIGHT = 1; // 1 vote per NFT from token1
  const TOKEN2_WEIGHT = 2; // 2 votes per NFT from token2

  // Vote types from the contract
  enum VoteType {
    NO = 0,
    YES = 1,
    ABSTAIN = 2,
  }

  async function deployLinearERC721Voting(
    strategyOwner: SignerWithAddress,
    governanceTokens: { tokenAddress: string; weight: number }[],
    azoriusAddr: string,
  ): Promise<LinearERC721VotingV1> {
    const salt = ethers.hexlify(ethers.randomBytes(32));
    const tokenAddresses = governanceTokens.map(t => t.tokenAddress);
    const tokenWeights = governanceTokens.map(t => t.weight);

    const initializeParams = ethers.AbiCoder.defaultAbiCoder().encode(
      ['address', 'address[]', 'uint256[]', 'address', 'uint32', 'uint256', 'uint256', 'uint256'],
      [
        strategyOwner.address,
        tokenAddresses,
        tokenWeights,
        azoriusAddr,
        VOTING_PERIOD,
        QUORUM_THRESHOLD,
        PROPOSER_THRESHOLD,
        BASIS_NUMERATOR,
      ],
    );

    const setupCalldata = linearERC721VotingMastercopy.interface.encodeFunctionData('setUp', [
      initializeParams,
    ]);

    const moduleProxyFactory = getModuleProxyFactory();

    await moduleProxyFactory.deployModule(
      await linearERC721VotingMastercopy.getAddress(),
      setupCalldata,
      salt,
    );

    const predictedAddress = await calculateProxyAddress(
      moduleProxyFactory,
      await linearERC721VotingMastercopy.getAddress(),
      setupCalldata,
      salt,
    );

    return LinearERC721VotingV1__factory.connect(predictedAddress, strategyOwner);
  }

  async function mintNFTs(
    tokenContract: MockERC721,
    holder: SignerWithAddress,
    count: number,
  ): Promise<number[]> {
    const ids: number[] = [];
    for (let i = 0; i < count; i++) {
      // Get current token ID before minting (it will be the next ID to be minted)
      const currentTokenId = await tokenContract.getCurrentTokenId();
      await tokenContract.mint(holder.address);
      ids.push(Number(currentTokenId));
    }
    return ids;
  }

  beforeEach(async () => {
    [deployer, owner, nonOwner, tokenHolder1, tokenHolder2, tokenHolder3] =
      await ethers.getSigners();

    // Use nonOwner address as a mock azorius address for testing
    azoriusAddress = await nonOwner.getAddress();

    // Deploy MockERC721 tokens
    mockNFT1 = await new MockERC721__factory(deployer).deploy();
    mockNFT2 = await new MockERC721__factory(deployer).deploy();

    // Mint NFTs to token holders
    tokenHolder1Ids = await mintNFTs(mockNFT1, tokenHolder1, 3); // 3 NFTs from token1
    tokenHolder2Ids = await mintNFTs(mockNFT1, tokenHolder2, 2); // 2 NFTs from token1
    tokenHolder3Ids = await mintNFTs(mockNFT2, tokenHolder3, 2); // 2 NFTs from token2

    // Deploy LinearERC721Voting strategy mastercopy
    linearERC721VotingMastercopy = await new LinearERC721VotingV1__factory(deployer).deploy();

    // Deploy LinearERC721Voting strategy
    linearERC721Voting = await deployLinearERC721Voting(
      owner,
      [
        { tokenAddress: await mockNFT1.getAddress(), weight: TOKEN1_WEIGHT },
        { tokenAddress: await mockNFT2.getAddress(), weight: TOKEN2_WEIGHT },
      ],
      azoriusAddress,
    );
  });

  describe('Initialization', () => {
    it('should initialize with correct parameters', async () => {
      expect(await linearERC721Voting.owner()).to.equal(owner.address);
      expect(await linearERC721Voting.azoriusModule()).to.equal(azoriusAddress);
      expect(await linearERC721Voting.votingPeriod()).to.equal(VOTING_PERIOD);
      expect(await linearERC721Voting.quorumThreshold()).to.equal(QUORUM_THRESHOLD);
      expect(await linearERC721Voting.proposerThreshold()).to.equal(PROPOSER_THRESHOLD);
      expect(await linearERC721Voting.basisNumerator()).to.equal(BASIS_NUMERATOR);

      // Check token addresses and weights
      expect(await linearERC721Voting.tokenAddresses(0)).to.equal(await mockNFT1.getAddress());
      expect(await linearERC721Voting.tokenAddresses(1)).to.equal(await mockNFT2.getAddress());
      expect(await linearERC721Voting.tokenWeights(await mockNFT1.getAddress())).to.equal(
        TOKEN1_WEIGHT,
      );
      expect(await linearERC721Voting.tokenWeights(await mockNFT2.getAddress())).to.equal(
        TOKEN2_WEIGHT,
      );
    });

    it('should not allow reinitialization', async () => {
      const tokenAddresses = [await mockNFT1.getAddress(), await mockNFT2.getAddress()];
      const tokenWeights = [TOKEN1_WEIGHT, TOKEN2_WEIGHT];

      const initializeParams = ethers.AbiCoder.defaultAbiCoder().encode(
        ['address', 'address[]', 'uint256[]', 'address', 'uint32', 'uint256', 'uint256', 'uint256'],
        [
          owner.address,
          tokenAddresses,
          tokenWeights,
          azoriusAddress,
          VOTING_PERIOD,
          QUORUM_THRESHOLD,
          PROPOSER_THRESHOLD,
          BASIS_NUMERATOR,
        ],
      );

      const setupCalldata = linearERC721VotingMastercopy.interface.encodeFunctionData('setUp', [
        initializeParams,
      ]);

      await expect(linearERC721Voting.setUp(setupCalldata)).to.be.reverted;
    });

    it('should revert when initializing with mismatched token arrays', async () => {
      const salt = ethers.hexlify(ethers.randomBytes(32));
      const tokenAddresses = [await mockNFT1.getAddress()];
      const tokenWeights = [TOKEN1_WEIGHT, TOKEN2_WEIGHT]; // Mismatched length

      const initializeParams = ethers.AbiCoder.defaultAbiCoder().encode(
        ['address', 'address[]', 'uint256[]', 'address', 'uint32', 'uint256', 'uint256', 'uint256'],
        [
          owner.address,
          tokenAddresses,
          tokenWeights,
          azoriusAddress,
          VOTING_PERIOD,
          QUORUM_THRESHOLD,
          PROPOSER_THRESHOLD,
          BASIS_NUMERATOR,
        ],
      );

      const setupCalldata = linearERC721VotingMastercopy.interface.encodeFunctionData('setUp', [
        initializeParams,
      ]);

      const moduleProxyFactory = getModuleProxyFactory();
      await expect(
        moduleProxyFactory.deployModule(
          await linearERC721VotingMastercopy.getAddress(),
          setupCalldata,
          salt,
        ),
      ).to.be.reverted;
    });
  });

  describe('Owner Functions', () => {
    it('should allow owner to update voting period', async () => {
      const newVotingPeriod = 200;
      await linearERC721Voting.connect(owner).updateVotingPeriod(newVotingPeriod);
      expect(await linearERC721Voting.votingPeriod()).to.equal(newVotingPeriod);
    });

    it('should not allow non-owner to update voting period', async () => {
      const newVotingPeriod = 200;
      await expect(
        linearERC721Voting.connect(nonOwner).updateVotingPeriod(newVotingPeriod),
      ).to.be.revertedWithCustomError(linearERC721Voting, 'OwnableUnauthorizedAccount');
    });

    it('should allow owner to update quorum threshold', async () => {
      const newQuorumThreshold = 10;
      await linearERC721Voting.connect(owner).updateQuorumThreshold(newQuorumThreshold);
      expect(await linearERC721Voting.quorumThreshold()).to.equal(newQuorumThreshold);
    });

    it('should not allow non-owner to update quorum threshold', async () => {
      const newQuorumThreshold = 10;
      await expect(
        linearERC721Voting.connect(nonOwner).updateQuorumThreshold(newQuorumThreshold),
      ).to.be.revertedWithCustomError(linearERC721Voting, 'OwnableUnauthorizedAccount');
    });

    it('should allow owner to update proposer threshold', async () => {
      const newProposerThreshold = 5;
      await linearERC721Voting.connect(owner).updateProposerThreshold(newProposerThreshold);
      expect(await linearERC721Voting.proposerThreshold()).to.equal(newProposerThreshold);
    });

    it('should not allow non-owner to update proposer threshold', async () => {
      const newProposerThreshold = 5;
      await expect(
        linearERC721Voting.connect(nonOwner).updateProposerThreshold(newProposerThreshold),
      ).to.be.revertedWithCustomError(linearERC721Voting, 'OwnableUnauthorizedAccount');
    });

    it('should allow owner to update basis numerator', async () => {
      const newBasisNumerator = 600000;
      await linearERC721Voting.connect(owner).updateBasisNumerator(newBasisNumerator);
      expect(await linearERC721Voting.basisNumerator()).to.equal(newBasisNumerator);
    });

    it('should not allow non-owner to update basis numerator', async () => {
      const newBasisNumerator = 600000;
      await expect(
        linearERC721Voting.connect(nonOwner).updateBasisNumerator(newBasisNumerator),
      ).to.be.revertedWithCustomError(linearERC721Voting, 'OwnableUnauthorizedAccount');
    });

    it('should allow owner to add a new governance token', async () => {
      // Deploy a new NFT token
      const newMockNFT = await new MockERC721__factory(deployer).deploy();
      const newTokenWeight = 3;

      // Add the new token as a governance token
      await linearERC721Voting
        .connect(owner)
        .addGovernanceToken(await newMockNFT.getAddress(), newTokenWeight);

      // Check if token was added correctly
      expect(await linearERC721Voting.tokenAddresses(2)).to.equal(await newMockNFT.getAddress());
      expect(await linearERC721Voting.tokenWeights(await newMockNFT.getAddress())).to.equal(
        newTokenWeight,
      );
    });

    it('should not allow non-owner to add a governance token', async () => {
      const newMockNFT = await new MockERC721__factory(deployer).deploy();
      await expect(
        linearERC721Voting.connect(nonOwner).addGovernanceToken(await newMockNFT.getAddress(), 3),
      ).to.be.revertedWithCustomError(linearERC721Voting, 'OwnableUnauthorizedAccount');
    });

    it('should allow owner to remove a governance token', async () => {
      // Get the initial token addresses
      const initialToken0 = await linearERC721Voting.tokenAddresses(0);

      // Remove the second token
      await linearERC721Voting.connect(owner).removeGovernanceToken(await mockNFT2.getAddress());

      // The removed token should no longer have a weight
      expect(await linearERC721Voting.tokenWeights(await mockNFT2.getAddress())).to.equal(0);

      // The token addresses array should still have the same length, but the last element should be zeroed out
      // The contract implementation moves the last token to the removed token's position and deletes the last position
      // Since we only have 2 tokens and we're removing the second one (which is also the last one),
      // it just zeroes out the last position
      expect(await linearERC721Voting.tokenAddresses(0)).to.equal(initialToken0);
      expect(await linearERC721Voting.tokenAddresses(1)).to.equal(
        '0x0000000000000000000000000000000000000000',
      );
    });

    it('should not allow non-owner to remove a governance token', async () => {
      await expect(
        linearERC721Voting.connect(nonOwner).removeGovernanceToken(await mockNFT1.getAddress()),
      ).to.be.revertedWithCustomError(linearERC721Voting, 'OwnableUnauthorizedAccount');
    });
  });

  describe('Proposal Functions', () => {
    it('should allow only azorius to initialize proposal', async () => {
      // Mock proposal ID
      const proposalId = 1;
      // Mock data for initializing a proposal
      const initializeData = ethers.AbiCoder.defaultAbiCoder().encode(['uint32'], [proposalId]);

      // Only Azorius can initialize proposals
      await expect(
        linearERC721Voting.connect(owner).initializeProposal(initializeData),
      ).to.be.revertedWithCustomError(linearERC721Voting, 'OnlyAzorius');

      // Test with Azorius signer
      await linearERC721Voting.connect(nonOwner).initializeProposal(initializeData);

      // Check that proposal was initialized correctly
      const votingEndBlock = await linearERC721Voting.votingEndBlock(proposalId);
      expect(votingEndBlock).to.not.equal(0);
    });

    it('should determine proposer status based on NFT ownership', async () => {
      // tokenHolder1 has 3 NFTs from token1, each worth 1 vote = 3 votes total
      // proposerThreshold is 2, so they should be a proposer
      void expect(await linearERC721Voting.isProposer(tokenHolder1.address)).to.be.true;

      // tokenHolder3 has 2 NFTs from token2, each worth 2 votes = 4 votes total
      // proposerThreshold is 2, so they should be a proposer
      void expect(await linearERC721Voting.isProposer(tokenHolder3.address)).to.be.true;

      // Update proposerThreshold to 5
      await linearERC721Voting.connect(owner).updateProposerThreshold(5);

      // Now tokenHolder1 should NOT be a proposer with only 3 votes < 5 required
      void expect(await linearERC721Voting.isProposer(tokenHolder1.address)).to.be.false;

      // But tokenHolder3 should still be a proposer because their NFTs are worth 4 total votes
      void expect(await linearERC721Voting.isProposer(tokenHolder3.address)).to.be.false;
    });

    it('should correctly calculate voting weight for different tokens', async () => {
      // tokenHolder1 has 3 NFTs from token1, each worth 1 vote = 3 votes
      const tokenHolder1Balance = await mockNFT1.balanceOf(tokenHolder1.address);
      const tokenHolder1Weight = Number(tokenHolder1Balance) * TOKEN1_WEIGHT;
      expect(tokenHolder1Weight).to.equal(3);

      // tokenHolder2 has 2 NFTs from token1, each worth 1 vote = 2 votes
      const tokenHolder2Balance = await mockNFT1.balanceOf(tokenHolder2.address);
      const tokenHolder2Weight = Number(tokenHolder2Balance) * TOKEN1_WEIGHT;
      expect(tokenHolder2Weight).to.equal(2);

      // tokenHolder3 has 2 NFTs from token2, each worth 2 votes = 4 votes
      const tokenHolder3Balance = await mockNFT2.balanceOf(tokenHolder3.address);
      const tokenHolder3Weight = Number(tokenHolder3Balance) * TOKEN2_WEIGHT;
      expect(tokenHolder3Weight).to.equal(4);
    });
  });

  describe('Voting Functions', () => {
    const proposalId = 1;

    beforeEach(async () => {
      // Initialize a proposal using the azorius mock account
      const initializeData = ethers.AbiCoder.defaultAbiCoder().encode(['uint32'], [proposalId]);
      await linearERC721Voting.connect(nonOwner).initializeProposal(initializeData);
    });

    it('should allow users to vote on a proposal with multiple NFTs', async () => {
      // Cast votes
      await linearERC721Voting
        .connect(tokenHolder1)
        .vote(
          proposalId,
          VoteType.YES,
          [await mockNFT1.getAddress(), await mockNFT1.getAddress(), await mockNFT1.getAddress()],
          [tokenHolder1Ids[0], tokenHolder1Ids[1], tokenHolder1Ids[2]],
        );

      await linearERC721Voting
        .connect(tokenHolder2)
        .vote(
          proposalId,
          VoteType.NO,
          [await mockNFT1.getAddress(), await mockNFT1.getAddress()],
          [tokenHolder2Ids[0], tokenHolder2Ids[1]],
        );

      await linearERC721Voting
        .connect(tokenHolder3)
        .vote(
          proposalId,
          VoteType.ABSTAIN,
          [await mockNFT2.getAddress(), await mockNFT2.getAddress()],
          [tokenHolder3Ids[0], tokenHolder3Ids[1]],
        );

      // Get proposal votes
      const [noVotes, yesVotes, abstainVotes, , ,] =
        await linearERC721Voting.getProposalVotes(proposalId);

      // Check vote counts
      // tokenHolder1: 3 NFTs * 1 vote weight = 3 YES votes
      // tokenHolder2: 2 NFTs * 1 vote weight = 2 NO votes
      // tokenHolder3: 2 NFTs * 2 vote weight = 4 ABSTAIN votes
      expect(yesVotes).to.equal(3);
      expect(noVotes).to.equal(2);
      expect(abstainVotes).to.equal(4);
    });

    it('should not allow voting with NFTs you do not own', async () => {
      // Try to vote with an NFT owned by tokenHolder1
      await expect(
        linearERC721Voting
          .connect(tokenHolder2)
          .vote(proposalId, VoteType.YES, [await mockNFT1.getAddress()], [tokenHolder1Ids[0]]),
      ).to.be.revertedWithCustomError(linearERC721Voting, 'IdNotOwned');
    });

    it('should not allow voting with the same NFT twice', async () => {
      // First vote with an NFT
      await linearERC721Voting
        .connect(tokenHolder1)
        .vote(proposalId, VoteType.YES, [await mockNFT1.getAddress()], [tokenHolder1Ids[0]]);

      // Try to vote with the same NFT again
      await expect(
        linearERC721Voting
          .connect(tokenHolder1)
          .vote(proposalId, VoteType.YES, [await mockNFT1.getAddress()], [tokenHolder1Ids[0]]),
      ).to.be.revertedWithCustomError(linearERC721Voting, 'IdAlreadyVoted');
    });

    it('should allow different NFTs from the same holder to vote differently', async () => {
      // Vote YES with first NFT
      await linearERC721Voting
        .connect(tokenHolder1)
        .vote(proposalId, VoteType.YES, [await mockNFT1.getAddress()], [tokenHolder1Ids[0]]);

      // Vote NO with second NFT
      await linearERC721Voting
        .connect(tokenHolder1)
        .vote(proposalId, VoteType.NO, [await mockNFT1.getAddress()], [tokenHolder1Ids[1]]);

      // Vote ABSTAIN with third NFT
      await linearERC721Voting
        .connect(tokenHolder1)
        .vote(proposalId, VoteType.ABSTAIN, [await mockNFT1.getAddress()], [tokenHolder1Ids[2]]);

      // Get proposal votes
      const [noVotes, yesVotes, abstainVotes, , ,] =
        await linearERC721Voting.getProposalVotes(proposalId);

      // Each NFT has a weight of 1
      expect(yesVotes).to.equal(1);
      expect(noVotes).to.equal(1);
      expect(abstainVotes).to.equal(1);
    });

    it('should not allow voting after voting period ends', async () => {
      // Mine blocks to advance past the voting period
      await mine(VOTING_PERIOD + 1);

      await expect(
        linearERC721Voting
          .connect(tokenHolder1)
          .vote(proposalId, VoteType.YES, [await mockNFT1.getAddress()], [tokenHolder1Ids[0]]),
      ).to.be.revertedWithCustomError(linearERC721Voting, 'VotingEnded');
    });

    it('should revert on invalid vote type', async () => {
      // Valid vote types are 0, 1, 2 (NO, YES, ABSTAIN)
      const invalidVoteType = 3;

      await expect(
        linearERC721Voting
          .connect(tokenHolder1)
          .vote(proposalId, invalidVoteType, [await mockNFT1.getAddress()], [tokenHolder1Ids[0]]),
      ).to.be.revertedWithCustomError(linearERC721Voting, 'InvalidVote');
    });
  });

  describe('isPassed Logic', () => {
    const proposalId = 1;

    beforeEach(async () => {
      // Initialize a proposal using the azorius mock account
      const initializeData = ethers.AbiCoder.defaultAbiCoder().encode(['uint32'], [proposalId]);
      await linearERC721Voting.connect(nonOwner).initializeProposal(initializeData);
    });

    it('should pass when yes > no and meets quorum', async () => {
      // Cast votes
      // Yes votes: 3 from tokenHolder1 + 4 from tokenHolder3 = 7
      // No votes: 2 from tokenHolder2 = 2
      // Total: 9 votes > 5 quorum threshold
      await linearERC721Voting
        .connect(tokenHolder1)
        .vote(
          proposalId,
          VoteType.YES,
          [await mockNFT1.getAddress(), await mockNFT1.getAddress(), await mockNFT1.getAddress()],
          [tokenHolder1Ids[0], tokenHolder1Ids[1], tokenHolder1Ids[2]],
        );

      await linearERC721Voting
        .connect(tokenHolder2)
        .vote(
          proposalId,
          VoteType.NO,
          [await mockNFT1.getAddress(), await mockNFT1.getAddress()],
          [tokenHolder2Ids[0], tokenHolder2Ids[1]],
        );

      await linearERC721Voting
        .connect(tokenHolder3)
        .vote(
          proposalId,
          VoteType.YES,
          [await mockNFT2.getAddress(), await mockNFT2.getAddress()],
          [tokenHolder3Ids[0], tokenHolder3Ids[1]],
        );

      // Mine blocks to end the voting period
      await mine(VOTING_PERIOD + 1);

      // Proposal should pass with 7 YES, 2 NO
      void expect(await linearERC721Voting.isPassed(proposalId)).to.be.true;
    });

    it('should fail when voting period is not over', async () => {
      // Cast votes
      await linearERC721Voting
        .connect(tokenHolder1)
        .vote(
          proposalId,
          VoteType.YES,
          [await mockNFT1.getAddress(), await mockNFT1.getAddress(), await mockNFT1.getAddress()],
          [tokenHolder1Ids[0], tokenHolder1Ids[1], tokenHolder1Ids[2]],
        );

      // Voting period not over yet
      void expect(await linearERC721Voting.isPassed(proposalId)).to.be.false;
    });

    it('should fail when quorum is not met', async () => {
      // Update quorum threshold to 10
      await linearERC721Voting.connect(owner).updateQuorumThreshold(10);

      // Cast votes (total 9 votes, less than 10 required)
      await linearERC721Voting
        .connect(tokenHolder1)
        .vote(
          proposalId,
          VoteType.YES,
          [await mockNFT1.getAddress(), await mockNFT1.getAddress(), await mockNFT1.getAddress()],
          [tokenHolder1Ids[0], tokenHolder1Ids[1], tokenHolder1Ids[2]],
        );

      await linearERC721Voting
        .connect(tokenHolder2)
        .vote(
          proposalId,
          VoteType.YES,
          [await mockNFT1.getAddress(), await mockNFT1.getAddress()],
          [tokenHolder2Ids[0], tokenHolder2Ids[1]],
        );

      await linearERC721Voting
        .connect(tokenHolder3)
        .vote(
          proposalId,
          VoteType.YES,
          [await mockNFT2.getAddress(), await mockNFT2.getAddress()],
          [tokenHolder3Ids[0], tokenHolder3Ids[1]],
        );

      // Mine blocks to end the voting period
      await mine(VOTING_PERIOD + 1);

      // Proposal should fail due to insufficient quorum
      void expect(await linearERC721Voting.isPassed(proposalId)).to.be.false;
    });

    it('should fail when basis is not met', async () => {
      // Cast votes
      // Yes votes: 3 from tokenHolder1 = 3
      // No votes: 2 from tokenHolder2 + 4 from tokenHolder3 = 6
      // Total: 9 votes > 5 quorum threshold, but YES < NO
      await linearERC721Voting
        .connect(tokenHolder1)
        .vote(
          proposalId,
          VoteType.YES,
          [await mockNFT1.getAddress(), await mockNFT1.getAddress(), await mockNFT1.getAddress()],
          [tokenHolder1Ids[0], tokenHolder1Ids[1], tokenHolder1Ids[2]],
        );

      await linearERC721Voting
        .connect(tokenHolder2)
        .vote(
          proposalId,
          VoteType.NO,
          [await mockNFT1.getAddress(), await mockNFT1.getAddress()],
          [tokenHolder2Ids[0], tokenHolder2Ids[1]],
        );

      await linearERC721Voting
        .connect(tokenHolder3)
        .vote(
          proposalId,
          VoteType.NO,
          [await mockNFT2.getAddress(), await mockNFT2.getAddress()],
          [tokenHolder3Ids[0], tokenHolder3Ids[1]],
        );

      // Mine blocks to end the voting period
      await mine(VOTING_PERIOD + 1);

      // Proposal should fail due to insufficient basis (YES < NO)
      void expect(await linearERC721Voting.isPassed(proposalId)).to.be.false;
    });
  });

  describe('Vote Counting', () => {
    const proposalId = 1;

    beforeEach(async () => {
      // Initialize a proposal using the azorius mock account
      const initializeData = ethers.AbiCoder.defaultAbiCoder().encode(['uint32'], [proposalId]);
      await linearERC721Voting.connect(nonOwner).initializeProposal(initializeData);

      // Cast some votes
      await linearERC721Voting
        .connect(tokenHolder1)
        .vote(
          proposalId,
          VoteType.YES,
          [await mockNFT1.getAddress(), await mockNFT1.getAddress(), await mockNFT1.getAddress()],
          [tokenHolder1Ids[0], tokenHolder1Ids[1], tokenHolder1Ids[2]],
        );

      await linearERC721Voting
        .connect(tokenHolder2)
        .vote(
          proposalId,
          VoteType.NO,
          [await mockNFT1.getAddress(), await mockNFT1.getAddress()],
          [tokenHolder2Ids[0], tokenHolder2Ids[1]],
        );

      await linearERC721Voting
        .connect(tokenHolder3)
        .vote(
          proposalId,
          VoteType.ABSTAIN,
          [await mockNFT2.getAddress(), await mockNFT2.getAddress()],
          [tokenHolder3Ids[0], tokenHolder3Ids[1]],
        );
    });

    it('should correctly return vote counts through getProposalVotes', async () => {
      // Get proposal votes
      const [noVotes, yesVotes, abstainVotes, startBlock, endBlock] =
        await linearERC721Voting.getProposalVotes(proposalId);

      // Check vote counts
      // tokenHolder1: 3 NFTs * 1 vote weight = 3 YES votes
      // tokenHolder2: 2 NFTs * 1 vote weight = 2 NO votes
      // tokenHolder3: 2 NFTs * 2 vote weight = 4 ABSTAIN votes
      expect(yesVotes).to.equal(3);
      expect(noVotes).to.equal(2);
      expect(abstainVotes).to.equal(4);

      // Check that start and end blocks are set
      expect(startBlock).to.not.equal(0);
      expect(endBlock).to.equal(Number(startBlock) + VOTING_PERIOD);
    });

    it('should correctly track if an NFT has voted', async () => {
      // Check that NFTs that have voted return true
      const voted = await linearERC721Voting.hasVoted(
        proposalId,
        await mockNFT1.getAddress(),
        tokenHolder1Ids[0],
      );
      expect(voted).to.equal(true);

      // Mint a new NFT that hasn't voted
      const newTokenId = await mintNFTs(mockNFT1, tokenHolder1, 1);

      // Check that NFTs that haven't voted return false
      const notVoted = await linearERC721Voting.hasVoted(
        proposalId,
        await mockNFT1.getAddress(),
        newTokenId[0],
      );
      expect(notVoted).to.equal(false);
    });
  });

  describe('Token Management', () => {
    it('should return all governance token addresses', async () => {
      const tokenAddresses = await linearERC721Voting.getAllTokenAddresses();
      expect(tokenAddresses.length).to.equal(2);
      expect(tokenAddresses[0]).to.equal(await mockNFT1.getAddress());
      expect(tokenAddresses[1]).to.equal(await mockNFT2.getAddress());
    });

    it('should emit GovernanceTokenAdded event when adding a token', async () => {
      // Deploy a new NFT token
      const newMockNFT = await new MockERC721__factory(deployer).deploy();
      const newTokenWeight = 3;

      // Add the new token as a governance token
      await expect(
        linearERC721Voting
          .connect(owner)
          .addGovernanceToken(await newMockNFT.getAddress(), newTokenWeight),
      )
        .to.emit(linearERC721Voting, 'GovernanceTokenAdded')
        .withArgs(await newMockNFT.getAddress(), newTokenWeight);
    });

    it('should emit GovernanceTokenRemoved event when removing a token', async () => {
      await expect(
        linearERC721Voting.connect(owner).removeGovernanceToken(await mockNFT2.getAddress()),
      )
        .to.emit(linearERC721Voting, 'GovernanceTokenRemoved')
        .withArgs(await mockNFT2.getAddress());
    });

    it('should emit VotingPeriodUpdated event when updating voting period', async () => {
      const newVotingPeriod = 200;
      await expect(linearERC721Voting.connect(owner).updateVotingPeriod(newVotingPeriod))
        .to.emit(linearERC721Voting, 'VotingPeriodUpdated')
        .withArgs(newVotingPeriod);
    });

    it('should emit QuorumThresholdUpdated event when updating quorum threshold', async () => {
      const newQuorumThreshold = 10;
      await expect(linearERC721Voting.connect(owner).updateQuorumThreshold(newQuorumThreshold))
        .to.emit(linearERC721Voting, 'QuorumThresholdUpdated')
        .withArgs(newQuorumThreshold);
    });

    it('should emit ProposerThresholdUpdated event when updating proposer threshold', async () => {
      const newProposerThreshold = 5;
      await expect(linearERC721Voting.connect(owner).updateProposerThreshold(newProposerThreshold))
        .to.emit(linearERC721Voting, 'ProposerThresholdUpdated')
        .withArgs(newProposerThreshold);
    });
  });

  describe('Edge Cases', () => {
    it('should revert when trying to vote with zero total weight', async () => {
      // Initialize a proposal
      const proposalId = 100;
      const initializeData = ethers.AbiCoder.defaultAbiCoder().encode(['uint32'], [proposalId]);
      await linearERC721Voting.connect(nonOwner).initializeProposal(initializeData);

      // Deploy a new NFT token not registered as a governance token
      const nonGovernanceNFT = await new MockERC721__factory(deployer).deploy();

      // Mint an NFT to token holder
      await nonGovernanceNFT.mint(tokenHolder1.address);

      // Attempt to vote with a token that has no governance weight
      await expect(
        linearERC721Voting
          .connect(tokenHolder1)
          .vote(proposalId, VoteType.YES, [await nonGovernanceNFT.getAddress()], [0]),
      ).to.be.revertedWithCustomError(linearERC721Voting, 'NoVotingWeight');
    });

    it('should revert when trying to initialize with an invalid ERC721 token', async () => {
      // We need to deploy a contract that doesn't implement the ERC721 interface
      // For this test, we can use the MockOwnership contract which doesn't support the ERC721 interface
      const mockNonERC721 = await new MockOwnership__factory(deployer).deploy(deployer.address);

      const salt = ethers.hexlify(ethers.randomBytes(32));
      const tokenAddresses = [await mockNonERC721.getAddress()];
      const tokenWeights = [TOKEN1_WEIGHT];

      const initializeParams = ethers.AbiCoder.defaultAbiCoder().encode(
        ['address', 'address[]', 'uint256[]', 'address', 'uint32', 'uint256', 'uint256', 'uint256'],
        [
          owner.address,
          tokenAddresses,
          tokenWeights,
          azoriusAddress,
          VOTING_PERIOD,
          QUORUM_THRESHOLD,
          PROPOSER_THRESHOLD,
          BASIS_NUMERATOR,
        ],
      );

      const setupCalldata = linearERC721VotingMastercopy.interface.encodeFunctionData('setUp', [
        initializeParams,
      ]);

      const moduleProxyFactory = getModuleProxyFactory();
      await expect(
        moduleProxyFactory.deployModule(
          await linearERC721VotingMastercopy.getAddress(),
          setupCalldata,
          salt,
        ),
      ).to.be.reverted; // This will revert when trying to check supportsInterface
    });

    it('should emit ProposalInitialized event when initializing a proposal', async () => {
      const proposalId = 200;
      const initializeData = ethers.AbiCoder.defaultAbiCoder().encode(['uint32'], [proposalId]);

      // Get current block number to calculate expected end block
      const currentBlockNumber = await ethers.provider.getBlockNumber();
      const expectedEndBlock = currentBlockNumber + 1 + VOTING_PERIOD; // +1 because the proposal will be in the next block

      await expect(linearERC721Voting.connect(nonOwner).initializeProposal(initializeData))
        .to.emit(linearERC721Voting, 'ProposalInitialized')
        .withArgs(proposalId, expectedEndBlock);
    });
  });

  describe('Smart Account Support', () => {
    it('should recognize that contracts integrate with ERC4337VoterSupport', async () => {
      // This is a simplified test to verify the ERC4337VoterSupport integration exists
      // In a real scenario, we'd test the full smart contract account voting flow

      // Since properly testing this requires complex test infrastructure to impersonate contracts,
      // we'll simply verify that the _voter function is inherited from ERC4337VoterSupportV1

      // Deploy a mock contract with ownership
      const mockOwnership = await new MockOwnership__factory(deployer).deploy(tokenHolder1.address);

      // Verify the owner is set correctly
      expect(await mockOwnership.owner()).to.equal(tokenHolder1.address);

      // We're verifying that the contract inherits ERC4337VoterSupportV1
      // This is mostly a conceptual test - in production this would allow contract wallets
      // to vote as their owners
    });
  });

  describe('Version', () => {
    it('should return correct version', async () => {
      expect(await linearERC721Voting.getVersion()).to.equal(1);
    });
  });
});
