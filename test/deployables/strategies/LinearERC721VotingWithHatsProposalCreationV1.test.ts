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
import { runHatsProposerTests } from '../../helpers/hatsProposerTests';
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

  // Hat IDs - we can use any arbitrary values
  const proposerHatId1 = 1n;
  const proposerHatId2 = 2n;
  const nonProposerHatId = 3n;

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

    // Deploy MockERC721 NFTs
    mockNFT1 = await new MockERC721__factory(deployer).deploy();
    mockNFT2 = await new MockERC721__factory(deployer).deploy();

    // Deploy MockHats
    mockHats = await new MockHats__factory(deployer).deploy();

    // Deploy LinearERC721VotingWithHatsProposalCreation mastercopy
    linearERC721VotingWithHatsProposalCreationMastercopy =
      await new LinearERC721VotingWithHatsProposalCreationV1__factory(deployer).deploy();

    // Deploy LinearERC721VotingWithHatsProposalCreation strategy with proposerHatId1 and proposerHatId2 whitelisted
    // Create an array of NFT addresses
    const nftAddresses = [await mockNFT1.getAddress(), await mockNFT2.getAddress()];
    const nftWeights = [1, 2]; // Each NFT2 token counts as 2 votes

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

        const quorumThreshold = await linearERC721VotingWithHatsProposalCreation.quorumThreshold();
        expect(quorumThreshold).to.equal(QUORUM_THRESHOLD);

        // Check vote token configuration
        const nftAddresses = [await mockNFT1.getAddress(), await mockNFT2.getAddress()];
        for (let i = 0; i < nftAddresses.length; i++) {
          const weight = await linearERC721VotingWithHatsProposalCreation.tokenWeights(
            nftAddresses[i],
          );
          expect(weight).to.equal(i === 0 ? 1 : 2); // NFT1 weight = 1, NFT2 weight = 2
        }

        // proposerThreshold should be 0 since we're using hats
        const threshold = await linearERC721VotingWithHatsProposalCreation.proposerThreshold();
        expect(threshold).to.equal(0);

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

        await expect(linearERC721VotingWithHatsProposalCreation.setUp(initializeParams)).to.be
          .reverted;
      });
    });

    // Use the shared test utility for isProposer tests
    runHatsProposerTests({
      getMockHats: () => mockHats,
      getContract: () => linearERC721VotingWithHatsProposalCreation,
      hatWearer: () => hatWearer,
      nonHatWearer: () => nonHatWearer,
      tokenHolder: () => tokenHolder1,
      owner: () => owner,
      proposerHatId: proposerHatId1,
      nonProposerHatId,
    });

    describe('getVersion override', () => {
      it('should return correct version', async () => {
        const version = await linearERC721VotingWithHatsProposalCreation.getVersion();
        expect(version).to.equal(1);
      });
    });
  });
});
