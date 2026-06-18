import type { HardhatEthersSigner as SignerWithAddress } from '@nomicfoundation/hardhat-ethers/types';
import { expect } from 'chai';
import {
  ERC1967Proxy__factory,
  FreezeGuardGovernorV1,
  FreezeGuardGovernorV1__factory,
  IDeploymentBlock__factory,
  IERC165__factory,
  IFreezeGuardGovernorV1__factory,
  IFreezeGuardBaseV1__factory,
  IGuard__factory,
  IVersion__factory,
  MockFreezable,
  MockFreezable__factory,
} from '../../../../typechain-types';
import { ethers } from '../../../helpers/network';
import { runDeploymentBlockTests } from '../../shared/deploymentBlockTests';
import { runInitializerEventEmitterTests } from '../../shared/initializerEventEmitterTests';
import { runSupportsInterfaceTests } from '../../shared/supportsInterfaceTests';
import { runUUPSUpgradeabilityTests } from '../../shared/uupsUpgradeabilityTests';

// Helper function for deploying GovernorFreezeGuardV1 instances using ERC1967Proxy
async function deployGovernorFreezeGuardProxy(
  proxyDeployer: SignerWithAddress,
  implementation: string,
  owner: SignerWithAddress,
  freezeVoting: string,
): Promise<FreezeGuardGovernorV1> {
  // Create initialization data with function selector
  const fullInitData = FreezeGuardGovernorV1__factory.createInterface().encodeFunctionData(
    'initialize',
    [owner.address, freezeVoting],
  );

  // Deploy the proxy with the implementation
  const proxy = await new ERC1967Proxy__factory(proxyDeployer).deploy(implementation, fullInitData);

  // Return a contract instance connected to the proxy
  return FreezeGuardGovernorV1__factory.connect(await proxy.getAddress(), owner);
}

