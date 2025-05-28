import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { mine, time } from '@nomicfoundation/hardhat-network-helpers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  ERC1967Proxy__factory,
  IERC165__factory,
  IERC20__factory,
  IVersion__factory,
  IVotes__factory,
  VotesStakedERC20V1,
  VotesStakedERC20V1__factory,
  MockERC20Votes,
  MockERC20Votes__factory,
} from '../../../typechain-types';
import { calculateInterfaceId } from '../../helpers/utils';
import { runUUPSUpgradeabilityTests } from '../../helpers/uupsUpgradeabilityTests';

// Helper function for deploying VotesERC20V1 instances using ERC1967Proxy
async function deployVotesStakedERC20Proxy(
  proxyDeployer: SignerWithAddress,
  implementation: string,
  owner: SignerWithAddress,
  name: string,
  symbol: string,
  stakedToken: string,
  minimumStakingPeriod: bigint,
): Promise<VotesStakedERC20V1> {
  // Create initialization data with function selector
  const fullInitData =
    VotesStakedERC20V1__factory.createInterface().getFunction('initialize').selector +
    ethers.AbiCoder.defaultAbiCoder()
      .encode(
        ['string', 'string', 'address', 'address', 'uint256', 'address[]'],
        [name, symbol, owner.address, stakedToken, minimumStakingPeriod, []],
      )
      .slice(2);

  // Deploy the proxy with the implementation
  const proxy = await new ERC1967Proxy__factory(proxyDeployer).deploy(implementation, fullInitData);

  // Return a contract instance connected to the proxy
  return VotesStakedERC20V1__factory.connect(await proxy.getAddress(), owner);
}

