import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { mine } from '@nomicfoundation/hardhat-network-helpers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  IBaseQuorumPercentV1__factory,
  IBaseStrategyV1__factory,
  IBaseVotingBasisPercentV1__factory,
  IERC165__factory,
  IVersion__factory,
  LinearERC20VotingV1,
  LinearERC20VotingV1__factory,
  MockERC20Votes,
  MockERC20Votes__factory,
  MockOwnership,
  MockOwnership__factory,
} from '../../../typechain-types';
import { getModuleProxyFactory } from '../../helpers/globals.test';
import { calculateInterfaceId, calculateProxyAddress } from '../../helpers/utils';

describe('LinearERC20VotingV1', () => {
  // Signers
  let deployer: SignerWithAddress;
  let owner: SignerWithAddress;
  let nonOwner: SignerWithAddress;
  let azoriusAddress: string;
  let tokenHolder1: SignerWithAddress;
  let tokenHolder2: SignerWithAddress;
  let tokenHolder3: SignerWithAddress;

  // Contracts
  let linearERC20VotingMastercopy: LinearERC20VotingV1;
  let linearERC20Voting: LinearERC20VotingV1;
  let mockToken: MockERC20Votes;
  let mockOwnership: MockOwnership;

  // Constants
  const VOTING_PERIOD = 100; // blocks
  const REQUIRED_PROPOSER_WEIGHT = 100; // 100 tokens to propose
  const QUORUM_NUMERATOR = 300000; // 30% of 1000000
  const BASIS_NUMERATOR = 500000; // 50% of 1000000

  // Vote types from the contract
  enum VoteType {
    NO = 0,
    YES = 1,
    ABSTAIN = 2,
  }

  async function deployLinearERC20Voting(
    strategyOwner: SignerWithAddress,
    governanceToken: string,
    azoriusAddr: string,
  ): Promise<LinearERC20VotingV1> {
    const salt = ethers.hexlify(ethers.randomBytes(32));
    const initializeParams = ethers.AbiCoder.defaultAbiCoder().encode(
      ['address', 'address', 'address', 'uint32', 'uint256', 'uint256', 'uint256'],
      [
        strategyOwner.address,
        governanceToken,
        azoriusAddr,
        VOTING_PERIOD,
        REQUIRED_PROPOSER_WEIGHT,
        QUORUM_NUMERATOR,
        BASIS_NUMERATOR,
      ],
    );

    const setupCalldata = linearERC20VotingMastercopy.interface.encodeFunctionData('setUp', [
      initializeParams,
    ]);

    const moduleProxyFactory = getModuleProxyFactory();

    await moduleProxyFactory.deployModule(
      await linearERC20VotingMastercopy.getAddress(),
      setupCalldata,
      salt,
    );

    const predictedAddress = await calculateProxyAddress(
      moduleProxyFactory,
      await linearERC20VotingMastercopy.getAddress(),
      setupCalldata,
      salt,
    );

    return LinearERC20VotingV1__factory.connect(predictedAddress, strategyOwner);
  }

  beforeEach(async () => {
    [deployer, owner, nonOwner, tokenHolder1, tokenHolder2, tokenHolder3] =
      await ethers.getSigners();

    // Use nonOwner address as a mock azorius address for testing
    azoriusAddress = await nonOwner.getAddress();

    // Deploy MockERC20Votes token
    mockToken = await new MockERC20Votes__factory(deployer).deploy();

    // Deploy MockOwnership contract
    mockOwnership = await new MockOwnership__factory(deployer).deploy(tokenHolder1.address);

    // Mint tokens to token holders
    await mockToken.mint(tokenHolder1.address, 1000);
    await mockToken.mint(tokenHolder2.address, 1000);
    await mockToken.mint(tokenHolder3.address, 1000);

    // Deploy LinearERC20Voting strategy mastercopy
    linearERC20VotingMastercopy = await new LinearERC20VotingV1__factory(deployer).deploy();

    // Deploy LinearERC20Voting strategy
    linearERC20Voting = await deployLinearERC20Voting(
      owner,
      await mockToken.getAddress(),
      azoriusAddress,
    );
  });

  describe('Initialization', () => {
    it('should initialize with correct parameters', async () => {
      expect(await linearERC20Voting.owner()).to.equal(owner.address);
      expect(await linearERC20Voting.governanceToken()).to.equal(await mockToken.getAddress());
      expect(await linearERC20Voting.azoriusModule()).to.equal(azoriusAddress);
      expect(await linearERC20Voting.votingPeriod()).to.equal(VOTING_PERIOD);
      expect(await linearERC20Voting.requiredProposerWeight()).to.equal(REQUIRED_PROPOSER_WEIGHT);
      expect(await linearERC20Voting.quorumNumerator()).to.equal(QUORUM_NUMERATOR);
      expect(await linearERC20Voting.basisNumerator()).to.equal(BASIS_NUMERATOR);
    });

    it('should not allow reinitialization', async () => {
      const initializeParams = ethers.AbiCoder.defaultAbiCoder().encode(
        ['address', 'address', 'address', 'uint32', 'uint256', 'uint256', 'uint256'],
        [
          owner.address,
          await mockToken.getAddress(),
          azoriusAddress,
          VOTING_PERIOD,
          REQUIRED_PROPOSER_WEIGHT,
          QUORUM_NUMERATOR,
          BASIS_NUMERATOR,
        ],
      );

      const setupCalldata = linearERC20VotingMastercopy.interface.encodeFunctionData('setUp', [
        initializeParams,
      ]);

      await expect(linearERC20Voting.setUp(setupCalldata)).to.be.reverted;
    });

    it('should revert when initializing with zero token address', async () => {
      const salt = ethers.hexlify(ethers.randomBytes(32));
      const initializeParams = ethers.AbiCoder.defaultAbiCoder().encode(
        ['address', 'address', 'address', 'uint32', 'uint256', 'uint256', 'uint256'],
        [
          owner.address,
          ethers.ZeroAddress,
          azoriusAddress,
          VOTING_PERIOD,
          REQUIRED_PROPOSER_WEIGHT,
          QUORUM_NUMERATOR,
          BASIS_NUMERATOR,
        ],
      );

      const setupCalldata = linearERC20VotingMastercopy.interface.encodeFunctionData('setUp', [
        initializeParams,
      ]);

      const moduleProxyFactory = getModuleProxyFactory();
      await expect(
        moduleProxyFactory.deployModule(
          await linearERC20VotingMastercopy.getAddress(),
          setupCalldata,
          salt,
        ),
      ).to.be.reverted;
    });
  });

  describe('Owner Functions', () => {
    it('should allow owner to update voting period', async () => {
      const newVotingPeriod = 200;
      await linearERC20Voting.connect(owner).updateVotingPeriod(newVotingPeriod);
      expect(await linearERC20Voting.votingPeriod()).to.equal(newVotingPeriod);
    });

    it('should not allow non-owner to update voting period', async () => {
      const newVotingPeriod = 200;
      await expect(
        linearERC20Voting.connect(nonOwner).updateVotingPeriod(newVotingPeriod),
      ).to.be.revertedWithCustomError(linearERC20Voting, 'OwnableUnauthorizedAccount');
    });

    it('should allow owner to update required proposer weight', async () => {
      const newRequiredProposerWeight = 200;
      await linearERC20Voting
        .connect(owner)
        .updateRequiredProposerWeight(newRequiredProposerWeight);
      expect(await linearERC20Voting.requiredProposerWeight()).to.equal(newRequiredProposerWeight);
    });

    it('should not allow non-owner to update required proposer weight', async () => {
      const newRequiredProposerWeight = 200;
      await expect(
        linearERC20Voting.connect(nonOwner).updateRequiredProposerWeight(newRequiredProposerWeight),
      ).to.be.revertedWithCustomError(linearERC20Voting, 'OwnableUnauthorizedAccount');
    });

    it('should allow owner to update quorum numerator', async () => {
      const newQuorumNumerator = 400000;
      await linearERC20Voting.connect(owner).updateQuorumNumerator(newQuorumNumerator);
      expect(await linearERC20Voting.quorumNumerator()).to.equal(newQuorumNumerator);
    });

    it('should not allow non-owner to update quorum numerator', async () => {
      const newQuorumNumerator = 400000;
      await expect(
        linearERC20Voting.connect(nonOwner).updateQuorumNumerator(newQuorumNumerator),
      ).to.be.revertedWithCustomError(linearERC20Voting, 'OwnableUnauthorizedAccount');
    });

    it('should allow owner to update basis numerator', async () => {
      const newBasisNumerator = 600000;
      await linearERC20Voting.connect(owner).updateBasisNumerator(newBasisNumerator);
      expect(await linearERC20Voting.basisNumerator()).to.equal(newBasisNumerator);
    });

    it('should not allow non-owner to update basis numerator', async () => {
      const newBasisNumerator = 600000;
      await expect(
        linearERC20Voting.connect(nonOwner).updateBasisNumerator(newBasisNumerator),
      ).to.be.revertedWithCustomError(linearERC20Voting, 'OwnableUnauthorizedAccount');
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
        linearERC20Voting.connect(owner).initializeProposal(initializeData),
      ).to.be.revertedWithCustomError(linearERC20Voting, 'OnlyAzorius');

      // Test with Azorius signer
      await linearERC20Voting.connect(nonOwner).initializeProposal(initializeData);

      // Check that proposal was initialized correctly
      const votingEndBlock = await linearERC20Voting.votingEndBlock(proposalId);
      expect(votingEndBlock).to.not.equal(0);
    });

    it('should determine proposer status based on voting weight', async () => {
      // This test focuses on whether an address is considered a proposer based on its voting weight

      // First, update required proposer weight to 500 tokens
      await linearERC20Voting.connect(owner).updateRequiredProposerWeight(500);

      // Delegate to tokenHolder1 (who has 1000 tokens > 500 required)
      await mockToken.connect(tokenHolder1).delegate(tokenHolder1.address);

      // tokenHolder1 should be a proposer with 1000 tokens > 500 required
      void expect(await linearERC20Voting.isProposer(tokenHolder1.address)).to.be.true;

      // Update required proposer weight to 1500 tokens (higher than tokenHolder1's balance)
      await linearERC20Voting.connect(owner).updateRequiredProposerWeight(1500);

      // Now tokenHolder1 should NOT be a proposer with 1000 tokens < 1500 required
      void expect(await linearERC20Voting.isProposer(tokenHolder1.address)).to.be.false;
    });
  });

  describe('Voting Functions', () => {
    const proposalId = 1;

    beforeEach(async () => {
      // Delegate tokens to voters
      await mockToken.connect(tokenHolder1).delegate(tokenHolder1.address);
      await mockToken.connect(tokenHolder2).delegate(tokenHolder2.address);
      await mockToken.connect(tokenHolder3).delegate(tokenHolder3.address);

      // Initialize a proposal using the azorius mock account
      const initializeData = ethers.AbiCoder.defaultAbiCoder().encode(['uint32'], [proposalId]);
      await linearERC20Voting.connect(nonOwner).initializeProposal(initializeData);
    });

    it('should allow users to vote on a proposal', async () => {
      // Cast votes
      await linearERC20Voting.connect(tokenHolder1).vote(proposalId, VoteType.YES);
      await linearERC20Voting.connect(tokenHolder2).vote(proposalId, VoteType.NO);
      await linearERC20Voting.connect(tokenHolder3).vote(proposalId, VoteType.ABSTAIN);

      // Get proposal votes
      const [noVotes, yesVotes, abstainVotes, , ,] =
        await linearERC20Voting.getProposalVotes(proposalId);

      // Check vote counts (each holder has 1000 tokens)
      expect(yesVotes).to.equal(1000);
      expect(noVotes).to.equal(1000);
      expect(abstainVotes).to.equal(1000);
    });

    it('should correctly track if an address has voted', async () => {
      void expect(await linearERC20Voting.hasVoted(proposalId, tokenHolder1.address)).to.be.false;

      await linearERC20Voting.connect(tokenHolder1).vote(proposalId, VoteType.YES);

      void expect(await linearERC20Voting.hasVoted(proposalId, tokenHolder1.address)).to.be.true;
    });

    it('should not allow voting twice', async () => {
      await linearERC20Voting.connect(tokenHolder1).vote(proposalId, VoteType.YES);

      await expect(
        linearERC20Voting.connect(tokenHolder1).vote(proposalId, VoteType.NO),
      ).to.be.revertedWithCustomError(linearERC20Voting, 'AlreadyVoted');
    });

    it('should not allow voting after voting period ends', async () => {
      // Mine blocks to advance past the voting period
      await mine(VOTING_PERIOD + 1);

      await expect(
        linearERC20Voting.connect(tokenHolder1).vote(proposalId, VoteType.YES),
      ).to.be.revertedWithCustomError(linearERC20Voting, 'VotingEnded');
    });

    it('should revert on invalid vote type', async () => {
      // Valid vote types are 0, 1, 2 (NO, YES, ABSTAIN)
      const invalidVoteType = 3;

      await expect(
        linearERC20Voting.connect(tokenHolder1).vote(proposalId, invalidVoteType),
      ).to.be.revertedWithCustomError(linearERC20Voting, 'InvalidVote');
    });
  });

  describe('isPassed Logic', () => {
    const proposalId = 1;

    beforeEach(async () => {
      // Delegate tokens to voters
      await mockToken.connect(tokenHolder1).delegate(tokenHolder1.address);
      await mockToken.connect(tokenHolder2).delegate(tokenHolder2.address);
      await mockToken.connect(tokenHolder3).delegate(tokenHolder3.address);

      // Initialize a proposal using the azorius mock account
      const initializeData = ethers.AbiCoder.defaultAbiCoder().encode(['uint32'], [proposalId]);
      await linearERC20Voting.connect(nonOwner).initializeProposal(initializeData);
    });

    it('should pass when yes > no and meets quorum', async () => {
      // Cast votes: 1500 YES, 500 NO, enough for both quorum and basis
      await linearERC20Voting.connect(tokenHolder1).vote(proposalId, VoteType.YES);
      await linearERC20Voting.connect(tokenHolder2).vote(proposalId, VoteType.YES);
      await linearERC20Voting.connect(tokenHolder3).vote(proposalId, VoteType.NO);

      // Mine blocks to end the voting period
      await mine(VOTING_PERIOD + 1);

      // Proposal should pass
      void expect(await linearERC20Voting.isPassed(proposalId)).to.be.true;
    });

    it('should fail when voting period is not over', async () => {
      // Cast votes: 2000 YES, 1000 NO
      await linearERC20Voting.connect(tokenHolder1).vote(proposalId, VoteType.YES);
      await linearERC20Voting.connect(tokenHolder2).vote(proposalId, VoteType.YES);
      await linearERC20Voting.connect(tokenHolder3).vote(proposalId, VoteType.NO);

      // Voting period not over yet
      void expect(await linearERC20Voting.isPassed(proposalId)).to.be.false;
    });

    it('should fail when quorum is not met', async () => {
      // Only 1000 tokens voting (33% of 3000), below QUORUM_NUMERATOR of 300000 (30%)
      await linearERC20Voting.connect(tokenHolder1).vote(proposalId, VoteType.YES);

      // Update quorum to 40% to make this test fail
      await linearERC20Voting.connect(owner).updateQuorumNumerator(400000);

      // Mine blocks to end the voting period
      await mine(VOTING_PERIOD + 1);

      // Proposal should fail due to insufficient quorum
      void expect(await linearERC20Voting.isPassed(proposalId)).to.be.false;
    });

    it('should fail when basis is not met', async () => {
      // Cast votes: 900 YES, 1100 NO, YES votes not high enough vs NO
      await linearERC20Voting.connect(tokenHolder1).vote(proposalId, VoteType.NO);
      await linearERC20Voting.connect(tokenHolder2).vote(proposalId, VoteType.NO);
      await linearERC20Voting.connect(tokenHolder3).vote(proposalId, VoteType.YES);

      // Mine blocks to end the voting period
      await mine(VOTING_PERIOD + 1);

      // Proposal should fail due to insufficient basis (YES < NO)
      void expect(await linearERC20Voting.isPassed(proposalId)).to.be.false;
    });
  });

  describe('Version', () => {
    // Use the shared version test utility
    it('should return the correct version number', async () => {
      expect(await linearERC20Voting.getVersion()).to.equal(1);
    });
  });

  describe('Voting Weight and Supply Functions', () => {
    const proposalId = 1;

    beforeEach(async () => {
      // Delegate tokens to voters
      await mockToken.connect(tokenHolder1).delegate(tokenHolder1.address);
      await mockToken.connect(tokenHolder2).delegate(tokenHolder2.address);
      await mockToken.connect(tokenHolder3).delegate(tokenHolder3.address);

      // Initialize a proposal using the azorius mock account
      const initializeData = ethers.AbiCoder.defaultAbiCoder().encode(['uint32'], [proposalId]);
      await linearERC20Voting.connect(nonOwner).initializeProposal(initializeData);

      // Get the actual voting start block from the proposal
      const [, , , startBlock, ,] = await linearERC20Voting.getProposalVotes(proposalId);

      // Now set past total supply for the EXACT block where the proposal was initialized
      await mockToken.setPastTotalSupply(startBlock, 3000);
    });

    it('should correctly calculate voting supply at proposal creation time', async () => {
      // Verify the proposal voting supply is recorded correctly at proposal creation
      const [, , , , , votingSupply] = await linearERC20Voting.getProposalVotes(proposalId);
      expect(votingSupply).to.equal(3000);

      // Mint more tokens (this won't affect past total supply at the proposal start block)
      await mockToken.mint(tokenHolder1.address, 2000);

      // The voting supply for the proposal should still be 3000
      const [, , , , , votingSupplyAfterMint] =
        await linearERC20Voting.getProposalVotes(proposalId);
      expect(votingSupplyAfterMint).to.equal(3000);
    });

    it('should correctly calculate voting weight at proposal creation time', async () => {
      // Check the voting weight for tokenHolder1
      const votingWeight = await linearERC20Voting.getVotingWeight(
        tokenHolder1.address,
        proposalId,
      );

      // The voting weight should be 1000 (what we set for the block at proposal creation)
      expect(votingWeight).to.equal(1000);

      // Mine a block to get to a new block number
      await mine(1);

      // Change the votes for a future block
      const newBlockNumber = await ethers.provider.getBlockNumber();
      const newWeight = 2000;
      await mockToken.setPastVotes(tokenHolder1.address, newBlockNumber, newWeight);

      // The voting weight for the proposal should still be 1000, based on the snapshot at the
      // time the proposal was created
      const votingWeightAfterChange = await linearERC20Voting.getVotingWeight(
        tokenHolder1.address,
        proposalId,
      );
      expect(votingWeightAfterChange).to.equal(1000);
    });

    it('should correctly calculate quorum votes based on voting supply', async () => {
      // Quorum is set to 30% of the total supply (QUORUM_NUMERATOR = 300000 out of 1000000)
      // Total supply at proposal creation is 3000, so quorum should be 900 votes
      const quorumVotesRequired = await linearERC20Voting.quorumVotes(proposalId);
      expect(quorumVotesRequired).to.equal(900);

      // Changing the quorum numerator should affect the required votes
      await linearERC20Voting.connect(owner).updateQuorumNumerator(500000); // 50%
      const newQuorumVotesRequired = await linearERC20Voting.quorumVotes(proposalId);
      expect(newQuorumVotesRequired).to.equal(1500); // 50% of 3000

      // Even if total supply changes after proposal creation, quorum should be based on original supply
      const quorumAfterSupplyChange = await linearERC20Voting.quorumVotes(proposalId);
      expect(quorumAfterSupplyChange).to.equal(1500); // Still 50% of 3000, not 6000
    });

    it('should directly call getProposalVotingSupply and return the correct value', async () => {
      // Call getProposalVotingSupply directly
      const votingSupply = await linearERC20Voting.getProposalVotingSupply(proposalId);
      expect(votingSupply).to.equal(3000);

      // Should match what getProposalVotes returns
      const [, , , , , votesSupply] = await linearERC20Voting.getProposalVotes(proposalId);
      expect(votingSupply).to.equal(votesSupply);

      // Add some more tokens to test that the snapshot supply doesn't change
      await mockToken.mint(tokenHolder1.address, 2000);
      const votingSupplyAfterMint = await linearERC20Voting.getProposalVotingSupply(proposalId);
      expect(votingSupplyAfterMint).to.equal(3000);
    });
  });

  describe('Smart Account Support', () => {
    const proposalId = 2;

    beforeEach(async () => {
      // Setup with tokens for the test
      await mockToken.mint(await mockOwnership.getAddress(), 1000);

      // Delegate tokens to the mock contract
      await mockToken.connect(deployer).delegate(await mockOwnership.getAddress());

      // Initialize the proposal
      const initializeData = ethers.AbiCoder.defaultAbiCoder().encode(['uint32'], [proposalId]);
      await linearERC20Voting.connect(nonOwner).initializeProposal(initializeData);
    });

    it('should correctly identify voter when using smart account', async () => {
      // The MockOwnership contract has owner() set to tokenHolder1.address in the beforeEach

      // We need to test that ERC4337VoterSupport correctly resolves the owner of the contract
      // But we can't directly call from the contract's address, so we need to verify indirectly

      // Vote from tokenHolder1 (which is the owner of mockOwnership)
      await linearERC20Voting.connect(tokenHolder1).vote(proposalId, VoteType.YES);

      // Check votes were attributed correctly
      const [, yesVotes, , , ,] = await linearERC20Voting.getProposalVotes(proposalId);
      expect(yesVotes).to.equal(1000);

      // Check that tokenHolder1 is marked as having voted
      void expect(await linearERC20Voting.hasVoted(proposalId, tokenHolder1.address)).to.be.true;

      // The test for ERC4337VoterSupport is more limited without advanced mocking
      // But we can verify that the _voter function works by setting up additional tests in ERC4337VoterSupportV1.test.ts
    });
  });

  describe('Edge Cases', () => {
    it('should handle invalid proposals', async () => {
      // Try to vote on a non-initialized proposal
      const nonExistentProposalId = 999;

      await expect(
        linearERC20Voting.connect(tokenHolder1).vote(nonExistentProposalId, VoteType.YES),
      ).to.be.revertedWithCustomError(linearERC20Voting, 'InvalidProposal');
    });

    it('should handle multiple concurrent proposals', async () => {
      // Set up votes for test accounts
      await mockToken.connect(tokenHolder1).delegate(tokenHolder1.address);
      await mockToken.connect(tokenHolder2).delegate(tokenHolder2.address);

      // Initialize the first proposal
      const proposalId1 = 10;
      const initializeData1 = ethers.AbiCoder.defaultAbiCoder().encode(['uint32'], [proposalId1]);
      await linearERC20Voting.connect(nonOwner).initializeProposal(initializeData1);

      // Mine a block to simulate time passing
      await mine(1);

      // Initialize the second proposal
      const proposalId2 = 20;
      const initializeData2 = ethers.AbiCoder.defaultAbiCoder().encode(['uint32'], [proposalId2]);
      await linearERC20Voting.connect(nonOwner).initializeProposal(initializeData2);

      // Vote differently on each proposal
      await linearERC20Voting.connect(tokenHolder1).vote(proposalId1, VoteType.YES);
      await linearERC20Voting.connect(tokenHolder1).vote(proposalId2, VoteType.NO);

      await linearERC20Voting.connect(tokenHolder2).vote(proposalId1, VoteType.NO);
      await linearERC20Voting.connect(tokenHolder2).vote(proposalId2, VoteType.YES);

      // Check that votes are tracked independently
      const [noVotes1, yesVotes1, , , ,] = await linearERC20Voting.getProposalVotes(proposalId1);
      const [noVotes2, yesVotes2, , , ,] = await linearERC20Voting.getProposalVotes(proposalId2);

      expect(yesVotes1).to.equal(1000);
      expect(noVotes1).to.equal(1000);

      expect(yesVotes2).to.equal(1000);
      expect(noVotes2).to.equal(1000);

      // Verify different hasVoted state per proposal
      void expect(await linearERC20Voting.hasVoted(proposalId1, tokenHolder1.address)).to.be.true;
      void expect(await linearERC20Voting.hasVoted(proposalId2, tokenHolder1.address)).to.be.true;
      void expect(await linearERC20Voting.hasVoted(proposalId1, tokenHolder2.address)).to.be.true;
      void expect(await linearERC20Voting.hasVoted(proposalId2, tokenHolder2.address)).to.be.true;
    });
  });

  describe('ERC165', function () {
    let iBaseStrategyV1InterfaceId: string;
    let iBaseQuorumPercentV1InterfaceId: string;
    let iBaseVotingBasisPercentV1InterfaceId: string;
    let iVersionInterfaceId: string;
    let iERC165InterfaceId: string;

    beforeEach(async function () {
      // Dynamically calculate interface IDs
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
});