describe('FreezeGuardGovernorV1', () => {
  const Operation = {
    Call: 0,
    DelegateCall: 1,
  };

  // signers
  let proxyDeployer: SignerWithAddress;
  let owner: SignerWithAddress;
  let user: SignerWithAddress;
  let nonOwner: SignerWithAddress;

  // contracts
  let masterCopy: string;
  let governorFreezeGuard: FreezeGuardGovernorV1;
  let mockFreezable: MockFreezable;

  beforeEach(async () => {
    // Get signers
    [proxyDeployer, owner, user, nonOwner] = await ethers.getSigners();

    // Deploy implementation
    const implementation = await new FreezeGuardGovernorV1__factory(proxyDeployer).deploy();
    masterCopy = await implementation.getAddress();

    // Deploy mock contracts
    mockFreezable = await new MockFreezable__factory(owner).deploy();
  });

  describe('Initialization', () => {
    it('should initialize with correct owner and freezeVoting address', async () => {
      governorFreezeGuard = await deployGovernorFreezeGuardProxy(
        proxyDeployer,
        masterCopy,
        owner,
        await mockFreezable.getAddress(),
      );

      expect(await governorFreezeGuard.owner()).to.equal(owner.address);
      expect(await governorFreezeGuard.freezable()).to.equal(await mockFreezable.getAddress());
    });

    it('should not allow reinitialization', async () => {
      governorFreezeGuard = await deployGovernorFreezeGuardProxy(
        proxyDeployer,
        masterCopy,
        owner,
        await mockFreezable.getAddress(),
      );

      await expect(
        governorFreezeGuard.initialize(user.address, ethers.ZeroAddress),
      ).to.be.revertedWithCustomError(governorFreezeGuard, 'InvalidInitialization');
    });

    it('Should have initialization disabled in the implementation', async function () {
      const implementationContract = FreezeGuardGovernorV1__factory.connect(
        masterCopy,
        proxyDeployer,
      );

      await expect(
        implementationContract.initialize(owner.address, ethers.ZeroAddress),
      ).to.be.revertedWithCustomError(implementationContract, 'InvalidInitialization');
    });
  });

  describe('Ownership', function () {
    beforeEach(async () => {
      governorFreezeGuard = await deployGovernorFreezeGuardProxy(
        proxyDeployer,
        masterCopy,
        owner,
        await mockFreezable.getAddress(),
      );
    });

    it('Should allow owner to call owner-only functions', async function () {
      // The transfer ownership function is an example of an owner-only function
      await governorFreezeGuard.connect(owner).transferOwnership(user.address);
      await governorFreezeGuard.connect(user).acceptOwnership();
      expect(await governorFreezeGuard.owner()).to.equal(user.address);
    });

    it('Should prevent non-owners from calling owner-only functions', async function () {
      await expect(
        governorFreezeGuard.connect(user).transferOwnership(user.address),
      ).to.be.revertedWithCustomError(governorFreezeGuard, 'OwnableUnauthorizedAccount');
    });
  });

  describe('Transaction Checking', () => {
    beforeEach(async () => {
      // Deploy the guard with the mock freeze voting
      governorFreezeGuard = await deployGovernorFreezeGuardProxy(
        proxyDeployer,
        masterCopy,
        owner,
        await mockFreezable.getAddress(),
      );
    });

    it('should allow transactions when DAO is not frozen', async () => {
      // Set the mock to return false for isFrozen
      await mockFreezable.setIsFrozen(false);

      // Should not revert when checking transaction
      await expect(
        governorFreezeGuard.checkTransaction(
          ethers.ZeroAddress, // to
          0, // value
          '0x', // data
          Operation.Call, // operation
          0, // safeTxGas
          0, // baseGas
          0, // gasPrice
          ethers.ZeroAddress, // gasToken
          ethers.ZeroAddress, // refundReceiver
          '0x', // signatures
          ethers.ZeroAddress, // msgSender
        ),
      ).not.to.be.revert(ethers);
    });

    it('should revert transactions when DAO is frozen', async () => {
      // Set the mock to return true for isFrozen
      await mockFreezable.setIsFrozen(true);

      // Should revert with DAOFrozen
      await expect(
        governorFreezeGuard.checkTransaction(
          ethers.ZeroAddress, // to
          0, // value
          '0x', // data
          Operation.Call, // operation
          0, // safeTxGas
          0, // baseGas
          0, // gasPrice
          ethers.ZeroAddress, // gasToken
          ethers.ZeroAddress, // refundReceiver
          '0x', // signatures
          ethers.ZeroAddress, // msgSender
        ),
      ).to.be.revertedWithCustomError(governorFreezeGuard, 'DAOFrozen');
    });

    it('should not perform any checks after execution', async () => {
      // checkAfterExecution should not revert or do anything
      await expect(governorFreezeGuard.checkAfterExecution(ethers.randomBytes(32), true)).not.to.be
        .revert(ethers);
    });
  });

  describe('Version', () => {
    beforeEach(async () => {
      governorFreezeGuard = await deployGovernorFreezeGuardProxy(
        proxyDeployer,
        masterCopy,
        owner,
        await mockFreezable.getAddress(),
      );
    });

    // Use the shared version test utility
    it('should return the correct version number', async () => {
      expect(await governorFreezeGuard.version()).to.equal(1);
    });
  });

  describe('ERC165 supportsInterface', function () {
    beforeEach(async function () {
      governorFreezeGuard = await deployGovernorFreezeGuardProxy(
        proxyDeployer,
        masterCopy,
        owner,
        await mockFreezable.getAddress(),
      );
    });

    runSupportsInterfaceTests({
      getContract: () => governorFreezeGuard,
      supportedInterfaceFactories: [
        IERC165__factory,
        IVersion__factory,
        {
          factory: IFreezeGuardGovernorV1__factory,
          inheritedFactories: [IFreezeGuardBaseV1__factory, IGuard__factory],
        },
        {
          factory: IFreezeGuardBaseV1__factory,
          inheritedFactories: [IGuard__factory],
        },
        IGuard__factory,
        IDeploymentBlock__factory,
      ],
    });
  });

  describe('GovernorFreezeGuardV1 UUPS Upgradeability', function () {
    beforeEach(async function () {
      // Deploy proxy
      governorFreezeGuard = await deployGovernorFreezeGuardProxy(
        proxyDeployer,
        masterCopy,
        owner,
        await mockFreezable.getAddress(),
      );
    });

    // Run UUPS upgradeability tests
    runUUPSUpgradeabilityTests({
      getContract: () => governorFreezeGuard,
      createNewImplementation: async () => {
        const newImplementation = await new FreezeGuardGovernorV1__factory(owner).deploy();
        return newImplementation;
      },
      owner: () => owner,
      nonOwner: () => nonOwner,
    });
  });

  describe('Deployment Block', () => {
    beforeEach(async function () {
      governorFreezeGuard = await deployGovernorFreezeGuardProxy(
        proxyDeployer,
        masterCopy,
        owner,
        await mockFreezable.getAddress(),
      );
    });

    runDeploymentBlockTests({
      getContract: () => governorFreezeGuard,
    });
  });

  describe('InitializerEventEmitter', () => {
    runInitializerEventEmitterTests({
      contractFactory: FreezeGuardGovernorV1__factory,
      masterCopy: () => masterCopy,
      deployer: () => proxyDeployer,
      initializeParams: async () => [owner.address, await mockFreezable.getAddress()],
      getExpectedInitData: async () =>
        ethers.AbiCoder.defaultAbiCoder().encode(
          ['address', 'address'],
          [owner.address, await mockFreezable.getAddress()],
        ),
    });
  });
});
