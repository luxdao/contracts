import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  ConcreteHatsProposalCreationWhitelistV1,
  ConcreteHatsProposalCreationWhitelistV1__factory,
  MockHats,
  MockHats__factory,
} from '../../../typechain-types';
import { topHatIdToHatId } from '../../helpers';

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

  // Hat IDs
  let topHatId: bigint;
  let proposerHatId1: bigint;
  let proposerHatId2: bigint;
  let nonProposerHatId: bigint;

  beforeEach(async () => {
    [deployer, owner, nonOwner, hatWearer, nonHatWearer] = await ethers.getSigners();

    // Deploy the MockHats contract
    mockHats = await new MockHats__factory(deployer).deploy();

    // Create hats for testing
    // Mint a top hat
    topHatId = topHatIdToHatId((await mockHats.lastTopHatId()) + 1n);
    await mockHats.mintTopHat(deployer.address, '', '');

    // Create the first proposer hat
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

    // Create the second proposer hat
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

    // Create a non-proposer hat
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

    // Mint the first proposer hat to the hat wearer
    await mockHats.mintHat(proposerHatId1, hatWearer.address);

    // Mint the non-proposer hat to the non-hat wearer (for testing adding/removing from whitelist)
    await mockHats.mintHat(nonProposerHatId, nonHatWearer.address);

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

  describe('isProposer', () => {
    it('should return true for an address wearing any of the whitelisted hats', async () => {
      expect(await concreteHatsProposalCreationWhitelist.isProposer(hatWearer.address)).to.equal(
        true,
      );
    });

    it('should return false for an address not wearing any of the whitelisted hats', async () => {
      expect(await concreteHatsProposalCreationWhitelist.isProposer(nonHatWearer.address)).to.equal(
        false,
      );
    });

    it('should return false after a hat is removed from the whitelist', async () => {
      await concreteHatsProposalCreationWhitelist
        .connect(owner)
        .removeHatFromWhitelist(proposerHatId1);
      expect(await concreteHatsProposalCreationWhitelist.isProposer(hatWearer.address)).to.equal(
        false,
      );
    });

    it('should return true when an address starts wearing a whitelisted hat', async () => {
      expect(await concreteHatsProposalCreationWhitelist.isProposer(nonHatWearer.address)).to.equal(
        false,
      );

      await mockHats.mintHat(proposerHatId2, nonHatWearer.address);

      expect(await concreteHatsProposalCreationWhitelist.isProposer(nonHatWearer.address)).to.equal(
        true,
      );
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

  describe('Version', () => {
    it('should return correct version', async () => {
      expect(await concreteHatsProposalCreationWhitelist.getVersion()).to.equal(1);
    });
  });
});
