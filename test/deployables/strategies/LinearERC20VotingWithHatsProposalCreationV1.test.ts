import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  LinearERC20VotingWithHatsProposalCreationV1,
  LinearERC20VotingWithHatsProposalCreationV1__factory,
  MockERC20Votes,
  MockERC20Votes__factory,
  MockHats,
  MockHats__factory,
} from '../../../typechain-types';
import { getModuleProxyFactory } from '../../global/GlobalSafeDeployments.test';
import { calculateProxyAddress } from '../../helpers';

/**
 * This test file only covers the specific functionality of LinearERC20VotingWithHatsProposalCreationV1,
 * focusing on the contract-specific code, not functionality inherited from parent contracts.
 *
 * Specifically, we test:
 * 1. The setUp function (which combines parameters from both parent contracts)
 * 2. The isProposer override (which uses the Hats implementation)
 * 3. The getVersion override
 */

// Helper function to convert a top hat ID to a hat ID
function topHatIdToHatId(topHatId: bigint | number): bigint {
  return BigInt(topHatId) << 224n;
}

describe('LinearERC20VotingWithHatsProposalCreationV1', () => {
  // Signers
  let deployer: SignerWithAddress;
  let owner: SignerWithAddress;
  let nonOwner: SignerWithAddress;
  let azoriusAddress: string;
  let tokenHolder1: SignerWithAddress;
  let hatWearer: SignerWithAddress;
  let nonHatWearer: SignerWithAddress;

  // Contracts
  let linearERC20VotingWithHatsProposalCreationMastercopy: LinearERC20VotingWithHatsProposalCreationV1;
  let linearERC20VotingWithHatsProposalCreation: LinearERC20VotingWithHatsProposalCreationV1;
  let mockToken: MockERC20Votes;
  let mockHats: MockHats;

  // Constants
  const VOTING_PERIOD = 100; // blocks
  const QUORUM_NUMERATOR = 300000; // 30% of 1000000
  const BASIS_NUMERATOR = 500000; // 50% of 1000000

  // Create hat IDs for testing
  let topHatId: bigint;
  let proposerHatId1: bigint;
  let proposerHatId2: bigint;
  let nonProposerHatId: bigint;

  async function deployLinearERC20VotingWithHatsProposalCreation(
    strategyOwner: SignerWithAddress,
    governanceToken: MockERC20Votes,
    azoriusAddr: string,
    hatsContract: MockHats,
    initialWhitelistedHats: bigint[],
  ): Promise<LinearERC20VotingWithHatsProposalCreationV1> {
    const salt = ethers.hexlify(ethers.randomBytes(32));
    const initializeParams = ethers.AbiCoder.defaultAbiCoder().encode(
      ['address', 'address', 'address', 'uint32', 'uint256', 'uint256', 'address', 'uint256[]'],
      [
        strategyOwner.address,
        await governanceToken.getAddress(),
        azoriusAddr,
        VOTING_PERIOD,
        QUORUM_NUMERATOR,
        BASIS_NUMERATOR,
        await hatsContract.getAddress(),
        initialWhitelistedHats,
      ],
    );

    const setupCalldata =
      linearERC20VotingWithHatsProposalCreationMastercopy.interface.encodeFunctionData('setUp', [
        initializeParams,
      ]);

    const moduleProxyFactory = getModuleProxyFactory();

    await moduleProxyFactory.deployModule(
      await linearERC20VotingWithHatsProposalCreationMastercopy.getAddress(),
      setupCalldata,
      salt,
    );

    const predictedAddress = await calculateProxyAddress(
      moduleProxyFactory,
      await linearERC20VotingWithHatsProposalCreationMastercopy.getAddress(),
      setupCalldata,
      salt,
    );

    return LinearERC20VotingWithHatsProposalCreationV1__factory.connect(
      predictedAddress,
      strategyOwner,
    );
  }

  beforeEach(async () => {
    [deployer, owner, nonOwner, tokenHolder1, hatWearer, nonHatWearer] = await ethers.getSigners();

    // Use nonOwner address as a mock azorius address for testing
    azoriusAddress = await nonOwner.getAddress();

    // Deploy MockERC20Votes token
    mockToken = await new MockERC20Votes__factory(deployer).deploy();

    // Mint tokens to token holders
    await mockToken.mint(tokenHolder1.address, 1000);
    await mockToken.mint(hatWearer.address, 1000);
    await mockToken.mint(nonHatWearer.address, 1000);

    // Set up delegates
    await mockToken.connect(tokenHolder1).delegate(tokenHolder1.address);
    await mockToken.connect(hatWearer).delegate(hatWearer.address);
    await mockToken.connect(nonHatWearer).delegate(nonHatWearer.address);

    // Deploy MockHats
    mockHats = await new MockHats__factory(deployer).deploy();

    // Create hats for testing - using the correct approach
    // Mint a top hat
    topHatId = topHatIdToHatId((await mockHats.lastTopHatId()) + 1n);
    await mockHats.mintTopHat(deployer.address, '', '');

    // Create proposer hats (these will be whitelisted for proposing)
    proposerHatId1 = await mockHats.getNextId(topHatId);
    await mockHats.createHat(
      topHatId,
      'Proposer Hat 1',
      1,
      deployer.address,
      deployer.address,
      true,
      '',
    );

    proposerHatId2 = await mockHats.getNextId(topHatId);
    await mockHats.createHat(
      topHatId,
      'Proposer Hat 2',
      1,
      deployer.address,
      deployer.address,
      true,
      '',
    );

    // Create a non-proposer hat (will not be whitelisted)
    nonProposerHatId = await mockHats.getNextId(topHatId);
    await mockHats.createHat(
      topHatId,
      'Non-Proposer Hat',
      1,
      deployer.address,
      deployer.address,
      true,
      '',
    );

    // Mint proposer hats to hatWearer
    await mockHats.mintHat(proposerHatId1, hatWearer.address);

    // Mint non-proposer hats to nonHatWearer
    await mockHats.mintHat(nonProposerHatId, nonHatWearer.address);

    // Deploy LinearERC20VotingWithHatsProposalCreation mastercopy
    linearERC20VotingWithHatsProposalCreationMastercopy =
      await new LinearERC20VotingWithHatsProposalCreationV1__factory(deployer).deploy();

    // Deploy LinearERC20VotingWithHatsProposalCreation strategy with proposerHatId1 and proposerHatId2 whitelisted
    linearERC20VotingWithHatsProposalCreation =
      await deployLinearERC20VotingWithHatsProposalCreation(
        owner,
        mockToken,
        azoriusAddress,
        mockHats,
        [proposerHatId1, proposerHatId2],
      );
  });

  describe('Contract-Specific Functionality', () => {
    describe('setUp', () => {
      it('should initialize with correct parameters from both parent contracts', async () => {
        // Check LinearERC20VotingV1 parameters
        const ownerAddress = await linearERC20VotingWithHatsProposalCreation.owner();
        expect(ownerAddress).to.equal(owner.address);

        const tokenAddress = await linearERC20VotingWithHatsProposalCreation.governanceToken();
        expect(tokenAddress).to.equal(await mockToken.getAddress());

        const votingPeriod = await linearERC20VotingWithHatsProposalCreation.votingPeriod();
        expect(votingPeriod).to.equal(VOTING_PERIOD);

        // requiredProposerWeight should be 0 since we're using hats
        const weight = await linearERC20VotingWithHatsProposalCreation.requiredProposerWeight();
        expect(weight).to.equal(0);

        // Check HatsProposalCreationWhitelistV1 parameters
        const hatsContract = await linearERC20VotingWithHatsProposalCreation.hatsContract();
        expect(hatsContract).to.equal(await mockHats.getAddress());

        // Check whitelisted hats
        const whitelistedHats =
          await linearERC20VotingWithHatsProposalCreation.getWhitelistedHatIds();
        expect(whitelistedHats.length).to.equal(2);
        expect(whitelistedHats[0]).to.equal(proposerHatId1);
        expect(whitelistedHats[1]).to.equal(proposerHatId2);
      });

      it('should not allow reinitialization', async () => {
        const initializeParams = ethers.AbiCoder.defaultAbiCoder().encode(
          ['address', 'address', 'address', 'uint32', 'uint256', 'uint256', 'address', 'uint256[]'],
          [
            owner.address,
            await mockToken.getAddress(),
            azoriusAddress,
            VOTING_PERIOD,
            QUORUM_NUMERATOR,
            BASIS_NUMERATOR,
            await mockHats.getAddress(),
            [proposerHatId1, proposerHatId2],
          ],
        );

        const setupCalldata =
          linearERC20VotingWithHatsProposalCreationMastercopy.interface.encodeFunctionData(
            'setUp',
            [initializeParams],
          );

        await expect(linearERC20VotingWithHatsProposalCreation.setUp(setupCalldata)).to.be.reverted;
      });
    });

    describe('isProposer override', () => {
      it('should use Hats implementation to determine proposers', async () => {
        // hatWearer has proposerHatId1, which is whitelisted
        const isHatWearerProposer = await linearERC20VotingWithHatsProposalCreation.isProposer(
          hatWearer.address,
        );
        void expect(isHatWearerProposer).to.be.true;

        // nonHatWearer has nonProposerHatId, which is not whitelisted
        const isNonHatWearerProposer = await linearERC20VotingWithHatsProposalCreation.isProposer(
          nonHatWearer.address,
        );
        void expect(isNonHatWearerProposer).to.be.false;

        // tokenHolder1 has no hats at all, but has tokens
        const isTokenHolder1Proposer = await linearERC20VotingWithHatsProposalCreation.isProposer(
          tokenHolder1.address,
        );
        void expect(isTokenHolder1Proposer).to.be.false;

        // Adding nonProposerHatId to the whitelist
        await linearERC20VotingWithHatsProposalCreation
          .connect(owner)
          .whitelistHat(nonProposerHatId);

        // Now nonHatWearer should be a proposer
        const isNonHatWearerProposerAfterWhitelist =
          await linearERC20VotingWithHatsProposalCreation.isProposer(nonHatWearer.address);
        void expect(isNonHatWearerProposerAfterWhitelist).to.be.true;
      });
    });

    describe('getVersion override', () => {
      it('should return correct version', async () => {
        const version = await linearERC20VotingWithHatsProposalCreation.getVersion();
        expect(version).to.equal(1);
      });
    });
  });
});