describe('VotesStakedERC20V1', () => {
  // signers
  let proxyDeployer: SignerWithAddress;
  let owner: SignerWithAddress;
  let alice: SignerWithAddress;
  // let bob: SignerWithAddress;
  // let carol: SignerWithAddress;
  let nonOwner: SignerWithAddress;

  // contracts
  let votesStakedERC20: VotesStakedERC20V1;
  let masterCopy: string;
  let stakedToken: MockERC20Votes;
  let rewardsTokenA: MockERC20Votes;
  let rewardsTokenB: MockERC20Votes;
  let rewardsTokenC: MockERC20Votes;

  beforeEach(async () => {
    // Get signers
    [proxyDeployer, owner, alice, nonOwner] = await ethers.getSigners();

    masterCopy = await (await new VotesStakedERC20V1__factory(owner).deploy()).getAddress();
    stakedToken = await new MockERC20Votes__factory(owner).deploy();
    rewardsTokenA = await new MockERC20Votes__factory(owner).deploy();
    rewardsTokenB = await new MockERC20Votes__factory(owner).deploy();
    rewardsTokenC = await new MockERC20Votes__factory(owner).deploy();
  });

  describe('Initialization', () => {
    it('should initialize with correct values', async () => {
      votesStakedERC20 = await deployVotesStakedERC20Proxy(
        proxyDeployer,
        masterCopy,
        owner,
        'Test Staking Contract',
        'TSC',
        await stakedToken.getAddress(),
        604800n,
      );

      expect(await votesStakedERC20.name()).to.equal('Test Staking Contract');
      expect(await votesStakedERC20.symbol()).to.equal('TSC');
      expect(await votesStakedERC20.owner()).to.equal(owner.address);
      expect(await votesStakedERC20.stakedToken()).to.equal(await stakedToken.getAddress());
      expect(await votesStakedERC20.minimumStakingPeriod()).to.equal(604800n);
    });

    it('should not allow reinitialization', async () => {
      votesStakedERC20 = await deployVotesStakedERC20Proxy(
        proxyDeployer,
        masterCopy,
        owner,
        'Test Staking Contract',
        'TSC',
        await stakedToken.getAddress(),
        604800n,
      );

      await expect(
        votesStakedERC20.initialize(
          'New Name',
          'NEW',
          owner.address,
          await stakedToken.getAddress(),
          604800n,
          [await rewardsTokenA.getAddress(), await rewardsTokenB.getAddress(), await rewardsTokenC.getAddress()],
        ),
      ).to.be.revertedWithCustomError(votesStakedERC20, 'InvalidInitialization');
    });

    it('Should have initialization disabled in the implementation', async function () {
      const implementationContract = VotesStakedERC20V1__factory.connect(masterCopy, proxyDeployer);

      await expect(
        implementationContract.initialize(
          'New Name',
          'NEW',
          owner.address,
          await stakedToken.getAddress(),
          604800n,
          [await rewardsTokenA.getAddress(), await rewardsTokenB.getAddress(), await rewardsTokenC.getAddress()],
        ),
      ).to.be.revertedWithCustomError(implementationContract, 'InvalidInitialization');
    });

    it('should set the owner correctly', async () => {
      votesStakedERC20 = await deployVotesStakedERC20Proxy(
        proxyDeployer,
        masterCopy,
        owner,
        'Test Staking Contract',
        'TSC',
        await stakedToken.getAddress(),
        604800n,
      );

      expect(await votesStakedERC20.owner()).to.equal(owner.address);
    });
  });

  describe('Ownership', () => {
    beforeEach(async () => {
      votesStakedERC20 = await deployVotesStakedERC20Proxy(
        proxyDeployer,
        masterCopy,
        owner,
        'Test Staking Contract',
        'TSC',
        await stakedToken.getAddress(),
        604800n,
      );
    });

    it('should set the owner correctly', async () => {
      const currentOwner = await votesStakedERC20.owner();
      expect(currentOwner).to.equal(owner.address);
    });

    it('should allow the owner to call authorized functions', async () => {
      await votesStakedERC20.connect(owner).renounceOwnership();
      expect(await votesStakedERC20.owner()).to.equal(ethers.ZeroAddress);
    });

    it('should not allow non-owners to call owner-only functions', async () => {
      await expect(
        votesStakedERC20.connect(alice).renounceOwnership(),
      ).to.be.revertedWithCustomError(votesStakedERC20, 'OwnableUnauthorizedAccount');
    });

    it('should allow the owner to set a new minimum staking period', async () => {
      await votesStakedERC20.connect(owner).setMinimumStakingPeriod(10n);
      expect(await votesStakedERC20.minimumStakingPeriod()).to.equal(10n);
    });

    it('should not allow non-owners to set a new minimum staking period', async () => {
      await expect(
        votesStakedERC20.connect(alice).setMinimumStakingPeriod(10n),
      ).to.be.revertedWithCustomError(votesStakedERC20, 'OwnableUnauthorizedAccount');
    });
  });

  describe('Version', () => {
    beforeEach(async () => {
      votesStakedERC20 = await deployVotesStakedERC20Proxy(
        proxyDeployer,
        masterCopy,
        owner,
        'Test Staking Contract',
        'TSC',
        await stakedToken.getAddress(),
        604800n,
      );
    });

    it('should return the correct version number', async () => {
      expect(await votesStakedERC20.getVersion()).to.equal(1);
    });
  });

  describe('ERC165', function () {
    // Interface IDs
    let iVersionInterfaceId: string;
    let iERC20InterfaceId: string;
    let iVotesInterfaceId: string;
    let iERC165InterfaceId: string;

    beforeEach(async function () {
      votesStakedERC20 = await deployVotesStakedERC20Proxy(
        proxyDeployer,
        masterCopy,
        owner,
        'Test Staking Contract',
        'TSC',
        await stakedToken.getAddress(),
        604800n,
      );

      // Calculate interface IDs
      const IVersionInterface = IVersion__factory.createInterface();
      iVersionInterfaceId = calculateInterfaceId(IVersionInterface);

      const IERC20Interface = IERC20__factory.createInterface();
      iERC20InterfaceId = calculateInterfaceId(IERC20Interface);

      const IVotesInterface = IVotes__factory.createInterface();
      iVotesInterfaceId = calculateInterfaceId(IVotesInterface);

      const IERC165Interface = IERC165__factory.createInterface();
      iERC165InterfaceId = calculateInterfaceId(IERC165Interface);
    });

    it('Should support IERC165 interface', async function () {
      const supported = await votesStakedERC20.supportsInterface(iERC165InterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should support IVersion interface', async function () {
      const supported = await votesStakedERC20.supportsInterface(iVersionInterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should support IERC20 interface', async function () {
      const supported = await votesStakedERC20.supportsInterface(iERC20InterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should support IVotes interface', async function () {
      const supported = await votesStakedERC20.supportsInterface(iVotesInterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should not support random interface', async function () {
      const randomInterfaceId = '0x12345678';
      const supported = await votesStakedERC20.supportsInterface(randomInterfaceId);
      void expect(supported).to.be.false;
    });
  });

  describe('Timestamp-based clock functions', () => {
    beforeEach(async () => {
      votesStakedERC20 = await deployVotesStakedERC20Proxy(
        proxyDeployer,
        masterCopy,
        owner,
        'Test Staking Contract',
        'TSC',
        await stakedToken.getAddress(),
        604800n,
      );
    });

    it('should return current timestamp from clock()', async () => {
      const currentTime = await ethers.provider.getBlock('latest').then(b => b!.timestamp);
      const clockTime = await votesStakedERC20.clock();

      // Allow small variance due to block mining time
      expect(Number(clockTime)).to.be.closeTo(currentTime, 5);
    });

    it("should return 'mode=timestamp' from CLOCK_MODE()", async () => {
      expect(await votesStakedERC20.CLOCK_MODE()).to.equal('mode=timestamp');
    });

    it('should use timestamp for vote checkpoints', async () => {
      // Delegate to another address
      await votesStakedERC20.connect(owner).delegate(alice.address);

      // Mine a block to move forward in time
      await mine(1);

      // Get current timestamp which is now > the delegation timestamp
      const currentTime = await time.latest();

      // The voting power at the previous timestamp should be available
      const votingPower = await votesStakedERC20.getPastVotes(alice.address, currentTime - 1);

      // Should match the owner's balance since we just delegated
      expect(votingPower).to.equal(await votesStakedERC20.balanceOf(owner.address));
    });
  });

  describe('VotesERC20V1 UUPS Upgradeability', function () {
    beforeEach(async function () {
      votesStakedERC20 = await deployVotesStakedERC20Proxy(
        proxyDeployer,
        masterCopy,
        owner,
        'Test Staking Contract',
        'TSC',
        await stakedToken.getAddress(),
        604800n,
      );
    });

    // Run UUPS upgradeability tests
    runUUPSUpgradeabilityTests({
      getContract: () => votesStakedERC20,
      createNewImplementation: async () => {
        const newImplementation = await new VotesStakedERC20V1__factory(owner).deploy();
        return newImplementation;
      },
      owner: () => owner,
      nonOwner: () => nonOwner,
    });
  });
});
