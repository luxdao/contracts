import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { mine } from '@nomicfoundation/hardhat-network-helpers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  ERC1967Proxy__factory,
  IERC165__factory,
  IMultisigFreezeGuardV1__factory,
  IVersion__factory,
  MockFreezeVoting,
  MockFreezeVoting__factory,
  MockSafe,
  MockSafe__factory,
  MultisigFreezeGuardV1,
  MultisigFreezeGuardV1__factory,
} from '../../../typechain-types';
import { calculateInterfaceId } from '../../helpers/utils';
import { runUUPSUpgradeabilityTests } from '../../helpers/uupsUpgradeabilityTests';

// Helper function for deploying MultisigFreezeGuardV1 instances using ERC1967Proxy
async function deployMultisigFreezeGuardProxy(
  proxyDeployer: SignerWithAddress,
  implementation: string,
  owner: SignerWithAddress,
  timelockPeriod: number,
  executionPeriod: number,
  freezeVoting: string,
  childGnosisSafe: string,
): Promise<MultisigFreezeGuardV1> {
  // Create initialization data with function selector
  const initializeInterface = MultisigFreezeGuardV1__factory.createInterface();
  const fullInitData = initializeInterface.encodeFunctionData(
    'initialize(uint32,uint32,address,address,address)',
    [timelockPeriod, executionPeriod, owner.address, freezeVoting, childGnosisSafe],
  );

  // Deploy the proxy with the implementation
  const proxy = await new ERC1967Proxy__factory(proxyDeployer).deploy(implementation, fullInitData);

  // Return a contract instance connected to the proxy
  return MultisigFreezeGuardV1__factory.connect(await proxy.getAddress(), owner);
}

