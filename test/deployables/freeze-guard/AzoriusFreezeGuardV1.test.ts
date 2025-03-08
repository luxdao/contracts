import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  AzoriusFreezeGuardV1,
  AzoriusFreezeGuardV1__factory,
  MockFreezeVoting,
  MockFreezeVoting__factory,
} from '../../../typechain-types';
import { getModuleProxyFactory } from '../../helpers/globals.test';
import { calculateProxyAddress } from '../../helpers/utils';

// Helper function for deploying AzoriusFreezeGuardV1 instances
async function deployAzoriusFreezeGuardProxy(
  azoriusFreezeGuardMastercopy: AzoriusFreezeGuardV1,
  owner: SignerWithAddress,
  freezeVoting: string,
): Promise<AzoriusFreezeGuardV1> {
  const moduleProxyFactory = getModuleProxyFactory();
  const salt = ethers.hexlify(ethers.randomBytes(32));

  const azoriusFreezeGuardSetupCalldata =
    AzoriusFreezeGuardV1__factory.createInterface().encodeFunctionData('setUp', [
      ethers.AbiCoder.defaultAbiCoder().encode(
        ['address', 'address'],
        [owner.address, freezeVoting],
      ),
    ]);

  await moduleProxyFactory.deployModule(
    await azoriusFreezeGuardMastercopy.getAddress(),
    azoriusFreezeGuardSetupCalldata,
    salt,
  );

  const predictedAzoriusFreezeGuardAddress = await calculateProxyAddress(
    moduleProxyFactory,
    await azoriusFreezeGuardMastercopy.getAddress(),
    azoriusFreezeGuardSetupCalldata,
    salt,
  );

  return AzoriusFreezeGuardV1__factory.connect(predictedAzoriusFreezeGuardAddress, owner);
}

describe('AzoriusFreezeGuardV1', () => {
  const Operation = {
    Call: 0,
    DelegateCall: 1,
  };

  // signers
  let owner: SignerWithAddress;
  let user: SignerWithAddress;

  // contracts
  let azoriusFreezeGuardMastercopy: AzoriusFreezeGuardV1;
  let azoriusFreezeGuard: AzoriusFreezeGuardV1;
  let mockFreezeVoting: MockFreezeVoting;

  beforeEach(async () => {
    // Get signers
    [owner, user] = await ethers.getSigners();

    // Deploy mastercopy
    azoriusFreezeGuardMastercopy = await new AzoriusFreezeGuardV1__factory(owner).deploy();

    // Deploy mock contracts
    mockFreezeVoting = await new MockFreezeVoting__factory(owner).deploy();
  });

  describe('Initialization', () => {
    it('should initialize with correct owner and freezeVoting address', async () => {
      azoriusFreezeGuard = await deployAzoriusFreezeGuardProxy(
        azoriusFreezeGuardMastercopy,
        owner,
        await mockFreezeVoting.getAddress(),
      );

      expect(await azoriusFreezeGuard.owner()).to.equal(owner.address);
      expect(await azoriusFreezeGuard.freezeVoting()).to.equal(await mockFreezeVoting.getAddress());
    });

    it('should emit AzoriusFreezeGuardSetUp event on initialization', async () => {
      const freezeVotingAddress = await mockFreezeVoting.getAddress();

      // Deploy proxy and check if event is emitted
      const factoryInstance = getModuleProxyFactory();
      const salt = ethers.hexlify(ethers.randomBytes(32));

      const azoriusFreezeGuardSetupCalldata =
        AzoriusFreezeGuardV1__factory.createInterface().encodeFunctionData('setUp', [
          ethers.AbiCoder.defaultAbiCoder().encode(
            ['address', 'address'],
            [owner.address, freezeVotingAddress],
          ),
        ]);

      // Calculate the proxy address to use for event filtering
      const predictedAddress = await calculateProxyAddress(
        factoryInstance,
        await azoriusFreezeGuardMastercopy.getAddress(),
        azoriusFreezeGuardSetupCalldata,
        salt,
      );

      const tx = await factoryInstance.deployModule(
        await azoriusFreezeGuardMastercopy.getAddress(),
        azoriusFreezeGuardSetupCalldata,
        salt,
      );

      // Connect to the deployed contract
      const deployedGuard = AzoriusFreezeGuardV1__factory.connect(predictedAddress, owner);

      // Check event emission
      const receipt = await tx.wait();

      // Filter events from the proxy address after deployment
      const filter = deployedGuard.filters.AzoriusFreezeGuardSetUp;
      const events = await deployedGuard.queryFilter(
        filter,
        receipt?.blockNumber,
        receipt?.blockNumber,
      );

      expect(events.length).to.equal(1);
      expect(events[0].args[0]).to.equal(await factoryInstance.getAddress()); // creator
      expect(events[0].args[1]).to.equal(owner.address); // owner
      expect(events[0].args[2]).to.equal(freezeVotingAddress); // freezeVoting
    });

    it('should not allow reinitialization', async () => {
      azoriusFreezeGuard = await deployAzoriusFreezeGuardProxy(
        azoriusFreezeGuardMastercopy,
        owner,
        await mockFreezeVoting.getAddress(),
      );

      const setupData = ethers.AbiCoder.defaultAbiCoder().encode(
        ['address', 'address'],
        [user.address, ethers.ZeroAddress],
      );

      await expect(azoriusFreezeGuard.setUp(setupData)).to.be.revertedWithCustomError(
        azoriusFreezeGuard,
        'InvalidInitialization',
      );
    });
  });

  describe('Transaction Checking', () => {
    beforeEach(async () => {
      // Deploy the guard with the mock freeze voting
      azoriusFreezeGuard = await deployAzoriusFreezeGuardProxy(
        azoriusFreezeGuardMastercopy,
        owner,
        await mockFreezeVoting.getAddress(),
      );
    });

    it('should allow transactions when DAO is not frozen', async () => {
      // Set the mock to return false for isFrozen
      await mockFreezeVoting.setIsFrozen(false);

      // Should not revert when checking transaction
      await expect(
        azoriusFreezeGuard.checkTransaction(
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
      ).not.to.be.reverted;
    });

    it('should revert transactions when DAO is frozen', async () => {
      // Set the mock to return true for isFrozen
      await mockFreezeVoting.setIsFrozen(true);

      // Should revert with DAOFrozen
      await expect(
        azoriusFreezeGuard.checkTransaction(
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
      ).to.be.revertedWithCustomError(azoriusFreezeGuard, 'DAOFrozen');
    });

    it('should not perform any checks after execution', async () => {
      // checkAfterExecution should not revert or do anything
      await expect(azoriusFreezeGuard.checkAfterExecution(ethers.randomBytes(32), true)).not.to.be
        .reverted;
    });
  });

  describe('Version', () => {
    beforeEach(async () => {
      azoriusFreezeGuard = await deployAzoriusFreezeGuardProxy(
        azoriusFreezeGuardMastercopy,
        owner,
        await mockFreezeVoting.getAddress(),
      );
    });

    it('should return correct version', async () => {
      expect(await azoriusFreezeGuard.getVersion()).to.equal(1);
    });
  });
});
