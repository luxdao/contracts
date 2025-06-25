import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  WarrantHedgeyV1,
  WarrantHedgeyV1__factory,
  MockERC20,
  MockERC20__factory,
  MockVotesERC20V1,
  MockVotesERC20V1__factory,
  MockVotingTokenLockupPlans,
  MockVotingTokenLockupPlans__factory,
  ERC1967Proxy__factory,
} from '../../../typechain-types';
import { IWarrantHedgeyV1 } from '../../../typechain-types/contracts/interfaces/decent/deployables/IWarrantHedgeyV1';
import { deploymentBlockTests } from '../../unit/shared/deploymentBlockTests';
import { supportsInterfaceTests } from '../../unit/shared/supportsInterfaceTests';

// Time utilities
const time = {
  latest: async (): Promise<number> => {
    const block = await ethers.provider.getBlock('latest');
    return block!.timestamp;
  },
  increaseTo: async (timestamp: number): Promise<void> => {
    await ethers.provider.send('evm_mine', [timestamp]);
  },
};

describe('WarrantHedgeyV1', () => {
  let owner: SignerWithAddress;
  let warrantHolder: SignerWithAddress;
  let feeReceiver: SignerWithAddress;
  let recipient: SignerWithAddress;
  let proxyDeployer: SignerWithAddress;

  let warrantHedgey: WarrantHedgeyV1;
  let warrantHedgeyImplementation: WarrantHedgeyV1;
  let mockToken: MockERC20;
  let mockFeeToken: MockERC20;
  let mockVotesToken: MockVotesERC20V1;
  let mockHedgey: MockVotingTokenLockupPlans;

  const TOKEN_AMOUNT = ethers.parseEther('1000');
  const TOKEN_PRICE = ethers.parseEther('0.5'); // 0.5 fee tokens per warrant token
  const EXPIRATION_DURATION = 30 * 24 * 60 * 60; // 30 days
  const HEDGEY_START = 100; // 100 seconds from now for absolute, 100 seconds after unlock for relative
  const HEDGEY_CLIFF = 7 * 24 * 60 * 60; // 7 days cliff
  const HEDGEY_RATE = ethers.parseEther('10'); // 10 tokens per period
  const HEDGEY_PERIOD = 24 * 60 * 60; // 1 day period

  async function deployWarrantHedgeyProxy(
    params: IWarrantHedgeyV1.InitParamsStruct,
  ): Promise<WarrantHedgeyV1> {
    const fullInitData = WarrantHedgeyV1__factory.createInterface().encodeFunctionData(
      'initialize',
      [params],
    );

    const proxy = await new ERC1967Proxy__factory(proxyDeployer).deploy(
      await warrantHedgeyImplementation.getAddress(),
      fullInitData,
    );

    return WarrantHedgeyV1__factory.connect(await proxy.getAddress(), owner);
  }

  beforeEach(async () => {
    [owner, warrantHolder, feeReceiver, recipient, , proxyDeployer] = await ethers.getSigners();

    // Deploy mock tokens
    mockToken = await new MockERC20__factory(owner).deploy('Mock Token', 'MTK', 18);
    mockFeeToken = await new MockERC20__factory(owner).deploy('Mock Fee Token', 'MFT', 18);
    mockVotesToken = await new MockVotesERC20V1__factory(owner).deploy();
    await mockVotesToken.initialize('Mock Votes Token', 'MVT', owner.address);

    // Deploy mock Hedgey
    mockHedgey = await new MockVotingTokenLockupPlans__factory(owner).deploy();

    // Deploy implementation
    warrantHedgeyImplementation = await new WarrantHedgeyV1__factory(owner).deploy();

    // Mint tokens for testing
    await mockToken.mint(owner.address, ethers.parseEther('10000'));
    await mockFeeToken.mint(warrantHolder.address, ethers.parseEther('10000'));
  });

  describe('Initialization', () => {
    it('should initialize with absolute time mode correctly', async () => {
      const currentTime = await time.latest();
      const expirationTime = currentTime + EXPIRATION_DURATION;
      const hedgeyStartTime = currentTime + HEDGEY_START;

      const params: IWarrantHedgeyV1.InitParamsStruct = {
        relativeTime: false,
        owner: owner.address,
        warrantHolder: warrantHolder.address,
        token: mockToken.address,
        feeToken: mockFeeToken.address,
        tokenAmount: TOKEN_AMOUNT,
        tokenPrice: TOKEN_PRICE,
        feeReceiver: feeReceiver.address,
        expiration: expirationTime,
        hedgeyTokenLockupPlans: mockHedgey.address,
        hedgeyStart: hedgeyStartTime,
        hedgeyRelativeCliff: HEDGEY_CLIFF,
        hedgeyRate: HEDGEY_RATE,
        hedgeyPeriod: HEDGEY_PERIOD,
      };

      warrantHedgey = await deployWarrantHedgeyProxy(params);

      // Check base parameters
      expect(await warrantHedgey.relativeTime()).to.be.false;
      expect(await warrantHedgey.owner()).to.equal(owner.address);
      expect(await warrantHedgey.warrantHolder()).to.equal(warrantHolder.address);
      expect(await warrantHedgey.token()).to.equal(mockToken.address);
      expect(await warrantHedgey.feeToken()).to.equal(mockFeeToken.address);
      expect(await warrantHedgey.tokenAmount()).to.equal(TOKEN_AMOUNT);
      expect(await warrantHedgey.tokenPrice()).to.equal(TOKEN_PRICE);
      expect(await warrantHedgey.feeReceiver()).to.equal(feeReceiver.address);
      expect(await warrantHedgey.expiration()).to.equal(expirationTime);
      expect(await warrantHedgey.executed()).to.be.false;

      // Check Hedgey-specific parameters
      expect(await warrantHedgey.hedgeyTokenLockupPlans()).to.equal(mockHedgey.address);
      expect(await warrantHedgey.hedgeyStart()).to.equal(hedgeyStartTime);
      expect(await warrantHedgey.hedgeyRelativeCliff()).to.equal(HEDGEY_CLIFF);
      expect(await warrantHedgey.hedgeyRate()).to.equal(HEDGEY_RATE);
      expect(await warrantHedgey.hedgeyPeriod()).to.equal(HEDGEY_PERIOD);
    });

    it('should revert if hedgeyRate is zero', async () => {
      const currentTime = await time.latest();

      const params: IWarrantHedgeyV1.InitParamsStruct = {
        relativeTime: false,
        owner: owner.address,
        warrantHolder: warrantHolder.address,
        token: mockToken.address,
        feeToken: mockFeeToken.address,
        tokenAmount: TOKEN_AMOUNT,
        tokenPrice: TOKEN_PRICE,
        feeReceiver: feeReceiver.address,
        expiration: currentTime + EXPIRATION_DURATION,
        hedgeyTokenLockupPlans: mockHedgey.address,
        hedgeyStart: currentTime + HEDGEY_START,
        hedgeyRelativeCliff: HEDGEY_CLIFF,
        hedgeyRate: 0n,
        hedgeyPeriod: HEDGEY_PERIOD,
      };

      await expect(deployWarrantHedgeyProxy(params)).to.be.revertedWithCustomError(
        warrantHedgeyImplementation,
        'InvalidRate',
      );
    });

    it('should revert if hedgeyRate exceeds tokenAmount', async () => {
      const currentTime = await time.latest();

      const params: IWarrantHedgeyV1.InitParamsStruct = {
        relativeTime: false,
        owner: owner.address,
        warrantHolder: warrantHolder.address,
        token: mockToken.address,
        feeToken: mockFeeToken.address,
        tokenAmount: TOKEN_AMOUNT,
        tokenPrice: TOKEN_PRICE,
        feeReceiver: feeReceiver.address,
        expiration: currentTime + EXPIRATION_DURATION,
        hedgeyTokenLockupPlans: mockHedgey.address,
        hedgeyStart: currentTime + HEDGEY_START,
        hedgeyRelativeCliff: HEDGEY_CLIFF,
        hedgeyRate: TOKEN_AMOUNT + 1n,
        hedgeyPeriod: HEDGEY_PERIOD,
      };

      await expect(deployWarrantHedgeyProxy(params)).to.be.revertedWithCustomError(
        warrantHedgeyImplementation,
        'RateExceedsAmount',
      );
    });

    it('should revert if hedgeyPeriod is zero', async () => {
      const currentTime = await time.latest();

      const params: IWarrantHedgeyV1.InitParamsStruct = {
        relativeTime: false,
        owner: owner.address,
        warrantHolder: warrantHolder.address,
        token: mockToken.address,
        feeToken: mockFeeToken.address,
        tokenAmount: TOKEN_AMOUNT,
        tokenPrice: TOKEN_PRICE,
        feeReceiver: feeReceiver.address,
        expiration: currentTime + EXPIRATION_DURATION,
        hedgeyTokenLockupPlans: mockHedgey.address,
        hedgeyStart: currentTime + HEDGEY_START,
        hedgeyRelativeCliff: HEDGEY_CLIFF,
        hedgeyRate: HEDGEY_RATE,
        hedgeyPeriod: 0n,
      };

      await expect(deployWarrantHedgeyProxy(params)).to.be.revertedWithCustomError(
        warrantHedgeyImplementation,
        'InvalidPeriod',
      );
    });

    it('should revert if cliff exceeds vesting end', async () => {
      const currentTime = await time.latest();

      // Calculate a cliff that would exceed the vesting end
      // With 100 tokens at 10 per period, we need 10 periods = 10 days
      // Setting cliff to 11 days should exceed end
      const excessiveCliff = 11 * 24 * 60 * 60;

      const params: IWarrantHedgeyV1.InitParamsStruct = {
        relativeTime: false,
        owner: owner.address,
        warrantHolder: warrantHolder.address,
        token: mockToken.address,
        feeToken: mockFeeToken.address,
        tokenAmount: ethers.parseEther('100'), // 100 tokens
        tokenPrice: TOKEN_PRICE,
        feeReceiver: feeReceiver.address,
        expiration: currentTime + EXPIRATION_DURATION,
        hedgeyTokenLockupPlans: mockHedgey.address,
        hedgeyStart: currentTime + HEDGEY_START,
        hedgeyRelativeCliff: excessiveCliff,
        hedgeyRate: ethers.parseEther('10'), // 10 tokens per period
        hedgeyPeriod: 24 * 60 * 60, // 1 day
      };

      await expect(deployWarrantHedgeyProxy(params)).to.be.revertedWithCustomError(
        warrantHedgeyImplementation,
        'CliffExceedsEnd',
      );
    });
  });

  describe('Execute - Absolute Time', () => {
    let currentTime: number;
    let expirationTime: number;
    let hedgeyStartTime: number;

    beforeEach(async () => {
      currentTime = await time.latest();
      expirationTime = currentTime + EXPIRATION_DURATION;
      hedgeyStartTime = currentTime + HEDGEY_START;

      const params: IWarrantHedgeyV1.InitParamsStruct = {
        relativeTime: false,
        owner: owner.address,
        warrantHolder: warrantHolder.address,
        token: mockToken.address,
        feeToken: mockFeeToken.address,
        tokenAmount: TOKEN_AMOUNT,
        tokenPrice: TOKEN_PRICE,
        feeReceiver: feeReceiver.address,
        expiration: expirationTime,
        hedgeyTokenLockupPlans: mockHedgey.address,
        hedgeyStart: hedgeyStartTime,
        hedgeyRelativeCliff: HEDGEY_CLIFF,
        hedgeyRate: HEDGEY_RATE,
        hedgeyPeriod: HEDGEY_PERIOD,
      };

      warrantHedgey = await deployWarrantHedgeyProxy(params);

      // Transfer tokens to warrant contract
      await mockToken.transfer(warrantHedgey.address, TOKEN_AMOUNT);

      // Approve fee payment
      await mockFeeToken.connect(warrantHolder).approve(warrantHedgey.address, ethers.MaxUint256);
    });

    it('should execute warrant successfully after hedgeyStart', async () => {
      // Wait until after hedgeyStart
      await time.increaseTo(hedgeyStartTime + 1);

      const expectedFee = (TOKEN_AMOUNT * TOKEN_PRICE) / ethers.parseEther('1');
      const feeReceiverBalanceBefore = await mockFeeToken.balanceOf(feeReceiver.address);

      const tx = await warrantHedgey.connect(warrantHolder).execute(recipient.address);

      // Check fee was transferred
      expect(await mockFeeToken.balanceOf(feeReceiver.address)).to.equal(
        feeReceiverBalanceBefore + expectedFee,
      );

      // Check execution was marked
      expect(await warrantHedgey.executed()).to.be.true;

      // Check Hedgey was called with correct parameters
      const createPlanCall = await mockHedgey.lastCreatePlanCall();
      expect(createPlanCall.recipient).to.equal(recipient.address);
      expect(createPlanCall.token).to.equal(mockToken.address);
      expect(createPlanCall.amount).to.equal(TOKEN_AMOUNT);
      expect(createPlanCall.start).to.equal(hedgeyStartTime);
      expect(createPlanCall.cliff).to.equal(hedgeyStartTime + HEDGEY_CLIFF);
      expect(createPlanCall.rate).to.equal(HEDGEY_RATE);
      expect(createPlanCall.period).to.equal(HEDGEY_PERIOD);

      // Check event
      await expect(tx).to.emit(warrantHedgey, 'Executed').withArgs(recipient.address);
    });

    it('should revert if executed before hedgeyStart', async () => {
      // Try to execute before hedgeyStart
      await expect(
        warrantHedgey.connect(warrantHolder).execute(recipient.address),
      ).to.be.revertedWithCustomError(warrantHedgey, 'HedgeyStartNotElapsed');
    });
  });

  describe('Execute - Relative Time', () => {
    const UNLOCK_TIME = 1000;

    beforeEach(async () => {
      const params: IWarrantHedgeyV1.InitParamsStruct = {
        relativeTime: true,
        owner: owner.address,
        warrantHolder: warrantHolder.address,
        token: mockVotesToken.address,
        feeToken: mockFeeToken.address,
        tokenAmount: TOKEN_AMOUNT,
        tokenPrice: TOKEN_PRICE,
        feeReceiver: feeReceiver.address,
        expiration: EXPIRATION_DURATION, // duration after unlock
        hedgeyTokenLockupPlans: mockHedgey.address,
        hedgeyStart: HEDGEY_START, // offset from unlock time
        hedgeyRelativeCliff: HEDGEY_CLIFF,
        hedgeyRate: HEDGEY_RATE,
        hedgeyPeriod: HEDGEY_PERIOD,
      };

      warrantHedgey = await deployWarrantHedgeyProxy(params);

      // Transfer tokens to warrant contract
      await mockVotesToken.transfer(warrantHedgey.address, TOKEN_AMOUNT);

      // Set unlock time on votes token
      await mockVotesToken.setUnlockTime(UNLOCK_TIME);

      // Approve fee payment
      await mockFeeToken.connect(warrantHolder).approve(warrantHedgey.address, ethers.MaxUint256);
    });

    it('should execute warrant with correct relative time calculations', async () => {
      // Wait for unlock
      await time.increaseTo(UNLOCK_TIME + 1);

      const tx = await warrantHedgey.connect(warrantHolder).execute(recipient.address);

      // Check Hedgey was called with correct start time (unlock time + hedgeyStart)
      const createPlanCall = await mockHedgey.lastCreatePlanCall();
      expect(createPlanCall.start).to.equal(UNLOCK_TIME + HEDGEY_START);
      expect(createPlanCall.cliff).to.equal(UNLOCK_TIME + HEDGEY_START + HEDGEY_CLIFF);

      // Check event
      await expect(tx).to.emit(warrantHedgey, 'Executed').withArgs(recipient.address);
    });

    it('should revert if token is still locked', async () => {
      await mockVotesToken.setLocked(true);

      await expect(
        warrantHedgey.connect(warrantHolder).execute(recipient.address),
      ).to.be.revertedWithCustomError(warrantHedgey, 'TokenLocked');
    });
  });

  describe('Vesting Parameter Validation', () => {
    it('should correctly calculate vesting end for even division', async () => {
      const currentTime = await time.latest();

      // 100 tokens at 10 per period = exactly 10 periods
      const params: IWarrantHedgeyV1.InitParamsStruct = {
        relativeTime: false,
        owner: owner.address,
        warrantHolder: warrantHolder.address,
        token: mockToken.address,
        feeToken: mockFeeToken.address,
        tokenAmount: ethers.parseEther('100'),
        tokenPrice: TOKEN_PRICE,
        feeReceiver: feeReceiver.address,
        expiration: currentTime + EXPIRATION_DURATION,
        hedgeyTokenLockupPlans: mockHedgey.address,
        hedgeyStart: currentTime + HEDGEY_START,
        hedgeyRelativeCliff: HEDGEY_CLIFF,
        hedgeyRate: ethers.parseEther('10'),
        hedgeyPeriod: 24 * 60 * 60, // 1 day
      };

      // Should not revert
      warrantHedgey = await deployWarrantHedgeyProxy(params);
      expect(await warrantHedgey.hedgeyRate()).to.equal(ethers.parseEther('10'));
    });

    it('should correctly calculate vesting end for uneven division', async () => {
      const currentTime = await time.latest();

      // 105 tokens at 10 per period = 10.5 periods, rounded up to 11
      const params: IWarrantHedgeyV1.InitParamsStruct = {
        relativeTime: false,
        owner: owner.address,
        warrantHolder: warrantHolder.address,
        token: mockToken.address,
        feeToken: mockFeeToken.address,
        tokenAmount: ethers.parseEther('105'),
        tokenPrice: TOKEN_PRICE,
        feeReceiver: feeReceiver.address,
        expiration: currentTime + EXPIRATION_DURATION,
        hedgeyTokenLockupPlans: mockHedgey.address,
        hedgeyStart: currentTime + HEDGEY_START,
        hedgeyRelativeCliff: HEDGEY_CLIFF,
        hedgeyRate: ethers.parseEther('10'),
        hedgeyPeriod: 24 * 60 * 60, // 1 day
      };

      // Should not revert
      warrantHedgey = await deployWarrantHedgeyProxy(params);
      expect(await warrantHedgey.hedgeyRate()).to.equal(ethers.parseEther('10'));
    });
  });

  describe('Version', () => {
    beforeEach(async () => {
      const currentTime = await time.latest();

      const params: IWarrantHedgeyV1.InitParamsStruct = {
        relativeTime: false,
        owner: owner.address,
        warrantHolder: warrantHolder.address,
        token: mockToken.address,
        feeToken: mockFeeToken.address,
        tokenAmount: TOKEN_AMOUNT,
        tokenPrice: TOKEN_PRICE,
        feeReceiver: feeReceiver.address,
        expiration: currentTime + EXPIRATION_DURATION,
        hedgeyTokenLockupPlans: mockHedgey.address,
        hedgeyStart: currentTime + HEDGEY_START,
        hedgeyRelativeCliff: HEDGEY_CLIFF,
        hedgeyRate: HEDGEY_RATE,
        hedgeyPeriod: HEDGEY_PERIOD,
      };

      warrantHedgey = await deployWarrantHedgeyProxy(params);
    });

    it('should return correct version', async () => {
      expect(await warrantHedgey.version()).to.equal(1);
    });
  });

  // Shared tests
  supportsInterfaceTests({
    contractFactory: async () => {
      const currentTime = await time.latest();

      const params: IWarrantHedgeyV1.InitParamsStruct = {
        relativeTime: false,
        owner: owner.address,
        warrantHolder: warrantHolder.address,
        token: mockToken.address,
        feeToken: mockFeeToken.address,
        tokenAmount: TOKEN_AMOUNT,
        tokenPrice: TOKEN_PRICE,
        feeReceiver: feeReceiver.address,
        expiration: currentTime + EXPIRATION_DURATION,
        hedgeyTokenLockupPlans: mockHedgey.address,
        hedgeyStart: currentTime + HEDGEY_START,
        hedgeyRelativeCliff: HEDGEY_CLIFF,
        hedgeyRate: HEDGEY_RATE,
        hedgeyPeriod: HEDGEY_PERIOD,
      };

      return deployWarrantHedgeyProxy(params);
    },
    supportedInterfaces: [
      { name: 'IWarrantHedgeyV1', id: '0x11111111' }, // Replace with actual interface ID
      { name: 'IWarrantBase', id: '0x12345678' }, // Replace with actual interface ID
      { name: 'IVersion', id: '0x87654321' }, // Replace with actual interface ID
      { name: 'IDeploymentBlockV1', id: '0xabcdef01' }, // Replace with actual interface ID
    ],
  });

  deploymentBlockTests({
    contractFactory: async () => {
      const currentTime = await time.latest();

      const params: IWarrantHedgeyV1.InitParamsStruct = {
        relativeTime: false,
        owner: owner.address,
        warrantHolder: warrantHolder.address,
        token: mockToken.address,
        feeToken: mockFeeToken.address,
        tokenAmount: TOKEN_AMOUNT,
        tokenPrice: TOKEN_PRICE,
        feeReceiver: feeReceiver.address,
        expiration: currentTime + EXPIRATION_DURATION,
        hedgeyTokenLockupPlans: mockHedgey.address,
        hedgeyStart: currentTime + HEDGEY_START,
        hedgeyRelativeCliff: HEDGEY_CLIFF,
        hedgeyRate: HEDGEY_RATE,
        hedgeyPeriod: HEDGEY_PERIOD,
      };

      return deployWarrantHedgeyProxy(params);
    },
  });
});
