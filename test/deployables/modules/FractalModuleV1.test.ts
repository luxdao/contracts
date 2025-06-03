import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  ERC1967Proxy__factory,
  FractalModuleV1,
  FractalModuleV1__factory,
  IERC165__factory,
  IFractalModuleV1__factory,
  IVersion__factory,
  MockAvatar,
  MockAvatar__factory,
  MockERC20Votes,
  MockERC20Votes__factory,
  UUPSUpgradeable,
} from '../../../typechain-types';
import { calculateInterfaceId } from '../../helpers/utils';
import { runUUPSUpgradeabilityTests } from '../../helpers/uupsUpgradeabilityTests';

// Helper functions for deploying FractalModuleV1 instances using ERC1967Proxy
async function deployFractalModuleProxy(
  proxyDeployer: SignerWithAddress,
  implementation: string,
  owner: SignerWithAddress,
  avatar: string,
  target: string,
): Promise<FractalModuleV1> {
  // Combine selector and encoded params
  const fullInitData =
    FractalModuleV1__factory.createInterface().getFunction('initialize').selector +
    ethers.AbiCoder.defaultAbiCoder()
      .encode(['address', 'address', 'address'], [owner.address, avatar, target])
      .slice(2);

  // Deploy the proxy with the implementation
  const proxy = await new ERC1967Proxy__factory(proxyDeployer).deploy(implementation, fullInitData);

  // Return a contract instance connected to the proxy
  return FractalModuleV1__factory.connect(await proxy.getAddress(), owner);
}

// Helper function for deploying using setUp instead of initialize
async function deployFractalModuleProxyWithSetUp(
  proxyDeployer: SignerWithAddress,
  implementation: string,
  owner: SignerWithAddress,
  avatar: string,
  target: string,
): Promise<FractalModuleV1> {
  // Create the call to setUp with the encoded parameters
  const fullInitData = FractalModuleV1__factory.createInterface().encodeFunctionData('setUp', [
    ethers.AbiCoder.defaultAbiCoder().encode(
      ['address', 'address', 'address'],
      [owner.address, avatar, target],
    ),
  ]);

  // Deploy the proxy with the implementation
  const proxy = await new ERC1967Proxy__factory(proxyDeployer).deploy(implementation, fullInitData);

  // Return a contract instance connected to the proxy
  return FractalModuleV1__factory.connect(await proxy.getAddress(), owner);
}

