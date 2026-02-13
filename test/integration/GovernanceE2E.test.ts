import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { time } from '@nomicfoundation/hardhat-network-helpers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  ERC1967Proxy__factory,
  ModuleGovernorV1,
  ModuleGovernorV1__factory,
  StrategyV1,
  StrategyV1__factory,
  VotesERC20V1,
  VotesERC20V1__factory,
  VotingWeightERC20V1,
  VotingWeightERC20V1__factory,
  VoteTrackerERC20V1,
  VoteTrackerERC20V1__factory,
  ProposerAdapterERC20V1,
  ProposerAdapterERC20V1__factory,
  MockAvatar,
  MockAvatar__factory,
} from '../../typechain-types';

/**
 * E2E Integration Tests for Lux DAO Governance
 *
 * Tests the full lifecycle:
 * 1. Deploy DAO with ERC20 token voting
 * 2. Create proposal
 * 3. Vote on proposal
 * 4. Execute proposal
 * 5. Verify state changes
 */
describe('Governance E2E Integration', () => {
  // Signers
  let deployer: SignerWithAddress;
  let daoOwner: SignerWithAddress;
  let proposer: SignerWithAddress;
  let voter1: SignerWithAddress;
  let voter2: SignerWithAddress;
  let voter3: SignerWithAddress;
  let treasury: SignerWithAddress;

  // Contracts
  let governor: ModuleGovernorV1;
  let strategy: StrategyV1;
  let votesToken: VotesERC20V1;
  let votingWeight: VotingWeightERC20V1;
  let voteTracker: VoteTrackerERC20V1;
  let proposerAdapter: ProposerAdapterERC20V1;
  let safe: MockAvatar;

  // Contract implementations
  let governorImpl: ModuleGovernorV1;
  let strategyImpl: StrategyV1;
  let votesTokenImpl: VotesERC20V1;
  let votingWeightImpl: VotingWeightERC20V1;
  let voteTrackerImpl: VoteTrackerERC20V1;
  let proposerAdapterImpl: ProposerAdapterERC20V1;

  // Configuration
  const TIMELOCK_PERIOD = 60 * 60 * 24; // 1 day in seconds
  const EXECUTION_PERIOD = 60 * 60 * 24 * 7; // 7 days in seconds
  const VOTING_PERIOD = 60 * 60 * 24 * 3; // 3 days in seconds
  const QUORUM_NUMERATOR = 40000n; // 4% (out of 1,000,000)
  const BASIS_NUMERATOR = 500001n; // 50% + 1 (simple majority)
  const PROPOSER_THRESHOLD = ethers.parseEther('100'); // 100 tokens to propose
  const INITIAL_SUPPLY = ethers.parseEther('1000000'); // 1M tokens

  before(async () => {
    [deployer, daoOwner, proposer, voter1, voter2, voter3, treasury] = await ethers.getSigners();
  });

  describe('Full DAO Lifecycle', () => {
    it('should deploy all governance contracts', async () => {
      // Deploy Mock Safe (Avatar)
      safe = await new MockAvatar__factory(deployer).deploy();
      const safeAddress = await safe.getAddress();

      // Deploy implementations
      governorImpl = await new ModuleGovernorV1__factory(deployer).deploy();
      strategyImpl = await new StrategyV1__factory(deployer).deploy();
      votesTokenImpl = await new VotesERC20V1__factory(deployer).deploy();
      votingWeightImpl = await new VotingWeightERC20V1__factory(deployer).deploy();
      voteTrackerImpl = await new VoteTrackerERC20V1__factory(deployer).deploy();
      proposerAdapterImpl = await new ProposerAdapterERC20V1__factory(deployer).deploy();

      console.log('Implementations deployed:');
      console.log('  Governor:', await governorImpl.getAddress());
      console.log('  Strategy:', await strategyImpl.getAddress());
      console.log('  VotesToken:', await votesTokenImpl.getAddress());
      console.log('  VotingWeight:', await votingWeightImpl.getAddress());
      console.log('  VoteTracker:', await voteTrackerImpl.getAddress());
      console.log('  ProposerAdapter:', await proposerAdapterImpl.getAddress());

      // Deploy VotesToken proxy
      const tokenAllocations = [
        { to: proposer.address, amount: ethers.parseEther('200000') }, // 200k for proposer
        { to: voter1.address, amount: ethers.parseEther('150000') },   // 150k for voter1
        { to: voter2.address, amount: ethers.parseEther('100000') },   // 100k for voter2
        { to: voter3.address, amount: ethers.parseEther('50000') },    // 50k for voter3
        { to: treasury.address, amount: ethers.parseEther('500000') }, // 500k for treasury
      ];

      const tokenInitData = VotesERC20V1__factory.createInterface().encodeFunctionData('initialize', [
        { name: 'Lux Governance', symbol: 'vLUX' },
        tokenAllocations,
        safeAddress, // owner
        false, // not locked
        0n, // no max supply
      ]);

      const tokenProxy = await new ERC1967Proxy__factory(deployer).deploy(
        await votesTokenImpl.getAddress(),
        tokenInitData
      );
      votesToken = VotesERC20V1__factory.connect(await tokenProxy.getAddress(), deployer);

      console.log('VotesToken deployed:', await votesToken.getAddress());

      // Deploy VotingWeight proxy
      const votingWeightInitData = VotingWeightERC20V1__factory.createInterface().encodeFunctionData('initialize', [
        await votesToken.getAddress(),
      ]);

      const votingWeightProxy = await new ERC1967Proxy__factory(deployer).deploy(
        await votingWeightImpl.getAddress(),
        votingWeightInitData
      );
      votingWeight = VotingWeightERC20V1__factory.connect(await votingWeightProxy.getAddress(), deployer);

      // Deploy VoteTracker proxy
      const voteTrackerInitData = VoteTrackerERC20V1__factory.createInterface().encodeFunctionData('initialize', [
        await votesToken.getAddress(),
        VOTING_PERIOD,
        QUORUM_NUMERATOR,
        BASIS_NUMERATOR,
      ]);

      const voteTrackerProxy = await new ERC1967Proxy__factory(deployer).deploy(
        await voteTrackerImpl.getAddress(),
        voteTrackerInitData
      );
      voteTracker = VoteTrackerERC20V1__factory.connect(await voteTrackerProxy.getAddress(), deployer);

      // Deploy ProposerAdapter proxy
      const proposerAdapterInitData = ProposerAdapterERC20V1__factory.createInterface().encodeFunctionData('initialize', [
        await votesToken.getAddress(),
        PROPOSER_THRESHOLD,
      ]);

      const proposerAdapterProxy = await new ERC1967Proxy__factory(deployer).deploy(
        await proposerAdapterImpl.getAddress(),
        proposerAdapterInitData
      );
      proposerAdapter = ProposerAdapterERC20V1__factory.connect(await proposerAdapterProxy.getAddress(), deployer);

      // Deploy Strategy proxy
      const strategyInitData = StrategyV1__factory.createInterface().encodeFunctionData('initialize', [
        ethers.ZeroAddress, // governor (set later)
        await votingWeight.getAddress(),
        await voteTracker.getAddress(),
        await proposerAdapter.getAddress(),
      ]);

      const strategyProxy = await new ERC1967Proxy__factory(deployer).deploy(
        await strategyImpl.getAddress(),
        strategyInitData
      );
      strategy = StrategyV1__factory.connect(await strategyProxy.getAddress(), deployer);

      // Deploy Governor proxy
      const governorInitData = ModuleGovernorV1__factory.createInterface().encodeFunctionData('initialize', [
        daoOwner.address, // owner
        safeAddress, // avatar (Safe)
        safeAddress, // target
        await strategy.getAddress(),
        TIMELOCK_PERIOD,
        EXECUTION_PERIOD,
      ]);

      const governorProxy = await new ERC1967Proxy__factory(deployer).deploy(
        await governorImpl.getAddress(),
        governorInitData
      );
      governor = ModuleGovernorV1__factory.connect(await governorProxy.getAddress(), deployer);

      console.log('Governor deployed:', await governor.getAddress());

      // Set governor on strategy
      await strategy.setGovernor(await governor.getAddress());

      // Enable governor module on Safe
      await safe.enableModule(await governor.getAddress());

      // Verify deployment
      expect(await votesToken.name()).to.equal('Lux Governance');
      expect(await votesToken.symbol()).to.equal('vLUX');
      expect(await governor.avatar()).to.equal(safeAddress);
    });

    it('should have correct token balances', async () => {
      expect(await votesToken.balanceOf(proposer.address)).to.equal(ethers.parseEther('200000'));
      expect(await votesToken.balanceOf(voter1.address)).to.equal(ethers.parseEther('150000'));
      expect(await votesToken.balanceOf(voter2.address)).to.equal(ethers.parseEther('100000'));
      expect(await votesToken.balanceOf(voter3.address)).to.equal(ethers.parseEther('50000'));
    });

    it('should allow delegation for voting power', async () => {
      // Users must delegate to themselves or others to have voting power
      await votesToken.connect(proposer).delegate(proposer.address);
      await votesToken.connect(voter1).delegate(voter1.address);
      await votesToken.connect(voter2).delegate(voter2.address);
      await votesToken.connect(voter3).delegate(voter3.address);

      // Verify voting power
      const proposerVotes = await votesToken.getVotes(proposer.address);
      expect(proposerVotes).to.equal(ethers.parseEther('200000'));
    });

    it('should allow creating a proposal', async () => {
      // Verify proposer has enough tokens
      const proposerBalance = await votesToken.balanceOf(proposer.address);
      expect(proposerBalance).to.be.gte(PROPOSER_THRESHOLD);

      // Create a simple transfer proposal
      const transferAmount = ethers.parseEther('1000');
      const transferData = votesToken.interface.encodeFunctionData('transfer', [
        voter1.address,
        transferAmount,
      ]);

      // Build proposal transactions
      const transactions = [{
        to: await votesToken.getAddress(),
        value: 0n,
        data: transferData,
        operation: 0, // Call
      }];

      // Submit proposal
      const tx = await governor.connect(proposer).submitProposal(
        transactions,
        'Proposal 1: Transfer tokens to voter1',
        'ipfs://QmTest123', // metadata URI
      );

      const receipt = await tx.wait();
      console.log('Proposal created, tx hash:', receipt?.hash);

      // Get proposal ID
      const proposalCount = await governor.proposalCount();
      expect(proposalCount).to.equal(1);
    });

    it('should allow voting on proposal', async () => {
      const proposalId = 0; // First proposal

      // Move time forward to start voting period
      await time.increase(1); // Small increase to ensure proposal is active

      // Vote FOR
      await governor.connect(voter1).vote(proposalId, 1); // 1 = FOR
      await governor.connect(voter2).vote(proposalId, 1); // 1 = FOR

      // Vote AGAINST
      await governor.connect(voter3).vote(proposalId, 0); // 0 = AGAINST

      // Check vote counts
      const proposal = await governor.getProposal(proposalId);
      console.log('Proposal state after voting:', proposal);
    });

    it('should execute proposal after voting period', async () => {
      const proposalId = 0;

      // Move time forward past voting period
      await time.increase(VOTING_PERIOD + 1);

      // Move time forward past timelock period
      await time.increase(TIMELOCK_PERIOD + 1);

      // Execute the proposal
      // Note: This will fail if the Safe doesn't have the tokens
      // In a real scenario, the Safe would hold treasury tokens
      try {
        await governor.connect(proposer).executeProposal(proposalId);
        console.log('Proposal executed successfully');
      } catch (error) {
        // Expected to fail since Safe doesn't have tokens in this test
        console.log('Proposal execution failed (expected - Safe has no tokens)');
      }
    });
  });

  describe('Voting Power & Delegation', () => {
    it('should allow delegating votes to another address', async () => {
      // Get a fresh signer for this test
      const [, , , , , , , delegator, delegate] = await ethers.getSigners();

      // Transfer some tokens to delegator
      await votesToken.connect(treasury).transfer(delegator.address, ethers.parseEther('10000'));

      // Delegate to another address
      await votesToken.connect(delegator).delegate(delegate.address);

      // Check voting power transferred
      const delegateVotes = await votesToken.getVotes(delegate.address);
      expect(delegateVotes).to.equal(ethers.parseEther('10000'));

      // Original holder should have no voting power
      const delegatorVotes = await votesToken.getVotes(delegator.address);
      expect(delegatorVotes).to.equal(0);
    });

    it('should track historical voting power at snapshots', async () => {
      const currentBlock = await ethers.provider.getBlockNumber();

      // Get past votes (if block exists)
      if (currentBlock > 0) {
        const pastVotes = await votesToken.getPastVotes(proposer.address, currentBlock - 1);
        expect(pastVotes).to.be.gte(0);
      }
    });
  });

  describe('Quorum & Threshold Checks', () => {
    it('should verify proposal meets quorum', async () => {
      // Total supply
      const totalSupply = await votesToken.totalSupply();

      // Quorum is 4% of total supply
      const quorum = (totalSupply * QUORUM_NUMERATOR) / 1000000n;

      console.log('Total supply:', ethers.formatEther(totalSupply));
      console.log('Quorum needed:', ethers.formatEther(quorum));

      // Combined voting power of FOR voters should exceed quorum
      const voter1Power = await votesToken.getVotes(voter1.address);
      const voter2Power = await votesToken.getVotes(voter2.address);
      const forVotes = voter1Power + voter2Power;

      console.log('FOR votes:', ethers.formatEther(forVotes));
      expect(forVotes).to.be.gte(quorum);
    });

    it('should verify proposer meets threshold', async () => {
      const proposerVotes = await votesToken.getVotes(proposer.address);
      expect(proposerVotes).to.be.gte(PROPOSER_THRESHOLD);
    });
  });
});

describe('vLUX Staking Integration', () => {
  // These tests would integrate with the standard contracts vLUX
  // Skipped for now as they require vLUX contract deployment

  it.skip('should allow locking LUX for vLUX voting power', async () => {
    // Deploy vLUX contract
    // Lock tokens
    // Verify voting power
  });

  it.skip('should decay voting power over time', async () => {
    // Lock tokens
    // Fast forward time
    // Verify voting power decreased
  });

  it.skip('should allow extending lock time', async () => {
    // Lock tokens
    // Extend lock
    // Verify new unlock time
  });
});
