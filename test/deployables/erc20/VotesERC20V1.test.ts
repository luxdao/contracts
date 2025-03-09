import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  IERC165__factory,
  IERC20__factory,
  IERC20Permit__factory,
  IVersion__factory,
  IVotes__factory,
  VotesERC20V1,
  VotesERC20V1__factory,
} from '../../../typechain-types';
import { getModuleProxyFactory } from '../../helpers/globals.test';
import { calculateInterfaceId, calculateProxyAddress } from '../../helpers/utils';

// Helper function for deploying VotesERC20V1 instances
async function deployVotesERC20Proxy(
  votesERC20Mastercopy: VotesERC20V1,
  owner: SignerWithAddress,
  name: string,
  symbol: string,
  allocationAddresses: string[],
  allocationAmounts: bigint[],
): Promise<VotesERC20V1> {
  const moduleProxyFactory = getModuleProxyFactory();
  const salt = ethers.hexlify(ethers.randomBytes(32));

  const votesERC20SetupCalldata = VotesERC20V1__factory.createInterface().encodeFunctionData(
    'setUp',
    [
      ethers.AbiCoder.defaultAbiCoder().encode(
        ['string', 'string', 'address[]', 'uint256[]'],
        [name, symbol, allocationAddresses, allocationAmounts],
      ),
    ],
  );

  await moduleProxyFactory.deployModule(
    await votesERC20Mastercopy.getAddress(),
    votesERC20SetupCalldata,
    salt,
  );

  const predictedVotesERC20Address = await calculateProxyAddress(
    moduleProxyFactory,
    await votesERC20Mastercopy.getAddress(),
    votesERC20SetupCalldata,
    salt,
  );

  return VotesERC20V1__factory.connect(predictedVotesERC20Address, owner);
}

describe('VotesERC20V1', () => {
  // signers
  let owner: SignerWithAddress;
  let alice: SignerWithAddress;
  let bob: SignerWithAddress;
  let carol: SignerWithAddress;

  // contracts
  let votesERC20Mastercopy: VotesERC20V1;
  let votesERC20: VotesERC20V1;

  // constants
  const TOKEN_NAME = 'Test Voting Token';
  const TOKEN_SYMBOL = 'TVT';

  beforeEach(async () => {
    // Get signers
    [owner, alice, bob, carol] = await ethers.getSigners();

    // Deploy mastercopy
    votesERC20Mastercopy = await new VotesERC20V1__factory(owner).deploy();
  });

  describe('Initialization', () => {
    it('should initialize with correct name and symbol', async () => {
      votesERC20 = await deployVotesERC20Proxy(
        votesERC20Mastercopy,
        owner,
        TOKEN_NAME,
        TOKEN_SYMBOL,
        [],
        [],
      );

      expect(await votesERC20.name()).to.equal(TOKEN_NAME);
      expect(await votesERC20.symbol()).to.equal(TOKEN_SYMBOL);
    });

    it('should mint initial tokens according to allocations', async () => {
      const allocationAddresses = [alice.address, bob.address, carol.address];
      const allocationAmounts = [
        ethers.parseEther('100'),
        ethers.parseEther('200'),
        ethers.parseEther('300'),
      ];

      votesERC20 = await deployVotesERC20Proxy(
        votesERC20Mastercopy,
        owner,
        TOKEN_NAME,
        TOKEN_SYMBOL,
        allocationAddresses,
        allocationAmounts,
      );

      expect(await votesERC20.balanceOf(alice.address)).to.equal(allocationAmounts[0]);
      expect(await votesERC20.balanceOf(bob.address)).to.equal(allocationAmounts[1]);
      expect(await votesERC20.balanceOf(carol.address)).to.equal(allocationAmounts[2]);
      expect(await votesERC20.totalSupply()).to.equal(
        allocationAmounts[0] + allocationAmounts[1] + allocationAmounts[2],
      );
    });

    it('should handle empty allocation arrays', async () => {
      votesERC20 = await deployVotesERC20Proxy(
        votesERC20Mastercopy,
        owner,
        TOKEN_NAME,
        TOKEN_SYMBOL,
        [],
        [],
      );

      expect(await votesERC20.totalSupply()).to.equal(0);
    });

    it('should not allow reinitialization', async () => {
      votesERC20 = await deployVotesERC20Proxy(
        votesERC20Mastercopy,
        owner,
        TOKEN_NAME,
        TOKEN_SYMBOL,
        [],
        [],
      );

      const setupData = ethers.AbiCoder.defaultAbiCoder().encode(
        ['string', 'string', 'address[]', 'uint256[]'],
        ['New Name', 'NEW', [], []],
      );

      await expect(votesERC20.setUp(setupData)).to.be.revertedWithCustomError(
        votesERC20,
        'InvalidInitialization',
      );
    });
  });

  describe('Version', () => {
    beforeEach(async () => {
      votesERC20 = await deployVotesERC20Proxy(
        votesERC20Mastercopy,
        owner,
        TOKEN_NAME,
        TOKEN_SYMBOL,
        [],
        [],
      );
    });

    it('should return correct version', async () => {
      expect(await votesERC20.getVersion()).to.equal(1);
    });
  });

  describe('ERC165', function () {
    // Interface IDs
    let iVersionInterfaceId: string;
    let iERC20InterfaceId: string;
    let iERC20PermitInterfaceId: string;
    let iVotesInterfaceId: string;
    let iERC165InterfaceId: string;

    beforeEach(async function () {
      // Deploy VotesERC20 for this test section
      votesERC20 = await deployVotesERC20Proxy(
        votesERC20Mastercopy,
        owner,
        TOKEN_NAME,
        TOKEN_SYMBOL,
        [],
        [],
      );

      // Calculate interface IDs
      const IVersionInterface = IVersion__factory.createInterface();
      iVersionInterfaceId = calculateInterfaceId(IVersionInterface);

      const IERC20Interface = IERC20__factory.createInterface();
      iERC20InterfaceId = calculateInterfaceId(IERC20Interface);

      const IERC20PermitInterface = IERC20Permit__factory.createInterface();
      iERC20PermitInterfaceId = calculateInterfaceId(IERC20PermitInterface);

      const IVotesInterface = IVotes__factory.createInterface();
      iVotesInterfaceId = calculateInterfaceId(IVotesInterface);

      const IERC165Interface = IERC165__factory.createInterface();
      iERC165InterfaceId = calculateInterfaceId(IERC165Interface);
    });

    it('Should support IERC165 interface', async function () {
      const supported = await votesERC20.supportsInterface(iERC165InterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should support IVersion interface', async function () {
      const supported = await votesERC20.supportsInterface(iVersionInterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should support IERC20 interface', async function () {
      const supported = await votesERC20.supportsInterface(iERC20InterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should support IERC20Permit interface', async function () {
      const supported = await votesERC20.supportsInterface(iERC20PermitInterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should support IVotes interface', async function () {
      const supported = await votesERC20.supportsInterface(iVotesInterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should not support random interface', async function () {
      const randomInterfaceId = '0x12345678';
      const supported = await votesERC20.supportsInterface(randomInterfaceId);
      void expect(supported).to.be.false;
    });
  });
});
