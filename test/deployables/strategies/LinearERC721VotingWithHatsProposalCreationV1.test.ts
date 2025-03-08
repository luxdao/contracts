import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  LinearERC721VotingWithHatsProposalCreationV1,
  LinearERC721VotingWithHatsProposalCreationV1__factory,
  MockERC721,
  MockERC721__factory,
  MockHats,
  MockHats__factory,
} from '../../../typechain-types';
import { getModuleProxyFactory } from '../../helpers/globals.test';
import { calculateProxyAddress } from '../../helpers/utils';

/**
 * This test file only covers the specific functionality of LinearERC721VotingWithHatsProposalCreationV1,
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

describe('LinearERC721VotingWithHatsProposalCreationV1', () => {
  // Signers
  let deployer: SignerWithAddress;
  let owner: SignerWithAddress;
  let nonOwner: SignerWithAddress;
  let azoriusAddress: string;
  let tokenHolder1: SignerWithAddress;
  let hatWearer: SignerWithAddress;
  let nonHatWearer: SignerWithAddress;

  // Contracts
  let linearERC721VotingWithHatsProposalCreationMastercopy: LinearERC721VotingWithHatsProposalCreationV1;
  let linearERC721VotingWithHatsProposalCreation: LinearERC721VotingWithHatsProposalCreationV1;
  let mockNFT1: MockERC721;
  let mockNFT2: MockERC721;
  let mockHats: MockHats;

  // Constants
  const VOTING_PERIOD = 100; // blocks
  const QUORUM_THRESHOLD = 5; // 5 votes required for quorum
  const BASIS_NUMERATOR = 500000; // 50% of 1000000

  // Create hat IDs for testing
  let topHatId: bigint;
  let proposerHatId1: bigint;
  let proposerHatId2: bigint;
  let nonProposerHatId: bigint;

  async function deployLinearERC721VotingWithHatsProposalCreation(
    strategyOwner: SignerWithAddress,
    nftAddresses: string[],
    nftWeights: number[],
    azoriusAddr: string,
    hatsContract: MockHats,
    initialWhitelistedHats: bigint[],
  ): Promise<LinearERC721VotingWithHatsProposalCreationV1> {
    const salt = ethers.hexlify(ethers.randomBytes(32));
    const initializeParams = ethers.AbiCoder.defaultAbiCoder().encode(
      [
        'address',
        'address[]',
        'uint256[]',
        'address',
        'uint32',
        'uint256',
        'uint256',
        'address',
        'uint256[]',
      ],
      [
        strategyOwner.address,
        nftAddresses,
        nftWeights,
        azoriusAddr,
        VOTING_PERIOD,
        QUORUM_THRESHOLD,
        BASIS_NUMERATOR,
        await hatsContract.getAddress(),
        initialWhitelistedHats,
      ],
    );

    const setupCalldata =
      linearERC721VotingWithHatsProposalCreationMastercopy.interface.encodeFunctionData('setUp', [
        initializeParams,
      ]);

    const moduleProxyFactory = getModuleProxyFactory();

    await moduleProxyFactory.deployModule(
      await linearERC721VotingWithHatsProposalCreationMastercopy.getAddress(),
      setupCalldata,
      salt,
    );

    const predictedAddress = await calculateProxyAddress(
      moduleProxyFactory,
      await linearERC721VotingWithHatsProposalCreationMastercopy.getAddress(),
      setupCalldata,
      salt,
    );

    return LinearERC721VotingWithHatsProposalCreationV1__factory.connect(
      predictedAddress,
      strategyOwner,
    );
  }

  beforeEach(async () => {
    [deployer, owner, nonOwner, tokenHolder1, hatWearer, nonHatWearer] = await ethers.getSigners();

    // Use nonOwner address as a mock azorius address for testing
    azoriusAddress = await nonOwner.getAddress();

    // Deploy MockERC721 tokens
    mockNFT1 = await new MockERC721__factory(deployer).deploy();
    mockNFT2 = await new MockERC721__factory(deployer).deploy();

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

    // Deploy LinearERC721VotingWithHatsProposalCreation mastercopy
    linearERC721VotingWithHatsProposalCreationMastercopy =
      await new LinearERC721VotingWithHatsProposalCreationV1__factory(deployer).deploy();

    // Deploy LinearERC721VotingWithHatsProposalCreation strategy with proposerHatId1 and proposerHatId2 whitelisted
    // Create an array of NFT addresses
    const nftAddresses = [await mockNFT1.getAddress(), await mockNFT2.getAddress()];

    // Each NFT has weight 1 (linear voting)
    const nftWeights = [1, 1];

    linearERC721VotingWithHatsProposalCreation =
      await deployLinearERC721VotingWithHatsProposalCreation(
        owner,
        nftAddresses,
        nftWeights,
        azoriusAddress,
        mockHats,
        [proposerHatId1, proposerHatId2],
      );
  });

  describe('Contract-Specific Functionality', () => {
    describe('setUp', () => {
      it('should initialize with correct parameters from both parent contracts', async () => {
        // Check LinearERC721VotingV1 parameters
        const ownerAddress = await linearERC721VotingWithHatsProposalCreation.owner();
        expect(ownerAddress).to.equal(owner.address);

        const votingPeriod = await linearERC721VotingWithHatsProposalCreation.votingPeriod();
        expect(votingPeriod).to.equal(VOTING_PERIOD);

        const quorum = await linearERC721VotingWithHatsProposalCreation.quorumThreshold();
        expect(quorum).to.equal(QUORUM_THRESHOLD);

        // proposerThreshold should be 0 since we're using hats
        const propThreshold = await linearERC721VotingWithHatsProposalCreation.proposerThreshold();
        expect(propThreshold).to.equal(0);

        // Check token addresses
        const addresses = await linearERC721VotingWithHatsProposalCreation.getAllTokenAddresses();
        expect(addresses.length).to.equal(2);
        expect(addresses[0]).to.equal(await mockNFT1.getAddress());
        expect(addresses[1]).to.equal(await mockNFT2.getAddress());

        // Check token weights
        const weight1 = await linearERC721VotingWithHatsProposalCreation.tokenWeights(
          await mockNFT1.getAddress(),
        );
        expect(weight1).to.equal(1);

        const weight2 = await linearERC721VotingWithHatsProposalCreation.tokenWeights(
          await mockNFT2.getAddress(),
        );
        expect(weight2).to.equal(1);

        // Check HatsProposalCreationWhitelistV1 parameters
        const hatsContract = await linearERC721VotingWithHatsProposalCreation.hatsContract();
        expect(hatsContract).to.equal(await mockHats.getAddress());

        // Check whitelisted hats
        const whitelistedHats =
          await linearERC721VotingWithHatsProposalCreation.getWhitelistedHatIds();
        expect(whitelistedHats.length).to.equal(2);
        expect(whitelistedHats[0]).to.equal(proposerHatId1);
        expect(whitelistedHats[1]).to.equal(proposerHatId2);
      });

      it('should not allow reinitialization', async () => {
        const nftAddresses = [await mockNFT1.getAddress(), await mockNFT2.getAddress()];
        const nftWeights = [1, 1];

        const initializeParams = ethers.AbiCoder.defaultAbiCoder().encode(
          [
            'address',
            'address[]',
            'uint256[]',
            'address',
            'uint32',
            'uint256',
            'uint256',
            'address',
            'uint256[]',
          ],
          [
            owner.address,
            nftAddresses,
            nftWeights,
            azoriusAddress,
            VOTING_PERIOD,
            QUORUM_THRESHOLD,
            BASIS_NUMERATOR,
            await mockHats.getAddress(),
            [proposerHatId1, proposerHatId2],
          ],
        );

        const setupCalldata =
          linearERC721VotingWithHatsProposalCreationMastercopy.interface.encodeFunctionData(
            'setUp',
            [initializeParams],
          );

        await expect(linearERC721VotingWithHatsProposalCreation.setUp(setupCalldata)).to.be
          .reverted;
      });
    });

    describe('isProposer override', () => {
      it('should use Hats implementation to determine proposers', async () => {
        // hatWearer has proposerHatId1, which is whitelisted
        const isHatWearerProposer = await linearERC721VotingWithHatsProposalCreation.isProposer(
          hatWearer.address,
        );
        void expect(isHatWearerProposer).to.be.true;

        // nonHatWearer has nonProposerHatId, which is not whitelisted
        const isNonHatWearerProposer = await linearERC721VotingWithHatsProposalCreation.isProposer(
          nonHatWearer.address,
        );
        void expect(isNonHatWearerProposer).to.be.false;

        // tokenHolder1 has no hats at all, but has tokens
        const isTokenHolder1Proposer = await linearERC721VotingWithHatsProposalCreation.isProposer(
          tokenHolder1.address,
        );
        void expect(isTokenHolder1Proposer).to.be.false;

        // Adding nonProposerHatId to the whitelist
        await linearERC721VotingWithHatsProposalCreation
          .connect(owner)
          .whitelistHat(nonProposerHatId);

        // Now nonHatWearer should be a proposer
        const isNonHatWearerProposerAfterWhitelist =
          await linearERC721VotingWithHatsProposalCreation.isProposer(nonHatWearer.address);
        void expect(isNonHatWearerProposerAfterWhitelist).to.be.true;
      });
    });

    describe('getVersion override', () => {
      it('should return correct version', async () => {
        const version = await linearERC721VotingWithHatsProposalCreation.getVersion();
        expect(version).to.equal(1);
      });
    });
  });
});