describe('FractalModuleV1', () => {
  // eoas
  let proxyDeployer: SignerWithAddress;
  let owner: SignerWithAddress;
  let nonOwner: SignerWithAddress;
  let user: SignerWithAddress;

  // mocks and mastercopies
  let masterCopy: string;
  let mockToken: MockERC20Votes;

  beforeEach(async () => {
    // Get signers
    [proxyDeployer, owner, nonOwner, user] = await ethers.getSigners();

    // Deploy implementation contract
    const implementation = await new FractalModuleV1__factory(proxyDeployer).deploy();
    masterCopy = await implementation.getAddress();
    mockToken = await new MockERC20Votes__factory(proxyDeployer).deploy();
  });

  describe('Initialization', () => {
    let fractalModule: FractalModuleV1;
    let avatar: MockAvatar;

    beforeEach(async () => {
      avatar = await new MockAvatar__factory(proxyDeployer).deploy();
    });

    describe('Owner parameter', () => {
      it('should set correct owner', async () => {
        fractalModule = await deployFractalModuleProxy(
          proxyDeployer,
          masterCopy,
          owner,
          await avatar.getAddress(),
          await avatar.getAddress(),
        );

        expect(await fractalModule.owner()).to.equal(owner.address);
      });
    });

    describe('Avatar and Target parameters', () => {
      it('should initialize with same avatar and target', async () => {
        fractalModule = await deployFractalModuleProxy(
          proxyDeployer,
          masterCopy,
          owner,
          await avatar.getAddress(),
          await avatar.getAddress(),
        );

        expect(await fractalModule.avatar()).to.equal(await avatar.getAddress());
        expect(await fractalModule.getFunction('target')()).to.equal(await avatar.getAddress());
      });

      it('should initialize with different target than avatar', async () => {
        fractalModule = await deployFractalModuleProxy(
          proxyDeployer,
          masterCopy,
          owner,
          await avatar.getAddress(),
          user.address, // Different from avatar
        );

        expect(await fractalModule.avatar()).to.equal(await avatar.getAddress());
        expect(await fractalModule.getFunction('target')()).to.equal(user.address);
      });

      it('should allow zero address avatar', async () => {
        fractalModule = await deployFractalModuleProxy(
          proxyDeployer,
          masterCopy,
          owner,
          ethers.ZeroAddress,
          await avatar.getAddress(),
        );

        expect(await fractalModule.avatar()).to.equal(ethers.ZeroAddress);
        expect(await fractalModule.getFunction('target')()).to.equal(await avatar.getAddress());
      });

      it('should allow zero address target', async () => {
        fractalModule = await deployFractalModuleProxy(
          proxyDeployer,
          masterCopy,
          owner,
          await avatar.getAddress(),
          ethers.ZeroAddress,
        );

        expect(await fractalModule.avatar()).to.equal(await avatar.getAddress());
        expect(await fractalModule.getFunction('target')()).to.equal(ethers.ZeroAddress);
      });

      it('should allow both avatar and target to be zero address', async () => {
        fractalModule = await deployFractalModuleProxy(
          proxyDeployer,
          masterCopy,
          owner,
          ethers.ZeroAddress,
          ethers.ZeroAddress,
        );

        expect(await fractalModule.avatar()).to.equal(ethers.ZeroAddress);
        expect(await fractalModule.getFunction('target')()).to.equal(ethers.ZeroAddress);
      });
    });

    describe('setUp function', () => {
      it('should correctly initialize contract when using setUp', async () => {
        fractalModule = await deployFractalModuleProxyWithSetUp(
          proxyDeployer,
          masterCopy,
          owner,
          await avatar.getAddress(),
          await avatar.getAddress(),
        );

        // Verify initialization was successful
        expect(await fractalModule.owner()).to.equal(owner.address);
        expect(await fractalModule.avatar()).to.equal(await avatar.getAddress());
        expect(await fractalModule.getFunction('target')()).to.equal(await avatar.getAddress());
      });

      it('should not allow setUp to be called again after initialization', async () => {
        fractalModule = await deployFractalModuleProxyWithSetUp(
          proxyDeployer,
          masterCopy,
          owner,
          await avatar.getAddress(),
          await avatar.getAddress(),
        );

        // Encode parameters correctly for setUp
        const innerParams = ethers.AbiCoder.defaultAbiCoder().encode(
          ['address', 'address', 'address'],
          [owner.address, await avatar.getAddress(), await avatar.getAddress()],
        );

        // Attempt to call setUp again - should revert
        await expect(fractalModule.setUp(innerParams)).to.be.revertedWithCustomError(
          fractalModule,
          'InvalidInitialization',
        );
      });
    });

    describe('Reinitialization prevention', () => {
      it('should not allow reinitialization', async () => {
        fractalModule = await deployFractalModuleProxy(
          proxyDeployer,
          masterCopy,
          owner,
          await avatar.getAddress(),
          await avatar.getAddress(),
        );

        await expect(
          fractalModule.initialize(owner.address, ethers.ZeroAddress, ethers.ZeroAddress),
        ).to.be.revertedWithCustomError(fractalModule, 'InvalidInitialization');
      });
    });
  });

  describe('Transaction Execution', () => {
    let fractalModule: FractalModuleV1;
    let avatar: MockAvatar;

    beforeEach(async () => {
      avatar = await new MockAvatar__factory(proxyDeployer).deploy();
      fractalModule = await deployFractalModuleProxy(
        proxyDeployer,
        masterCopy,
        owner,
        await avatar.getAddress(),
        await avatar.getAddress(),
      );
      await avatar.enableModule(await fractalModule.getAddress());
    });

    describe('Authorization', () => {
      let target: string;
      let value: bigint;
      let data: string;
      let operation: number;

      beforeEach(async () => {
        await mockToken.mint(await avatar.getAddress(), 1000); // Mint tokens for these tests

        target = await mockToken.getAddress();
        value = 0n;
        data = mockToken.interface.encodeFunctionData('transfer', [user.address, 100]);
        operation = 0;
      });

      it('should allow owner to execute transactions', async () => {
        await mockToken.mint(await avatar.getAddress(), 1000);
        await fractalModule.execTx(target, value, data, operation);
        expect(await mockToken.balanceOf(user.address)).to.equal(100);
      });

      it('should revert with OwnableUnauthorizedAccount for non-owner', async () => {
        await expect(
          fractalModule.connect(user).execTx(target, value, data, operation),
        ).to.be.revertedWithCustomError(fractalModule, 'OwnableUnauthorizedAccount');
      });
    });

    describe('Transaction Success/Failure', () => {
      let target: string;
      let value: bigint;
      let data: string;
      let operation: number;

      beforeEach(async () => {
        target = await mockToken.getAddress();
        value = 0n;
        data = mockToken.interface.encodeFunctionData('transfer', [user.address, 100]);
        operation = 0;
      });

      it('should execute successful transactions', async () => {
        await mockToken.mint(await avatar.getAddress(), 1000);
        await fractalModule.execTx(target, value, data, operation);
        expect(await mockToken.balanceOf(user.address)).to.equal(100);
      });

      it('should revert with TxFailed on failed transactions', async () => {
        // No tokens minted to avatar, so transfer should fail
        target = await mockToken.getAddress();
        value = 0n;
        data = mockToken.interface.encodeFunctionData('transfer', [user.address, 100]);
        operation = 0;

        await expect(
          fractalModule.execTx(target, value, data, operation),
        ).to.be.revertedWithCustomError(fractalModule, 'TxFailed');
      });
    });

    describe('Transaction Data Handling', () => {
      it('should handle transactions with value', async () => {
        // Fund the avatar with ETH
        await owner.sendTransaction({
          to: await avatar.getAddress(),
          value: ethers.parseEther('1.0'),
        });

        const target = user.address;
        const value = ethers.parseEther('0.5');
        const data = '0x';
        const operation = 0;

        const initialBalance = await ethers.provider.getBalance(user.address);
        await fractalModule.execTx(target, value, data, operation);
        const finalBalance = await ethers.provider.getBalance(user.address);

        expect(finalBalance - initialBalance).to.equal(ethers.parseEther('0.5'));
      });

      it('should handle transactions with empty data', async () => {
        const target = user.address;
        const value = 0n;
        const data = '0x';
        const operation = 0;

        await fractalModule.execTx(target, value, data, operation);
      });

      it('should handle transactions with both value and data', async () => {
        // Fund the avatar with ETH and tokens
        await owner.sendTransaction({
          to: await avatar.getAddress(),
          value: ethers.parseEther('1.0'),
        });
        await mockToken.mint(await avatar.getAddress(), 1000);

        // First send ETH to user
        const ethTxTarget = user.address;
        const ethTxValue = ethers.parseEther('0.5');
        const ethTxData = '0x';
        const ethTxOperation = 0;

        // Then do token transfer
        const tokenTxTarget = await mockToken.getAddress();
        const tokenTxValue = 0n;
        const tokenTxData = mockToken.interface.encodeFunctionData('transfer', [user.address, 100]);
        const tokenTxOperation = 0;

        const initialEthBalance = await ethers.provider.getBalance(user.address);

        // Execute both transactions
        await fractalModule.execTx(ethTxTarget, ethTxValue, ethTxData, ethTxOperation);
        await fractalModule.execTx(tokenTxTarget, tokenTxValue, tokenTxData, tokenTxOperation);

        const finalEthBalance = await ethers.provider.getBalance(user.address);

        // Verify both the ETH transfer and token transfer worked
        expect(finalEthBalance - initialEthBalance).to.equal(ethers.parseEther('0.5'));
        expect(await mockToken.balanceOf(user.address)).to.equal(100);
      });
    });
  });

  describe('Version', () => {
    let fractalModule: FractalModuleV1;

    beforeEach(async () => {
      fractalModule = await deployFractalModuleProxy(
        proxyDeployer,
        masterCopy,
        owner,
        ethers.ZeroAddress,
        ethers.ZeroAddress,
      );
    });

    // Use the shared version test utility
    it('should return the correct version number', async () => {
      expect(await fractalModule.version()).to.equal(1);
    });
  });

  describe('ERC165', function () {
    let fractalModuleInstance: FractalModuleV1;
    let iFractalModuleV1InterfaceId: string;
    let iVersionInterfaceId: string;
    let iERC165InterfaceId: string;

    beforeEach(async function () {
      // Deploy a new instance for testing
      fractalModuleInstance = await deployFractalModuleProxy(
        proxyDeployer,
        masterCopy,
        owner,
        ethers.ZeroAddress,
        ethers.ZeroAddress,
      );

      // Dynamically calculate interface IDs
      const IFractalModuleV1Interface = IFractalModuleV1__factory.createInterface();
      iFractalModuleV1InterfaceId = calculateInterfaceId(IFractalModuleV1Interface);

      const IVersionInterface = IVersion__factory.createInterface();
      iVersionInterfaceId = calculateInterfaceId(IVersionInterface);

      const IERC165Interface = IERC165__factory.createInterface();
      iERC165InterfaceId = calculateInterfaceId(IERC165Interface);
    });

    it('Should support IERC165 interface', async function () {
      const supported = await fractalModuleInstance.supportsInterface(iERC165InterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should support IFractalModuleV1 interface', async function () {
      const supported = await fractalModuleInstance.supportsInterface(iFractalModuleV1InterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should support IVersion interface', async function () {
      const supported = await fractalModuleInstance.supportsInterface(iVersionInterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should not support random interface', async function () {
      const randomInterfaceId = '0x12345678';
      const supported = await fractalModuleInstance.supportsInterface(randomInterfaceId);
      void expect(supported).to.be.false;
    });
  });

  describe('UUPS Upgradeability', function () {
    let fractalModule: FractalModuleV1;

    beforeEach(async function () {
      // Deploy fractal module proxy
      fractalModule = await deployFractalModuleProxy(
        proxyDeployer,
        masterCopy,
        owner,
        ethers.ZeroAddress,
        ethers.ZeroAddress,
      );
    });

    // Run UUPS upgradeability tests
    runUUPSUpgradeabilityTests({
      getContract: () => fractalModule as unknown as UUPSUpgradeable,
      createNewImplementation: async () => {
        const newImplementation = await new FractalModuleV1__factory(owner).deploy();
        return newImplementation as unknown as UUPSUpgradeable;
      },
      owner: () => owner,
      nonOwner: () => nonOwner,
    });
  });
});
