import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { time } from '@nomicfoundation/hardhat-network-helpers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  WarrantHedgeyV1,
  WarrantHedgeyV1__factory,
  MockERC20,
  MockERC20__factory,
  MockERC20Votes,
  MockERC20Votes__factory,
  MockVotingTokenLockupPlans,
  MockVotingTokenLockupPlans__factory,
  ERC1967Proxy__factory,
  IDeploymentBlock__factory,
  IWarrantHedgeyV1__factory,
  IWarrantBase__factory,
  IVersion__factory,
} from '../../../../typechain-types';
import { IWarrantHedgeyV1 } from '../../../../typechain-types/contracts/interfaces/decent/deployables/IWarrantHedgeyV1';
import { runDeploymentBlockTests } from '../../shared/deploymentBlockTests';
import { runInitializerEventEmitterTests } from '../../shared/initializerEventEmitterTests';
import { runSupportsInterfaceTests } from '../../shared/supportsInterfaceTests';

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
  let mockVotesToken: MockERC20Votes;
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
    mockVotesToken = await new MockERC20Votes__factory(owner).deploy();

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
        token: await mockToken.getAddress(),
        feeToken: await mockFeeToken.getAddress(),
        tokenAmount: TOKEN_AMOUNT,
        tokenPrice: TOKEN_PRICE,
        feeReceiver: feeReceiver.address,
        expiration: expirationTime,
        hedgeyTokenLockupPlans: await mockHedgey.getAddress(),
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
      expect(await warrantHedgey.token()).to.equal(await mockToken.getAddress());
      expect(await warrantHedgey.feeToken()).to.equal(await mockFeeToken.getAddress());
      expect(await warrantHedgey.tokenAmount()).to.equal(TOKEN_AMOUNT);
      expect(await warrantHedgey.tokenPrice()).to.equal(TOKEN_PRICE);
      expect(await warrantHedgey.feeReceiver()).to.equal(feeReceiver.address);
      expect(await warrantHedgey.expiration()).to.equal(expirationTime);
      expect(await warrantHedgey.executed()).to.be.false;

      // Check Hedgey-specific parameters
      expect(await warrantHedgey.hedgeyTokenLockupPlans()).to.equal(await mockHedgey.getAddress());
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
        token: await mockToken.getAddress(),
        feeToken: await mockFeeToken.getAddress(),
        tokenAmount: TOKEN_AMOUNT,
        tokenPrice: TOKEN_PRICE,
        feeReceiver: feeReceiver.address,
        expiration: currentTime + EXPIRATION_DURATION,
        hedgeyTokenLockupPlans: await mockHedgey.getAddress(),
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
        token: await mockToken.getAddress(),
        feeToken: await mockFeeToken.getAddress(),
        tokenAmount: TOKEN_AMOUNT,
        tokenPrice: TOKEN_PRICE,
        feeReceiver: feeReceiver.address,
        expiration: currentTime + EXPIRATION_DURATION,
        hedgeyTokenLockupPlans: await mockHedgey.getAddress(),
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
        token: await mockToken.getAddress(),
        feeToken: await mockFeeToken.getAddress(),
        tokenAmount: TOKEN_AMOUNT,
        tokenPrice: TOKEN_PRICE,
        feeReceiver: feeReceiver.address,
        expiration: currentTime + EXPIRATION_DURATION,
        hedgeyTokenLockupPlans: await mockHedgey.getAddress(),
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
        token: await mockToken.getAddress(),
        feeToken: await mockFeeToken.getAddress(),
        tokenAmount: ethers.parseEther('100'), // 100 tokens
        tokenPrice: TOKEN_PRICE,
        feeReceiver: feeReceiver.address,
        expiration: currentTime + EXPIRATION_DURATION,
        hedgeyTokenLockupPlans: await mockHedgey.getAddress(),
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
        token: await mockToken.getAddress(),
        feeToken: await mockFeeToken.getAddress(),
        tokenAmount: TOKEN_AMOUNT,
        tokenPrice: TOKEN_PRICE,
        feeReceiver: feeReceiver.address,
        expiration: expirationTime,
        hedgeyTokenLockupPlans: await mockHedgey.getAddress(),
        hedgeyStart: hedgeyStartTime,
        hedgeyRelativeCliff: HEDGEY_CLIFF,
        hedgeyRate: HEDGEY_RATE,
        hedgeyPeriod: HEDGEY_PERIOD,
      };

      warrantHedgey = await deployWarrantHedgeyProxy(params);

      // Transfer tokens to warrant contract
      await mockToken.transfer(await warrantHedgey.getAddress(), TOKEN_AMOUNT);

      // Approve fee payment
      await mockFeeToken
        .connect(warrantHolder)
        .approve(await warrantHedgey.getAddress(), ethers.MaxUint256);
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
      expect(createPlanCall.token).to.equal(await mockToken.getAddress());
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
    let UNLOCK_TIME: number;

    beforeEach(async () => {
      const params: IWarrantHedgeyV1.InitParamsStruct = {
        relativeTime: true,
        owner: owner.address,
        warrantHolder: warrantHolder.address,
        token: await mockVotesToken.getAddress(),
        feeToken: await mockFeeToken.getAddress(),
        tokenAmount: TOKEN_AMOUNT,
        tokenPrice: TOKEN_PRICE,
        feeReceiver: feeReceiver.address,
        expiration: EXPIRATION_DURATION, // duration after unlock
        hedgeyTokenLockupPlans: await mockHedgey.getAddress(),
        hedgeyStart: HEDGEY_START, // offset from unlock time
        hedgeyRelativeCliff: HEDGEY_CLIFF,
        hedgeyRate: HEDGEY_RATE,
        hedgeyPeriod: HEDGEY_PERIOD,
      };

      warrantHedgey = await deployWarrantHedgeyProxy(params);

      // Mint tokens to warrant contract
      await mockVotesToken.mint(await warrantHedgey.getAddress(), TOKEN_AMOUNT);

      UNLOCK_TIME = await time.latest();

      // Set unlock time on votes token
      await mockVotesToken.setUnlockTime(UNLOCK_TIME);

      // Approve fee payment
      await mockFeeToken
        .connect(warrantHolder)
        .approve(await warrantHedgey.getAddress(), ethers.MaxUint256);
    });

    it('should execute warrant with correct relative time calculations', async () => {
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

  describe('Vesting Parameter Validation Errors', () => {
    it('should revert with InvalidToken when token is zero address', async () => {
      const currentTime = await time.latest();

      const params: IWarrantHedgeyV1.InitParamsStruct = {
        relativeTime: false,
        owner: owner.address,
        warrantHolder: warrantHolder.address,
        token: ethers.ZeroAddress,
        feeToken: await mockFeeToken.getAddress(),
        tokenAmount: TOKEN_AMOUNT,
        tokenPrice: TOKEN_PRICE,
        feeReceiver: feeReceiver.address,
        expiration: currentTime + EXPIRATION_DURATION,
        hedgeyTokenLockupPlans: await mockHedgey.getAddress(),
        hedgeyStart: currentTime + HEDGEY_START,
        hedgeyRelativeCliff: HEDGEY_CLIFF,
        hedgeyRate: HEDGEY_RATE,
        hedgeyPeriod: HEDGEY_PERIOD,
      };

      await expect(deployWarrantHedgeyProxy(params)).to.be.revertedWithCustomError(
        warrantHedgey,
        'InvalidToken',
      );
    });

    it('should revert with InvalidAmount when tokenAmount is zero', async () => {
      const currentTime = await time.latest();

      const params: IWarrantHedgeyV1.InitParamsStruct = {
        relativeTime: false,
        owner: owner.address,
        warrantHolder: warrantHolder.address,
        token: await mockToken.getAddress(),
        feeToken: await mockFeeToken.getAddress(),
        tokenAmount: 0, // Zero amount should trigger InvalidAmount
        tokenPrice: TOKEN_PRICE,
        feeReceiver: feeReceiver.address,
        expiration: currentTime + EXPIRATION_DURATION,
        hedgeyTokenLockupPlans: await mockHedgey.getAddress(),
        hedgeyStart: currentTime + HEDGEY_START,
        hedgeyRelativeCliff: HEDGEY_CLIFF,
        hedgeyRate: HEDGEY_RATE,
        hedgeyPeriod: HEDGEY_PERIOD,
      };

      await expect(deployWarrantHedgeyProxy(params)).to.be.revertedWithCustomError(
        warrantHedgey,
        'InvalidAmount',
      );
    });

    it('should revert with InvalidRate when hedgeyRate is zero', async () => {
      const currentTime = await time.latest();

      const params: IWarrantHedgeyV1.InitParamsStruct = {
        relativeTime: false,
        owner: owner.address,
        warrantHolder: warrantHolder.address,
        token: await mockToken.getAddress(),
        feeToken: await mockFeeToken.getAddress(),
        tokenAmount: TOKEN_AMOUNT,
        tokenPrice: TOKEN_PRICE,
        feeReceiver: feeReceiver.address,
        expiration: currentTime + EXPIRATION_DURATION,
        hedgeyTokenLockupPlans: await mockHedgey.getAddress(),
        hedgeyStart: currentTime + HEDGEY_START,
        hedgeyRelativeCliff: HEDGEY_CLIFF,
        hedgeyRate: 0, // Zero rate should trigger InvalidRate
        hedgeyPeriod: HEDGEY_PERIOD,
      };

      await expect(deployWarrantHedgeyProxy(params)).to.be.revertedWithCustomError(
        warrantHedgey,
        'InvalidRate',
      );
    });

    it('should revert with RateExceedsAmount when hedgeyRate exceeds tokenAmount', async () => {
      const currentTime = await time.latest();

      const params: IWarrantHedgeyV1.InitParamsStruct = {
        relativeTime: false,
        owner: owner.address,
        warrantHolder: warrantHolder.address,
        token: await mockToken.getAddress(),
        feeToken: await mockFeeToken.getAddress(),
        tokenAmount: ethers.parseEther('100'),
        tokenPrice: TOKEN_PRICE,
        feeReceiver: feeReceiver.address,
        expiration: currentTime + EXPIRATION_DURATION,
        hedgeyTokenLockupPlans: await mockHedgey.getAddress(),
        hedgeyStart: currentTime + HEDGEY_START,
        hedgeyRelativeCliff: HEDGEY_CLIFF,
        hedgeyRate: ethers.parseEther('150'), // Rate > Amount should trigger RateExceedsAmount
        hedgeyPeriod: HEDGEY_PERIOD,
      };

      await expect(deployWarrantHedgeyProxy(params)).to.be.revertedWithCustomError(
        warrantHedgey,
        'RateExceedsAmount',
      );
    });

    it('should revert with InvalidPeriod when hedgeyPeriod is zero', async () => {
      const currentTime = await time.latest();

      const params: IWarrantHedgeyV1.InitParamsStruct = {
        relativeTime: false,
        owner: owner.address,
        warrantHolder: warrantHolder.address,
        token: await mockToken.getAddress(),
        feeToken: await mockFeeToken.getAddress(),
        tokenAmount: TOKEN_AMOUNT,
        tokenPrice: TOKEN_PRICE,
        feeReceiver: feeReceiver.address,
        expiration: currentTime + EXPIRATION_DURATION,
        hedgeyTokenLockupPlans: await mockHedgey.getAddress(),
        hedgeyStart: currentTime + HEDGEY_START,
        hedgeyRelativeCliff: HEDGEY_CLIFF,
        hedgeyRate: HEDGEY_RATE,
        hedgeyPeriod: 0, // Zero period should trigger InvalidPeriod
      };

      await expect(deployWarrantHedgeyProxy(params)).to.be.revertedWithCustomError(
        warrantHedgey,
        'InvalidPeriod',
      );
    });

    it('should revert with CliffExceedsEnd when cliff exceeds vesting end time', async () => {
      const currentTime = await time.latest();

      // Set up parameters where cliff will exceed the vesting end
      // 100 tokens at 10 per period = 10 periods = 10 * 86400 = 864000 seconds
      // If we set cliff to 900000 seconds, it will exceed the vesting end
      const params: IWarrantHedgeyV1.InitParamsStruct = {
        relativeTime: false,
        owner: owner.address,
        warrantHolder: warrantHolder.address,
        token: await mockToken.getAddress(),
        feeToken: await mockFeeToken.getAddress(),
        tokenAmount: ethers.parseEther('100'),
        tokenPrice: TOKEN_PRICE,
        feeReceiver: feeReceiver.address,
        expiration: currentTime + EXPIRATION_DURATION,
        hedgeyTokenLockupPlans: await mockHedgey.getAddress(),
        hedgeyStart: currentTime + HEDGEY_START,
        hedgeyRelativeCliff: 900000, // Cliff > vesting end should trigger CliffExceedsEnd
        hedgeyRate: ethers.parseEther('10'),
        hedgeyPeriod: 24 * 60 * 60, // 1 day = 86400 seconds
      };

      await expect(deployWarrantHedgeyProxy(params)).to.be.revertedWithCustomError(
        warrantHedgey,
        'CliffExceedsEnd',
      );
    });

    it('should not revert when cliff equals vesting end time', async () => {
      const currentTime = await time.latest();

      // Set up parameters where cliff equals the vesting end
      // 100 tokens at 10 per period = 10 periods = 10 * 86400 = 864000 seconds
      const params: IWarrantHedgeyV1.InitParamsStruct = {
        relativeTime: false,
        owner: owner.address,
        warrantHolder: warrantHolder.address,
        token: await mockToken.getAddress(),
        feeToken: await mockFeeToken.getAddress(),
        tokenAmount: ethers.parseEther('100'),
        tokenPrice: TOKEN_PRICE,
        feeReceiver: feeReceiver.address,
        expiration: currentTime + EXPIRATION_DURATION,
        hedgeyTokenLockupPlans: await mockHedgey.getAddress(),
        hedgeyStart: currentTime + HEDGEY_START,
        hedgeyRelativeCliff: 864000, // Cliff = vesting end should be valid
        hedgeyRate: ethers.parseEther('10'),
        hedgeyPeriod: 24 * 60 * 60, // 1 day = 86400 seconds
      };

      // Should not revert when cliff equals vesting end
      warrantHedgey = await deployWarrantHedgeyProxy(params);
      expect(await warrantHedgey.hedgeyRelativeCliff()).to.equal(864000);
    });
  });

  describe('Version', () => {
    it('should return correct version', async () => {
      expect(await warrantHedgey.version()).to.equal(1);
    });
  });

  describe('ERC165 supportsInterface', () => {
    runSupportsInterfaceTests({
      getContract: () => warrantHedgey,
      supportedInterfaceFactories: [
        IWarrantHedgeyV1__factory,
        IWarrantBase__factory,
        IVersion__factory,
        IDeploymentBlock__factory,
      ],
    });
  });

  describe('Deployment Block', () => {
    runDeploymentBlockTests({
      getContract: () => warrantHedgey,
    });
  });

  describe('InitializerEventEmitter', () => {
    let testDeployer: SignerWithAddress;

    beforeEach(async () => {
      [testDeployer] = await ethers.getSigners();
    });

    runInitializerEventEmitterTests({
      contractFactory: WarrantHedgeyV1__factory,
      masterCopy: async () =>
        await (await new WarrantHedgeyV1__factory(testDeployer).deploy()).getAddress(),
      deployer: () => testDeployer,
      initializeParams: async () => [
        {
          relativeTime: false,
          owner: owner.address,
          warrantHolder: warrantHolder.address,
          token: await mockToken.getAddress(),
          feeToken: await mockFeeToken.getAddress(),
          tokenAmount: TOKEN_AMOUNT,
          tokenPrice: TOKEN_PRICE,
          feeReceiver: feeReceiver.address,
          expiration: 1000000, // Static timestamp
          hedgeyTokenLockupPlans: await mockHedgey.getAddress(),
          hedgeyStart: 1000001, // Static timestamp
          hedgeyRelativeCliff: HEDGEY_CLIFF,
          hedgeyRate: HEDGEY_RATE,
          hedgeyPeriod: HEDGEY_PERIOD,
        },
      ],
      getExpectedInitData: async () =>
        ethers.AbiCoder.defaultAbiCoder().encode(
          [
            'tuple(bool,address,address,address,address,uint256,uint256,address,uint256,address,uint256,uint256,uint256,uint256)',
          ],
          [
            [
              false,
              owner.address,
              warrantHolder.address,
              await mockToken.getAddress(),
              await mockFeeToken.getAddress(),
              TOKEN_AMOUNT,
              TOKEN_PRICE,
              feeReceiver.address,
              1000000, // Static timestamp
              await mockHedgey.getAddress(),
              1000001, // Static timestamp
              HEDGEY_CLIFF,
              HEDGEY_RATE,
              HEDGEY_PERIOD,
            ],
          ],
        ),
    });
  });
});
