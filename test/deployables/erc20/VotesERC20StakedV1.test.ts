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
  IVotesERC20StakedV1__factory,
  MockERC20Votes,
  MockERC20Votes__factory,
  VotesERC20StakedV1,
  VotesERC20StakedV1__factory,
} from '../../../typechain-types';
import { calculateInterfaceId } from '../../helpers/utils';
import { runUUPSUpgradeabilityTests } from '../../helpers/uupsUpgradeabilityTests';

// Helper function for deploying VotesERC20StakedV1 instances using ERC1967Proxy
async function deployVotesERC20StakedProxy(
  proxyDeployer: SignerWithAddress,
  implementation: string,
  owner: SignerWithAddress,
  name: string,
  symbol: string,
  stakedToken: string,
  minimumStakingPeriod: bigint,
  rewardsTokens: string[],
): Promise<VotesERC20StakedV1> {
  // Create initialization data with function selector
  const fullInitData =
    VotesERC20StakedV1__factory.createInterface().getFunction('initialize').selector +
    ethers.AbiCoder.defaultAbiCoder()
      .encode(
        ['string', 'string', 'address', 'address', 'uint256', 'address[]'],
        [name, symbol, owner.address, stakedToken, minimumStakingPeriod, rewardsTokens],
      )
      .slice(2);

  // Deploy the proxy with the implementation
  const proxy = await new ERC1967Proxy__factory(proxyDeployer).deploy(implementation, fullInitData);

  // Return a contract instance connected to the proxy
  return VotesERC20StakedV1__factory.connect(await proxy.getAddress(), owner);
}

