import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { mine } from '@nomicfoundation/hardhat-network-helpers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
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
import { getModuleProxyFactory } from '../../helpers/globals.test';
import { calculateInterfaceId, calculateProxyAddress } from '../../helpers/utils';

// Helper function for deploying MultisigFreezeGuardV1 instances
async function deployMultisigFreezeGuardProxy(
  multisigFreezeGuardMastercopy: MultisigFreezeGuardV1,
  owner: SignerWithAddress,
  timelockPeriod: number,
  executionPeriod: number,
  freezeVoting: string,
  childGnosisSafe: string,
): Promise<MultisigFreezeGuardV1> {
  const moduleProxyFactory = getModuleProxyFactory();
  const salt = ethers.hexlify(ethers.randomBytes(32));

  const multisigFreezeGuardSetupCalldata =
    MultisigFreezeGuardV1__factory.createInterface().encodeFunctionData('setUp', [
      ethers.AbiCoder.defaultAbiCoder().encode(
        ['uint32', 'uint32', 'address', 'address', 'address'],
        [timelockPeriod, executionPeriod, owner.address, freezeVoting, childGnosisSafe],
      ),
    ]);

  await moduleProxyFactory.deployModule(
    await multisigFreezeGuardMastercopy.getAddress(),
    multisigFreezeGuardSetupCalldata,
    salt,
  );

  const predictedMultisigFreezeGuardAddress = await calculateProxyAddress(
    moduleProxyFactory,
    await multisigFreezeGuardMastercopy.getAddress(),
    multisigFreezeGuardSetupCalldata,
    salt,
  );

  return MultisigFreezeGuardV1__factory.connect(predictedMultisigFreezeGuardAddress, owner);
}

describe('MultisigFreezeGuardV1', () => {
  const Operation = {
    Call: 0,
    DelegateCall: 1,
  };

  // signers
  let owner: SignerWithAddress;
  let user: SignerWithAddress;

  // contracts
  let multisigFreezeGuardMastercopy: MultisigFreezeGuardV1;
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
    [owner, user] = await ethers.getSigners();

    // Deploy mastercopy
    multisigFreezeGuardMastercopy = await new MultisigFreezeGuardV1__factory(owner).deploy();

    // Deploy mock contracts
    mockFreezeVoting = await new MockFreezeVoting__factory(owner).deploy();
    mockSafe = await new MockSafe__factory(owner).deploy();

    // Deploy MultisigFreezeGuard with mock dependencies
    multisigFreezeGuard = await deployMultisigFreezeGuardProxy(
      multisigFreezeGuardMastercopy,
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

      // Deploy proxy and check if event is emitted
      const factoryInstance = getModuleProxyFactory();
      const salt = ethers.hexlify(ethers.randomBytes(32));

      const multisigFreezeGuardSetupCalldata =
        MultisigFreezeGuardV1__factory.createInterface().encodeFunctionData('setUp', [
          ethers.AbiCoder.defaultAbiCoder().encode(
            ['uint32', 'uint32', 'address', 'address', 'address'],
            [
              TIMELOCK_PERIOD,
              EXECUTION_PERIOD,
              owner.address,
              freezeVotingAddress,
              mockSafeAddress,
            ],
          ),
        ]);

      // Calculate the proxy address to use for event filtering
      const predictedAddress = await calculateProxyAddress(
        factoryInstance,
        await multisigFreezeGuardMastercopy.getAddress(),
        multisigFreezeGuardSetupCalldata,
        salt,
      );

      const tx = await factoryInstance.deployModule(
        await multisigFreezeGuardMastercopy.getAddress(),
        multisigFreezeGuardSetupCalldata,
        salt,
      );

      // Connect to the deployed contract
      const deployedGuard = MultisigFreezeGuardV1__factory.connect(predictedAddress, owner);

      // Check event emission
      const receipt = await tx.wait();

      // Filter events from the proxy address after deployment
      const filter = deployedGuard.filters.MultisigFreezeGuardSetup;
      const events = await deployedGuard.queryFilter(
        filter,
        receipt?.blockNumber,
        receipt?.blockNumber,
      );

      expect(events.length).to.equal(1);
      expect(events[0].args[0]).to.equal(await factoryInstance.getAddress()); // creator
      expect(events[0].args[1]).to.equal(owner.address); // owner
      expect(events[0].args[2]).to.equal(freezeVotingAddress); // freezeVoting
      expect(events[0].args[3]).to.equal(mockSafeAddress); // childGnosisSafe
    });

    it('should not allow reinitialization', async () => {
      const setupData = ethers.AbiCoder.defaultAbiCoder().encode(
        ['uint32', 'uint32', 'address', 'address', 'address'],
        [50, 100, user.address, ethers.ZeroAddress, ethers.ZeroAddress],
      );

      await expect(multisigFreezeGuard.setUp(setupData)).to.be.revertedWithCustomError(
        multisigFreezeGuard,
        'InvalidInitialization',
      );
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
});