describe('MultisigFreezeGuardV1', () => {
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
  let multisigFreezeGuard: MultisigFreezeGuardV1;
  let mockFreezeVoting: MockFreezeVoting;
  let mockSafe: MockSafe;

  // test data
  const mockSignatures = '0x1234';
  const mockSignaturesHash = ethers.keccak256(mockSignatures);

  // constants
  const TIMELOCK_PERIOD = 100;
  const EXECUTION_PERIOD = 200;

  beforeEach(async () => {
    // Get signers
    [proxyDeployer, owner, user, nonOwner] = await ethers.getSigners();

    // Deploy implementation
    const implementation = await new MultisigFreezeGuardV1__factory(proxyDeployer).deploy();
    masterCopy = await implementation.getAddress();

    // Deploy mock contracts
    mockFreezeVoting = await new MockFreezeVoting__factory(owner).deploy();
    mockSafe = await new MockSafe__factory(owner).deploy();

    // Deploy MultisigFreezeGuard with mock dependencies
    multisigFreezeGuard = await deployMultisigFreezeGuardProxy(
      proxyDeployer,
      masterCopy,
      owner,
      TIMELOCK_PERIOD,
      EXECUTION_PERIOD,
      await mockFreezeVoting.getAddress(),
      await mockSafe.getAddress(),
    );
  });

  describe('Initialization', () => {
    it('should initialize with correct parameters', async () => {
      expect(await multisigFreezeGuard.owner()).to.equal(owner.address);
      expect(await multisigFreezeGuard.freezeVoting()).to.equal(
        await mockFreezeVoting.getAddress(),
      );
      expect(await multisigFreezeGuard.childGnosisSafe()).to.equal(await mockSafe.getAddress());
      expect(await multisigFreezeGuard.timelockPeriod()).to.equal(TIMELOCK_PERIOD);
      expect(await multisigFreezeGuard.executionPeriod()).to.equal(EXECUTION_PERIOD);
    });

    it('should emit MultisigFreezeGuardSetup event on initialization', async () => {
      const freezeVotingAddress = await mockFreezeVoting.getAddress();
      const mockSafeAddress = await mockSafe.getAddress();

      // Create initialization data
      const initializeInterface = MultisigFreezeGuardV1__factory.createInterface();
      const fullInitData = initializeInterface.encodeFunctionData(
        'initialize(uint32,uint32,address,address,address)',
        [TIMELOCK_PERIOD, EXECUTION_PERIOD, owner.address, freezeVotingAddress, mockSafeAddress],
      );

      // Deploy the proxy directly
      const proxy = await new ERC1967Proxy__factory(proxyDeployer).deploy(masterCopy, fullInitData);

      const proxyAddress = await proxy.getAddress();

      // Connect to the deployed contract
      const deployedGuard = MultisigFreezeGuardV1__factory.connect(proxyAddress, owner);

      // Check event emission
      const filter = deployedGuard.filters.MultisigFreezeGuardSetup;
      const events = await deployedGuard.queryFilter(filter);

      expect(events.length).to.equal(1);
      expect(events[0].args[0]).to.equal(proxyDeployer.address); // creator
      expect(events[0].args[1]).to.equal(owner.address); // owner
      expect(events[0].args[2]).to.equal(freezeVotingAddress); // freezeVoting
      expect(events[0].args[3]).to.equal(mockSafeAddress); // childGnosisSafe
    });

    it('should not allow reinitialization', async () => {
      await expect(
        multisigFreezeGuard['initialize(uint32,uint32,address,address,address)'](
          50,
          100,
          user.address,
          ethers.ZeroAddress,
          ethers.ZeroAddress,
        ),
      ).to.be.revertedWithCustomError(multisigFreezeGuard, 'InvalidInitialization');
    });

    it('Should have initialization disabled in the implementation', async function () {
      const implementationContract = MultisigFreezeGuardV1__factory.connect(
        masterCopy,
        proxyDeployer,
      );

      await expect(
        implementationContract['initialize(uint32,uint32,address,address,address)'](
          50,
          100,
          owner.address,
          ethers.ZeroAddress,
          ethers.ZeroAddress,
        ),
      ).to.be.revertedWithCustomError(implementationContract, 'InvalidInitialization');
    });
  });

  describe('Period Updates', () => {
    it('should allow owner to update timelock period', async () => {
      const newTimelockPeriod = 150;

      await expect(multisigFreezeGuard.updateTimelockPeriod(newTimelockPeriod))
        .to.emit(multisigFreezeGuard, 'TimelockPeriodUpdated')
        .withArgs(newTimelockPeriod);

      expect(await multisigFreezeGuard.timelockPeriod()).to.equal(newTimelockPeriod);
    });

    it('should allow owner to update execution period', async () => {
      const newExecutionPeriod = 250;

      await expect(multisigFreezeGuard.updateExecutionPeriod(newExecutionPeriod))
        .to.emit(multisigFreezeGuard, 'ExecutionPeriodUpdated')
        .withArgs(newExecutionPeriod);

      expect(await multisigFreezeGuard.executionPeriod()).to.equal(newExecutionPeriod);
    });

    it('should not allow non-owner to update timelock period', async () => {
      await expect(
        multisigFreezeGuard.connect(user).updateTimelockPeriod(150),
      ).to.be.revertedWithCustomError(multisigFreezeGuard, 'OwnableUnauthorizedAccount');
    });

    it('should not allow non-owner to update execution period', async () => {
      await expect(
        multisigFreezeGuard.connect(user).updateExecutionPeriod(250),
      ).to.be.revertedWithCustomError(multisigFreezeGuard, 'OwnableUnauthorizedAccount');
    });
  });

  describe('Transaction Timelocking', () => {
    const to = ethers.ZeroAddress;
    const value = 0;
    const data = '0x';
    const operation = Operation.Call;
    const safeTxGas = 0;
    const baseGas = 0;
    const gasPrice = 0;
    const gasToken = ethers.ZeroAddress;
    const refundReceiver = ethers.ZeroAddress;
    const nonce = 0;

    beforeEach(async () => {
      // Configure mock Safe for valid signature validation
      await mockSafe.setValidSignature(mockSignaturesHash, true);
    });

    it('should timelock a transaction with valid signatures', async () => {
      await expect(
        multisigFreezeGuard.timelockTransaction(
          to,
          value,
          data,
          operation,
          safeTxGas,
          baseGas,
          gasPrice,
          gasToken,
          refundReceiver,
          mockSignatures,
          nonce,
        ),
      )
        .to.emit(multisigFreezeGuard, 'TransactionTimelocked')
        .withArgs(owner.address, ethers.isHexString, mockSignatures);

      // Check that the transaction is now timelocked
      const timelockedBlock =
        await multisigFreezeGuard.getTransactionTimelockedBlock(mockSignaturesHash);
      expect(timelockedBlock).to.not.equal(0);
    });

    it('should not allow timelocking the same signatures twice', async () => {
      // Timelock transaction first time
      await multisigFreezeGuard.timelockTransaction(
        to,
        value,
        data,
        operation,
        safeTxGas,
        baseGas,
        gasPrice,
        gasToken,
        refundReceiver,
        mockSignatures,
        nonce,
      );

      // Try to timelock again with the same signatures
      await expect(
        multisigFreezeGuard.timelockTransaction(
          to,
          value,
          data,
          operation,
          safeTxGas,
          baseGas,
          gasPrice,
          gasToken,
          refundReceiver,
          mockSignatures,
          nonce,
        ),
      ).to.be.revertedWithCustomError(multisigFreezeGuard, 'AlreadyTimelocked');
    });

    it('should revert if signatures are invalid', async () => {
      // Configure mock Safe to reject the signatures
      const invalidSignatures = '0x4321';
      await mockSafe.setValidSignature(ethers.keccak256(invalidSignatures), false);

      await expect(
        multisigFreezeGuard.timelockTransaction(
          to,
          value,
          data,
          operation,
          safeTxGas,
          baseGas,
          gasPrice,
          gasToken,
          refundReceiver,
          invalidSignatures,
          nonce,
        ),
      ).to.be.reverted;
    });
  });

  describe('Transaction Checking', () => {
    const to = ethers.ZeroAddress;
    const value = 0;
    const data = '0x';
    const operation = Operation.Call;
    const safeTxGas = 0;
    const baseGas = 0;
    const gasPrice = 0;
    const gasToken = ethers.ZeroAddress;
    const refundReceiver = ethers.ZeroAddress;
    const nonce = 0;

    beforeEach(async () => {
      // Configure mock Safe for valid signature validation
      await mockSafe.setValidSignature(mockSignaturesHash, true);

      // Timelock a transaction
      await multisigFreezeGuard.timelockTransaction(
        to,
        value,
        data,
        operation,
        safeTxGas,
        baseGas,
        gasPrice,
        gasToken,
        refundReceiver,
        mockSignatures,
        nonce,
      );
    });

    it('should revert if transaction is not timelocked', async () => {
      const unknownSignatures = '0x5678';

      await expect(
        multisigFreezeGuard.checkTransaction(
          to,
          value,
          data,
          operation,
          safeTxGas,
          baseGas,
          gasPrice,
          gasToken,
          refundReceiver,
          unknownSignatures,
          ethers.ZeroAddress,
        ),
      ).to.be.revertedWithCustomError(multisigFreezeGuard, 'NotTimelocked');
    });

    it('should revert if timelock period has not passed', async () => {
      await expect(
        multisigFreezeGuard.checkTransaction(
          to,
          value,
          data,
          operation,
          safeTxGas,
          baseGas,
          gasPrice,
          gasToken,
          refundReceiver,
          mockSignatures,
          ethers.ZeroAddress,
        ),
      ).to.be.revertedWithCustomError(multisigFreezeGuard, 'Timelocked');
    });

    it('should revert if timelock has expired', async () => {
      // Mine blocks to make timelock expire
      await mine(TIMELOCK_PERIOD + EXECUTION_PERIOD + 1);

      await expect(
        multisigFreezeGuard.checkTransaction(
          to,
          value,
          data,
          operation,
          safeTxGas,
          baseGas,
          gasPrice,
          gasToken,
          refundReceiver,
          mockSignatures,
          ethers.ZeroAddress,
        ),
      ).to.be.revertedWithCustomError(multisigFreezeGuard, 'Expired');
    });

    it('should revert if DAO is frozen', async () => {
      // Mine blocks to pass the timelock period
      await mine(TIMELOCK_PERIOD + 1);

      // Set DAO to frozen
      await mockFreezeVoting.setIsFrozen(true);

      await expect(
        multisigFreezeGuard.checkTransaction(
          to,
          value,
          data,
          operation,
          safeTxGas,
          baseGas,
          gasPrice,
          gasToken,
          refundReceiver,
          mockSignatures,
          ethers.ZeroAddress,
        ),
      ).to.be.revertedWithCustomError(multisigFreezeGuard, 'DAOFrozen');
    });

    it('should allow transaction if properly timelocked and DAO not frozen', async () => {
      // Mine blocks to pass the timelock period but not expire
      await mine(TIMELOCK_PERIOD + 1);

      // Set DAO to not frozen
      await mockFreezeVoting.setIsFrozen(false);

      // Should not revert
      await expect(
        multisigFreezeGuard.checkTransaction(
          to,
          value,
          data,
          operation,
          safeTxGas,
          baseGas,
          gasPrice,
          gasToken,
          refundReceiver,
          mockSignatures,
          ethers.ZeroAddress,
        ),
      ).not.to.be.reverted;
    });
  });

  describe('checkAfterExecution', () => {
    it('should not perform any checks after execution', async () => {
      // This function in the contract doesn't do anything, so it should never revert
      await expect(multisigFreezeGuard.checkAfterExecution(ethers.randomBytes(32), true)).not.to.be
        .reverted;
    });
  });

  describe('getTransactionTimelockedBlock', () => {
    it('should return 0 for unknown signatures', async () => {
      const unknownSignatures = ethers.keccak256('0x9999');
      expect(await multisigFreezeGuard.getTransactionTimelockedBlock(unknownSignatures)).to.equal(
        0,
      );
    });

    it('should return correct block number for timelocked signatures', async () => {
      // Configure mock Safe for valid signature validation
      await mockSafe.setValidSignature(mockSignaturesHash, true);

      // Timelock a transaction
      await multisigFreezeGuard.timelockTransaction(
        ethers.ZeroAddress,
        0,
        '0x',
        Operation.Call,
        0,
        0,
        0,
        ethers.ZeroAddress,
        ethers.ZeroAddress,
        mockSignatures,
        0,
      );

      // Get the current block number
      const blockNumber = await ethers.provider.getBlockNumber();

      // Check that the returned block number matches
      expect(await multisigFreezeGuard.getTransactionTimelockedBlock(mockSignaturesHash)).to.equal(
        blockNumber,
      );
    });
  });

  describe('Version', () => {
    // Use the shared version test utility
    it('should return the correct version number', async () => {
      expect(await multisigFreezeGuard.getVersion()).to.equal(1);
    });
  });

  describe('ERC165', function () {
    let iVersionInterfaceId: string;
    let iMultisigFreezeGuardV1InterfaceId: string;
    let iERC165InterfaceId: string;

    beforeEach(async function () {
      // Dynamically calculate interface IDs
      const IVersionInterface = IVersion__factory.createInterface();
      iVersionInterfaceId = calculateInterfaceId(IVersionInterface);

      const IMultisigFreezeGuardV1Interface = IMultisigFreezeGuardV1__factory.createInterface();
      iMultisigFreezeGuardV1InterfaceId = calculateInterfaceId(IMultisigFreezeGuardV1Interface);

      const IERC165Interface = IERC165__factory.createInterface();
      iERC165InterfaceId = calculateInterfaceId(IERC165Interface);
    });

    it('Should support IERC165 interface', async function () {
      const supported = await multisigFreezeGuard.supportsInterface(iERC165InterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should support IVersion interface', async function () {
      const supported = await multisigFreezeGuard.supportsInterface(iVersionInterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should support IMultisigFreezeGuardV1 interface', async function () {
      const supported = await multisigFreezeGuard.supportsInterface(
        iMultisigFreezeGuardV1InterfaceId,
      );
      void expect(supported).to.be.true;
    });

    it('Should not support random interface', async function () {
      const randomInterfaceId = '0x12345678';
      const supported = await multisigFreezeGuard.supportsInterface(randomInterfaceId);
      void expect(supported).to.be.false;
    });
  });

  describe('UUPS Upgradeability', function () {
    runUUPSUpgradeabilityTests({
      getContract: () => multisigFreezeGuard,
      createNewImplementation: async () => {
        const newImplementation = await new MultisigFreezeGuardV1__factory(owner).deploy();
        return newImplementation;
      },
      owner: () => owner,
      nonOwner: () => nonOwner,
    });
  });
});
