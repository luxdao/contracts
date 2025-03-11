import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  ConcreteHatsProposalCreationWhitelistV1,
  ConcreteHatsProposalCreationWhitelistV1__factory,
  IERC165__factory,
  IHatsProposalCreationWhitelistV1__factory,
  MockHats,
  MockHats__factory,
} from '../../../typechain-types';
import { runHatsProposerTests } from '../../helpers/hatsProposerTests';
import { calculateInterfaceId } from '../../helpers/utils';

describe('HatsProposalCreationWhitelistV1', () => {
  // Signers
  let deployer: SignerWithAddress;
  let owner: SignerWithAddress;
  let nonOwner: SignerWithAddress;
  let hatWearer: SignerWithAddress;
  let nonHatWearer: SignerWithAddress;

  // Contracts
  let concreteHatsProposalCreationWhitelist: ConcreteHatsProposalCreationWhitelistV1;
  let mockHats: MockHats;

  // Hat IDs - we can use any arbitrary values now
  const proposerHatId1 = 1n;
  const proposerHatId2 = 2n;
  const nonProposerHatId = 3n;

  beforeEach(async () => {
    [deployer, owner, nonOwner, hatWearer, nonHatWearer] = await ethers.getSigners();

    // Deploy the ultra-minimal MockHats contract
    mockHats = await new MockHats__factory(deployer).deploy();

    // Set up initial hat wearing status - this is all we need!
    await mockHats.setWearerStatus(hatWearer.address, proposerHatId1, true);
    await mockHats.setWearerStatus(nonHatWearer.address, nonProposerHatId, true);

    // Deploy the ConcreteHatsProposalCreationWhitelist contract
    concreteHatsProposalCreationWhitelist =
      await new ConcreteHatsProposalCreationWhitelistV1__factory(deployer).deploy();

    // Initialize the contract
    const initializeParams = ethers.AbiCoder.defaultAbiCoder().encode(
      ['address', 'uint256[]'],
      [await mockHats.getAddress(), [proposerHatId1, proposerHatId2]],
    );

    await concreteHatsProposalCreationWhitelist.setUp(initializeParams);

    // Transfer ownership to the owner account
    await concreteHatsProposalCreationWhitelist.transferOwnership(owner.address);
  });

  describe('Initialization', () => {
    it('should initialize with correct hats contract address', async () => {
      expect(await concreteHatsProposalCreationWhitelist.hatsContract()).to.equal(
        await mockHats.getAddress(),
      );
    });

    it('should initialize with correct whitelisted hats', async () => {
      const whitelistedHats = await concreteHatsProposalCreationWhitelist.getWhitelistedHatIds();
      expect(whitelistedHats.length).to.equal(2);
      expect(whitelistedHats[0]).to.equal(proposerHatId1);
      expect(whitelistedHats[1]).to.equal(proposerHatId2);
    });

    it('should initialize with correct owner', async () => {
      expect(await concreteHatsProposalCreationWhitelist.owner()).to.equal(owner.address);
    });

    it('should not allow initialization with no whitelisted hats', async () => {
      const mockWhitelist = await new ConcreteHatsProposalCreationWhitelistV1__factory(
        deployer,
      ).deploy();

      const emptyWhitelistedHats: bigint[] = [];
      const initializeParams = ethers.AbiCoder.defaultAbiCoder().encode(
        ['address', 'uint256[]'],
        [await mockHats.getAddress(), emptyWhitelistedHats],
      );

      await expect(mockWhitelist.setUp(initializeParams)).to.be.revertedWithCustomError(
        mockWhitelist,
        'NoHatsWhitelisted',
      );
    });

    it('should not allow initialization with invalid hats contract', async () => {
      const mockWhitelist = await new ConcreteHatsProposalCreationWhitelistV1__factory(
        deployer,
      ).deploy();

      const initializeParams = ethers.AbiCoder.defaultAbiCoder().encode(
        ['address', 'uint256[]'],
        [ethers.ZeroAddress, [proposerHatId1]],
      );

      await expect(mockWhitelist.setUp(initializeParams)).to.be.revertedWithCustomError(
        mockWhitelist,
        'InvalidHatsContract',
      );
    });
  });

  describe('whitelistHat', () => {
    it('should allow owner to whitelist a new hat', async () => {
      await concreteHatsProposalCreationWhitelist.connect(owner).whitelistHat(nonProposerHatId);

      const whitelistedHats = await concreteHatsProposalCreationWhitelist.getWhitelistedHatIds();
      expect(whitelistedHats.length).to.equal(3);
      expect(whitelistedHats[2]).to.equal(nonProposerHatId);
    });

    it('should emit HatWhitelisted event when a hat is whitelisted', async () => {
      await expect(
        concreteHatsProposalCreationWhitelist.connect(owner).whitelistHat(nonProposerHatId),
      )
        .to.emit(concreteHatsProposalCreationWhitelist, 'HatWhitelisted')
        .withArgs(nonProposerHatId);
    });

    it('should not allow non-owner to whitelist a hat', async () => {
      await expect(
        concreteHatsProposalCreationWhitelist.connect(nonOwner).whitelistHat(nonProposerHatId),
      ).to.be.revertedWithCustomError(
        concreteHatsProposalCreationWhitelist,
        'OwnableUnauthorizedAccount',
      );
    });

    it('should not allow whitelisting an already whitelisted hat', async () => {
      await expect(
        concreteHatsProposalCreationWhitelist.connect(owner).whitelistHat(proposerHatId1),
      ).to.be.revertedWithCustomError(
        concreteHatsProposalCreationWhitelist,
        'HatAlreadyWhitelisted',
      );
    });
  });

  describe('removeHatFromWhitelist', () => {
    it('should allow owner to remove a hat from the whitelist', async () => {
      await concreteHatsProposalCreationWhitelist
        .connect(owner)
        .removeHatFromWhitelist(proposerHatId1);

      const whitelistedHats = await concreteHatsProposalCreationWhitelist.getWhitelistedHatIds();
      expect(whitelistedHats.length).to.equal(1);
      expect(whitelistedHats[0]).to.equal(proposerHatId2);
    });

    it('should emit HatRemovedFromWhitelist event when a hat is removed', async () => {
      await expect(
        concreteHatsProposalCreationWhitelist.connect(owner).removeHatFromWhitelist(proposerHatId1),
      )
        .to.emit(concreteHatsProposalCreationWhitelist, 'HatRemovedFromWhitelist')
        .withArgs(proposerHatId1);
    });

    it('should not allow non-owner to remove a hat from the whitelist', async () => {
      await expect(
        concreteHatsProposalCreationWhitelist
          .connect(nonOwner)
          .removeHatFromWhitelist(proposerHatId1),
      ).to.be.revertedWithCustomError(
        concreteHatsProposalCreationWhitelist,
        'OwnableUnauthorizedAccount',
      );
    });

    it('should not allow removing a hat that is not whitelisted', async () => {
      await expect(
        concreteHatsProposalCreationWhitelist
          .connect(owner)
          .removeHatFromWhitelist(nonProposerHatId),
      ).to.be.revertedWithCustomError(concreteHatsProposalCreationWhitelist, 'HatNotWhitelisted');
    });
  });

  describe('isProposer override', () => {
    runHatsProposerTests({
      getMockHats: () => mockHats,
      getContract: () => concreteHatsProposalCreationWhitelist,
      hatWearer: () => hatWearer,
      nonHatWearer: () => nonHatWearer,
      tokenHolder: () => nonOwner, // Using nonOwner as tokenHolder since we don't have tokens in this test
      owner: () => owner,
      proposerHatId: proposerHatId1,
      nonProposerHatId,
    });
  });

  describe('getWhitelistedHatIds', () => {
    it('should return the correct list of whitelisted hat IDs', async () => {
      const whitelistedHats = await concreteHatsProposalCreationWhitelist.getWhitelistedHatIds();
      expect(whitelistedHats.length).to.equal(2);
      expect(whitelistedHats[0]).to.equal(proposerHatId1);
      expect(whitelistedHats[1]).to.equal(proposerHatId2);
    });

    it('should return updated list after adding a hat', async () => {
      await concreteHatsProposalCreationWhitelist.connect(owner).whitelistHat(nonProposerHatId);

      const whitelistedHats = await concreteHatsProposalCreationWhitelist.getWhitelistedHatIds();
      expect(whitelistedHats.length).to.equal(3);
      expect(whitelistedHats[2]).to.equal(nonProposerHatId);
    });

    it('should return updated list after removing a hat', async () => {
      await concreteHatsProposalCreationWhitelist
        .connect(owner)
        .removeHatFromWhitelist(proposerHatId1);

      const whitelistedHats = await concreteHatsProposalCreationWhitelist.getWhitelistedHatIds();
      expect(whitelistedHats.length).to.equal(1);
      expect(whitelistedHats[0]).to.equal(proposerHatId2);
    });
  });

  describe('ERC165', function () {
    let iHatsProposalCreationWhitelistV1InterfaceId: string;
    let iERC165InterfaceId: string;

    beforeEach(async function () {
      // Dynamically calculate interface IDs
      const IHatsProposalCreationWhitelistV1Interface =
        IHatsProposalCreationWhitelistV1__factory.createInterface();
      iHatsProposalCreationWhitelistV1InterfaceId = calculateInterfaceId(
        IHatsProposalCreationWhitelistV1Interface,
      );

      const IERC165Interface = IERC165__factory.createInterface();
      iERC165InterfaceId = calculateInterfaceId(IERC165Interface);
    });

    it('Should support IERC165 interface', async function () {
      const supported =
        await concreteHatsProposalCreationWhitelist.supportsInterface(iERC165InterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should support IHatsProposalCreationWhitelistV1 interface', async function () {
      const supported = await concreteHatsProposalCreationWhitelist.supportsInterface(
        iHatsProposalCreationWhitelistV1InterfaceId,
      );
      void expect(supported).to.be.true;
    });

    it('Should not support random interface', async function () {
      const randomInterfaceId = '0x12345678';
      const supported =
        await concreteHatsProposalCreationWhitelist.supportsInterface(randomInterfaceId);
      void expect(supported).to.be.false;
    });
  });
});