describe('VotesERC20StakedV1', () => {
  // signers
  let proxyDeployer: SignerWithAddress;
  let owner: SignerWithAddress;
  let alice: SignerWithAddress;
  let bob: SignerWithAddress;
  // let carol: SignerWithAddress;
  let nonOwner: SignerWithAddress;

  // contracts
  let votesERC20Staked: VotesERC20StakedV1;
  let masterCopy: string;
  let stakedToken: MockERC20Votes;
  let rewardsTokenA: MockERC20Votes;
  let rewardsTokenB: MockERC20Votes;
  let rewardsTokenC: MockERC20Votes;

  beforeEach(async () => {
    // Get signers
    [proxyDeployer, owner, alice, bob, nonOwner] = await ethers.getSigners();

    masterCopy = await (await new VotesERC20StakedV1__factory(owner).deploy()).getAddress();
    stakedToken = await new MockERC20Votes__factory(owner).deploy();
    rewardsTokenA = await new MockERC20Votes__factory(owner).deploy();
    rewardsTokenB = await new MockERC20Votes__factory(owner).deploy();
    rewardsTokenC = await new MockERC20Votes__factory(owner).deploy();
  });

  describe('Initialization', () => {
    it('should initialize with correct values', async () => {
      votesERC20Staked = await deployVotesERC20StakedProxy(
        proxyDeployer,
        masterCopy,
        owner,
        'Test Staking Contract',
        'TSC',
        await stakedToken.getAddress(),
        604800n,
        [
          await rewardsTokenA.getAddress(),
          await rewardsTokenB.getAddress(),
          await rewardsTokenC.getAddress(),
        ],
      );

      expect(await votesERC20Staked.name()).to.equal('Test Staking Contract');
      expect(await votesERC20Staked.symbol()).to.equal('TSC');
      expect(await votesERC20Staked.owner()).to.equal(owner.address);
      expect(await votesERC20Staked.stakedToken()).to.equal(await stakedToken.getAddress());
      expect(await votesERC20Staked.minimumStakingPeriod()).to.equal(604800n);
      expect(await votesERC20Staked.rewardsTokens()).to.deep.equal([
        await rewardsTokenA.getAddress(),
        await rewardsTokenB.getAddress(),
        await rewardsTokenC.getAddress(),
      ]);
    });

    it('should not allow reinitialization', async () => {
      votesERC20Staked = await deployVotesERC20StakedProxy(
        proxyDeployer,
        masterCopy,
        owner,
        'Test Staking Contract',
        'TSC',
        await stakedToken.getAddress(),
        604800n,
        [
          await rewardsTokenA.getAddress(),
          await rewardsTokenB.getAddress(),
          await rewardsTokenC.getAddress(),
        ],
      );

      await expect(
        votesERC20Staked.initialize(
          'New Name',
          'NEW',
          owner.address,
          await stakedToken.getAddress(),
          604800n,
          [
            await rewardsTokenA.getAddress(),
            await rewardsTokenB.getAddress(),
            await rewardsTokenC.getAddress(),
          ],
        ),
      ).to.be.revertedWithCustomError(votesERC20Staked, 'InvalidInitialization');
    });

    it('Should have initialization disabled in the implementation', async function () {
      const implementationContract = VotesERC20StakedV1__factory.connect(masterCopy, proxyDeployer);

      await expect(
        implementationContract.initialize(
          'New Name',
          'NEW',
          owner.address,
          await stakedToken.getAddress(),
          604800n,
          [
            await rewardsTokenA.getAddress(),
            await rewardsTokenB.getAddress(),
            await rewardsTokenC.getAddress(),
          ],
        ),
      ).to.be.revertedWithCustomError(implementationContract, 'InvalidInitialization');
    });

    it('should set the owner correctly', async () => {
      votesERC20Staked = await deployVotesERC20StakedProxy(
        proxyDeployer,
        masterCopy,
        owner,
        'Test Staking Contract',
        'TSC',
        await stakedToken.getAddress(),
        604800n,
        [
          await rewardsTokenA.getAddress(),
          await rewardsTokenB.getAddress(),
          await rewardsTokenC.getAddress(),
        ],
      );

      expect(await votesERC20Staked.owner()).to.equal(owner.address);
    });
  });

  describe('Ownership', () => {
    beforeEach(async () => {
      votesERC20Staked = await deployVotesERC20StakedProxy(
        proxyDeployer,
        masterCopy,
        owner,
        'Test Staking Contract',
        'TSC',
        await stakedToken.getAddress(),
        604800n,
        [
          await rewardsTokenA.getAddress(),
          await rewardsTokenB.getAddress(),
          await rewardsTokenC.getAddress(),
        ],
      );
    });

    it('should set the owner correctly', async () => {
      const currentOwner = await votesERC20Staked.owner();
      expect(currentOwner).to.equal(owner.address);
    });

    it('Should allow owner to transfer ownership', async function () {
      await votesERC20Staked.connect(owner).transferOwnership(alice.address);
      await votesERC20Staked.connect(alice).acceptOwnership();
      expect(await votesERC20Staked.owner()).to.equal(alice.address);
    });

    it('should allow the owner to call authorized functions', async () => {
      await votesERC20Staked.connect(owner).renounceOwnership();
      expect(await votesERC20Staked.owner()).to.equal(ethers.ZeroAddress);
    });

    it('should not allow non-owners to call owner-only functions', async () => {
      await expect(
        votesERC20Staked.connect(alice).renounceOwnership(),
      ).to.be.revertedWithCustomError(votesERC20Staked, 'OwnableUnauthorizedAccount');
    });

    it('should allow the owner to set a new minimum staking period', async () => {
      await votesERC20Staked.connect(owner).updateMinimumStakingPeriod(10n);
      expect(await votesERC20Staked.minimumStakingPeriod()).to.equal(10n);
    });

    it('should not allow non-owners to set a new minimum staking period', async () => {
      await expect(
        votesERC20Staked.connect(alice).updateMinimumStakingPeriod(10n),
      ).to.be.revertedWithCustomError(votesERC20Staked, 'OwnableUnauthorizedAccount');
    });
  });

  describe('Version', () => {
    beforeEach(async () => {
      votesERC20Staked = await deployVotesERC20StakedProxy(
        proxyDeployer,
        masterCopy,
        owner,
        'Test Staking Contract',
        'TSC',
        await stakedToken.getAddress(),
        604800n,
        [
          await rewardsTokenA.getAddress(),
          await rewardsTokenB.getAddress(),
          await rewardsTokenC.getAddress(),
        ],
      );
    });

    it('should return the correct version number', async () => {
      expect(await votesERC20Staked.version()).to.equal(1);
    });
  });

  describe('ERC165', function () {
    // Interface IDs
    let iVersionInterfaceId: string;
    let iERC20InterfaceId: string;
    let iVotesInterfaceId: string;
    let iERC165InterfaceId: string;
    let iVotesERC20StakedV1InterfaceId: string;
    beforeEach(async function () {
      votesERC20Staked = await deployVotesERC20StakedProxy(
        proxyDeployer,
        masterCopy,
        owner,
        'Test Staking Contract',
        'TSC',
        await stakedToken.getAddress(),
        604800n,
        [
          await rewardsTokenA.getAddress(),
          await rewardsTokenB.getAddress(),
          await rewardsTokenC.getAddress(),
        ],
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

      const IVotesERC20StakedV1Interface = IVotesERC20StakedV1__factory.createInterface();
      iVotesERC20StakedV1InterfaceId = calculateInterfaceId(IVotesERC20StakedV1Interface);
    });

    it('Should support IERC165 interface', async function () {
      const supported = await votesERC20Staked.supportsInterface(iERC165InterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should support IVotesERC20StakedV1 interface', async function () {
      const supported = await votesERC20Staked.supportsInterface(iVotesERC20StakedV1InterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should support IVersion interface', async function () {
      const supported = await votesERC20Staked.supportsInterface(iVersionInterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should support IERC20 interface', async function () {
      const supported = await votesERC20Staked.supportsInterface(iERC20InterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should support IVotes interface', async function () {
      const supported = await votesERC20Staked.supportsInterface(iVotesInterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should not support random interface', async function () {
      const randomInterfaceId = '0x12345678';
      const supported = await votesERC20Staked.supportsInterface(randomInterfaceId);
      void expect(supported).to.be.false;
    });
  });

  describe('Timestamp-based clock functions', () => {
    beforeEach(async () => {
      votesERC20Staked = await deployVotesERC20StakedProxy(
        proxyDeployer,
        masterCopy,
        owner,
        'Test Staking Contract',
        'TSC',
        await stakedToken.getAddress(),
        604800n,
        [
          await rewardsTokenA.getAddress(),
          await rewardsTokenB.getAddress(),
          await rewardsTokenC.getAddress(),
        ],
      );
    });

    it('should return current timestamp from clock()', async () => {
      const currentTime = await ethers.provider.getBlock('latest').then(b => b!.timestamp);
      const clockTime = await votesERC20Staked.clock();

      // Allow small variance due to block mining time
      expect(Number(clockTime)).to.be.closeTo(currentTime, 5);
    });

    it("should return 'mode=timestamp' from CLOCK_MODE()", async () => {
      expect(await votesERC20Staked.CLOCK_MODE()).to.equal('mode=timestamp');
    });

    it('should use timestamp for vote checkpoints', async () => {
      // Delegate to another address
      await votesERC20Staked.connect(owner).delegate(alice.address);

      // Mine a block to move forward in time
      await mine(1);

      // Get current timestamp which is now > the delegation timestamp
      const currentTime = await time.latest();

      // The voting power at the previous timestamp should be available
      const votingPower = await votesERC20Staked.getPastVotes(alice.address, currentTime - 1);

      // Should match the owner's balance since we just delegated
      expect(votingPower).to.equal(await votesERC20Staked.balanceOf(owner.address));
    });
  });

  describe('VotesERC20V1 UUPS Upgradeability', function () {
    beforeEach(async function () {
      votesERC20Staked = await deployVotesERC20StakedProxy(
        proxyDeployer,
        masterCopy,
        owner,
        'Test Staking Contract',
        'TSC',
        await stakedToken.getAddress(),
        604800n,
        [
          await rewardsTokenA.getAddress(),
          await rewardsTokenB.getAddress(),
          await rewardsTokenC.getAddress(),
        ],
      );
    });

    // Run UUPS upgradeability tests
    runUUPSUpgradeabilityTests({
      getContract: () => votesERC20Staked,
      createNewImplementation: async () => {
        const newImplementation = await new VotesERC20StakedV1__factory(owner).deploy();
        return newImplementation;
      },
      owner: () => owner,
      nonOwner: () => nonOwner,
    });
  });

  describe('Rewards Tokens', function () {
    beforeEach(async function () {
      votesERC20Staked = await deployVotesERC20StakedProxy(
        proxyDeployer,
        masterCopy,
        owner,
        'Test Staking Contract',
        'TSC',
        await stakedToken.getAddress(),
        604800n,
        [
          await rewardsTokenA.getAddress(),
          await rewardsTokenB.getAddress(),
          await rewardsTokenC.getAddress(),
        ],
      );

      // Mint 10 staked tokens to alice
      await stakedToken.mint(alice.address, ethers.parseEther('10'));

      // Alice approves the staking contract to spend her tokens
      await stakedToken
        .connect(alice)
        .approve(await votesERC20Staked.getAddress(), ethers.parseEther('10'));
    });

    it('should not allow adding duplicate rewards tokens', async function () {
      await expect(
        votesERC20Staked.connect(owner).addRewardsTokens([await rewardsTokenA.getAddress()]),
      ).to.be.revertedWithCustomError(votesERC20Staked, 'DuplicateRewardsToken');
    });

    it('should allow owner to add rewards tokens', async function () {
      const rewardsTokenD = await new MockERC20Votes__factory(owner).deploy();
      const rewardsTokenE = await new MockERC20Votes__factory(owner).deploy();

      await votesERC20Staked
        .connect(owner)
        .addRewardsTokens([await rewardsTokenD.getAddress(), await rewardsTokenE.getAddress()]);

      expect(await votesERC20Staked.rewardsTokens()).to.deep.equal([
        await rewardsTokenA.getAddress(),
        await rewardsTokenB.getAddress(),
        await rewardsTokenC.getAddress(),
        await rewardsTokenD.getAddress(),
        await rewardsTokenE.getAddress(),
      ]);
    });

    it('should not allow non-owner to add rewards tokens', async function () {
      await expect(
        votesERC20Staked.connect(alice).addRewardsTokens([await rewardsTokenA.getAddress()]),
      ).to.be.revertedWithCustomError(votesERC20Staked, 'OwnableUnauthorizedAccount');
    });

    it('should return rewards token data', async function () {
      const [rewardsRate, rewardsDistributed, rewardsClaimed] =
        await votesERC20Staked.rewardsTokenData(await rewardsTokenA.getAddress());

      expect(rewardsRate).to.equal(0n);
      expect(rewardsDistributed).to.equal(0n);
      expect(rewardsClaimed).to.equal(0n);
    });

    it('should not return data for invalid rewards tokens', async function () {
      await expect(
        votesERC20Staked.rewardsTokenData(await bob.address),
      ).to.be.revertedWithCustomError(votesERC20Staked, 'InvalidRewardsToken');
    });
  });

  describe('Staking', function () {
    beforeEach(async function () {
      votesERC20Staked = await deployVotesERC20StakedProxy(
        proxyDeployer,
        masterCopy,
        owner,
        'Test Staking Contract',
        'TSC',
        await stakedToken.getAddress(),
        604800n,
        [
          await rewardsTokenA.getAddress(),
          await rewardsTokenB.getAddress(),
          await rewardsTokenC.getAddress(),
        ],
      );

      // Mint 10 staked tokens to alice
      await stakedToken.mint(alice.address, ethers.parseEther('10'));

      // Alice approves the staking contract to spend her tokens
      await stakedToken
        .connect(alice)
        .approve(await votesERC20Staked.getAddress(), ethers.parseEther('10'));
    });

    it('should not allow users to stake 0 tokens', async function () {
      await expect(votesERC20Staked.connect(alice).stake(0n)).to.be.revertedWithCustomError(
        votesERC20Staked,
        'ZeroStake',
      );
    });

    it('should not allow users to transfer or approve VotesERC20StakedV1 tokens', async function () {
      await votesERC20Staked.connect(alice).stake(ethers.parseEther('10'));

      await expect(
        votesERC20Staked.connect(alice).approve(bob.address, ethers.parseEther('10')),
      ).to.be.revertedWithCustomError(votesERC20Staked, 'NonTransferable');

      await expect(
        votesERC20Staked.connect(alice).transfer(bob.address, ethers.parseEther('10')),
      ).to.be.revertedWithCustomError(votesERC20Staked, 'NonTransferable');

      await expect(
        votesERC20Staked
          .connect(alice)
          .transferFrom(bob.address, alice.address, ethers.parseEther('10')),
      ).to.be.revertedWithCustomError(votesERC20Staked, 'NonTransferable');
    });

    it('should allow users to stake tokens', async function () {
      await votesERC20Staked.connect(alice).stake(ethers.parseEther('10'));

      expect(await votesERC20Staked.balanceOf(alice.address)).to.equal(ethers.parseEther('10'));
      expect(await stakedToken.balanceOf(alice.address)).to.equal(ethers.parseEther('0'));

      expect(await stakedToken.balanceOf(await votesERC20Staked.getAddress())).to.equal(
        ethers.parseEther('10'),
      );

      expect(await votesERC20Staked.totalStaked()).to.equal(ethers.parseEther('10'));

      expect(await votesERC20Staked.stakerData(alice.address)).to.deep.equal([
        ethers.parseEther('10'),
        await time.latest(),
      ]);

      expect(
        await votesERC20Staked.stakerRewardsData(await rewardsTokenA.getAddress(), alice.address),
      ).to.deep.equal([0n, 0n]);
    });

    it('should allow users to unstake less tokens than their staked amount', async function () {
      await votesERC20Staked.connect(alice).stake(ethers.parseEther('10'));
      const stakeTimestamp = await time.latest();

      // move forward 7 days
      await time.increase(604800);

      await votesERC20Staked.connect(alice).unstake(ethers.parseEther('5'));

      expect(await votesERC20Staked.balanceOf(alice.address)).to.equal(ethers.parseEther('5'));
      expect(await stakedToken.balanceOf(alice.address)).to.equal(ethers.parseEther('5'));
      expect(await votesERC20Staked.stakerData(alice.address)).to.deep.equal([
        ethers.parseEther('5'),
        stakeTimestamp,
      ]);
    });

    it('should allow users to unstake tokens', async function () {
      await votesERC20Staked.connect(alice).stake(ethers.parseEther('10'));
      const stakeTimestamp = await time.latest();

      // move forward 7 days
      await time.increase(604800);

      await votesERC20Staked.connect(alice).unstake(ethers.parseEther('10'));

      expect(await votesERC20Staked.balanceOf(alice.address)).to.equal(ethers.parseEther('0'));
      expect(await stakedToken.balanceOf(alice.address)).to.equal(ethers.parseEther('10'));

      expect(await stakedToken.balanceOf(await votesERC20Staked.getAddress())).to.equal(
        ethers.parseEther('0'),
      );

      expect(await votesERC20Staked.totalStaked()).to.equal(ethers.parseEther('0'));

      expect(await votesERC20Staked.stakerData(alice.address)).to.deep.equal([
        ethers.parseEther('0'),
        stakeTimestamp,
      ]);

      expect(
        await votesERC20Staked.stakerRewardsData(await rewardsTokenA.getAddress(), alice.address),
      ).to.deep.equal([0n, 0n]);
    });

    it('should not allow users to unstake zero tokens', async function () {
      await votesERC20Staked.connect(alice).stake(ethers.parseEther('10'));

      await time.increase(604800);

      await expect(votesERC20Staked.connect(alice).unstake(0n)).to.be.revertedWithCustomError(
        votesERC20Staked,
        'ZeroUnstake',
      );
    });

    it('should not allow users to unstake tokens before their minimum staking period has elapsed', async function () {
      await votesERC20Staked.connect(alice).stake(ethers.parseEther('10'));

      await expect(
        votesERC20Staked.connect(alice).unstake(ethers.parseEther('10')),
      ).to.be.revertedWithCustomError(votesERC20Staked, 'MinimumStakingPeriod');
    });

    it('should not allow users to unstake more token than they have staked', async function () {
      await votesERC20Staked.connect(alice).stake(ethers.parseEther('10'));

      await time.increase(604800);

      await expect(
        votesERC20Staked.connect(alice).unstake(ethers.parseEther('11')),
      ).to.be.revertedWithPanic(0x11);
    });
  });
});
