import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  ConcreteSmartAccountValidation,
  ConcreteSmartAccountValidation__factory,
  ERC1967Proxy__factory,
  MockGaslessTarget,
  MockGaslessTarget__factory,
  MockInvalidLightAccount,
  MockInvalidLightAccount__factory,
  MockLightAccount,
  MockLightAccount__factory,
  MockLightAccountFactory,
  MockLightAccountFactory__factory,
} from '../../../typechain-types';

interface PackedUserOperation {
  sender: string;
  nonce: bigint;
  initCode: string;
  callData: string;
  accountGasLimits: string;
  preVerificationGas: bigint;
  gasFees: string;
  paymasterAndData: string;
  signature: string;
}

async function deploySmartAccountValidation(
  deployer: SignerWithAddress,
  implementation: ConcreteSmartAccountValidation,
  mockLightAccountFactoryAddress: string,
) {
  // Create full initialization data with function selector
  const fullInitData = ConcreteSmartAccountValidation__factory.createInterface().encodeFunctionData(
    'initialize',
    [mockLightAccountFactoryAddress],
  );

  // Deploy the proxy with the implementation
  const proxy = await new ERC1967Proxy__factory(deployer).deploy(implementation, fullInitData);

  return ConcreteSmartAccountValidation__factory.connect(await proxy.getAddress(), deployer);
}

describe('SmartAccountValidationV1', function () {
  // contracts
  let concreteSmartAccountValidation: ConcreteSmartAccountValidation;
  let mockLightAccount: MockLightAccount;
  let mockInvalidLightAccount: MockInvalidLightAccount;
  let mockLightAccountFactory: MockLightAccountFactory;

  // signers
  let deployer: SignerWithAddress;
  let owner: SignerWithAddress;

  beforeEach(async function () {
    // Get signers
    [deployer, owner] = await ethers.getSigners();

    // Deploy MockLightAccount
    mockLightAccount = await new MockLightAccount__factory(deployer).deploy(owner.address);

    // Deploy MockInvalidLightAccount
    mockInvalidLightAccount = await new MockInvalidLightAccount__factory(deployer).deploy();

    // Deploy MockLightAccountFactory
    mockLightAccountFactory = await new MockLightAccountFactory__factory(deployer).deploy();

    // Deploy ConcreteSmartAccountValidation
    const concreteValidationImplementation = await new ConcreteSmartAccountValidation__factory(
      deployer,
    ).deploy();

    concreteSmartAccountValidation = await deploySmartAccountValidation(
      deployer,
      concreteValidationImplementation,
      mockLightAccountFactory.target.toString(),
    );
  });

  describe('validateSmartAccount', function () {
    describe('When the smart account is valid', function () {
      it('should return true and the owner address', async function () {
        // set up the mock factory contract to return the correct address to `validateSmartAccount`
        await mockLightAccountFactory.setAccountAddress(
          await mockLightAccount.owner(),
          0n,
          await mockLightAccount.getAddress(),
        );

        const [isValid, lightAccountOwner] =
          await concreteSmartAccountValidation.validateSmartAccountPublic(
            await mockLightAccount.getAddress(),
          );
        void expect(isValid).to.be.true;
        expect(lightAccountOwner).to.equal(await mockLightAccount.owner());
      });
    });

    describe('When the smart account is invalid', function () {
      describe('When the address is not a contract', function () {
        it('should return false and the zero address', async function () {
          const randomAddress = ethers.Wallet.createRandom().address;

          // Should return false since the address won't have the owner() function
          const [isValid, lightAccountOwner] =
            await concreteSmartAccountValidation.validateSmartAccountPublic(randomAddress);
          void expect(isValid).to.be.false;
          expect(lightAccountOwner).to.equal(ethers.ZeroAddress);
        });
      });

      describe('When the address is a contract', function () {
        it('should return false when factory check fails', async function () {
          // not calling "setAccountAddress", so the LightAccountFactory will always
          // return the zero address when calling `getAddress` for a given owner and salt
          // (which is implemented in the SmartAccountValidation validateSmartAccount function).
          const [isValid, lightAccountOwner] =
            await concreteSmartAccountValidation.validateSmartAccountPublic(
              await mockLightAccount.getAddress(),
            );
          void expect(isValid).to.be.false;
          expect(lightAccountOwner).to.equal(await mockLightAccount.owner());
        });

        it('should return false when owner() call reverts', async function () {
          // Hits the "catch" block in the `validateSmartAccount` function
          const [isValid, lightAccountOwner] =
            await concreteSmartAccountValidation.validateSmartAccountPublic(
              await mockInvalidLightAccount.getAddress(),
            );
          void expect(isValid).to.be.false;
          expect(lightAccountOwner).to.equal(ethers.ZeroAddress);
        });
      });
    });
  });

  describe('validateUserOp', function () {
    let mockUserOp: PackedUserOperation;
    let mockTarget: MockGaslessTarget;
    let FOO_SELECTOR: string;
    let expectedInnerCallData: string;

    beforeEach(async function () {
      // Deploy MockGaslessTarget
      mockTarget = await new MockGaslessTarget__factory(deployer).deploy();

      // Get the foo function selector
      FOO_SELECTOR = mockTarget.interface.getFunction('foo').selector;

      // Create mock UserOperation with properly encoded calldata
      expectedInnerCallData = mockTarget.interface.encodeFunctionData('foo', [
        123, // uint32 someNumber
        1, // uint8 someFlag
      ]);

      const executeCalldata = mockLightAccount.interface.encodeFunctionData('execute', [
        await mockTarget.getAddress(),
        0n, // value
        expectedInnerCallData,
      ]);

      mockUserOp = {
        sender: await mockLightAccount.getAddress(),
        nonce: 0n,
        initCode: '0x',
        callData: executeCalldata,
        accountGasLimits: ethers.ZeroHash,
        preVerificationGas: 0n,
        gasFees: ethers.ZeroHash,
        paymasterAndData: '0x',
        signature: '0x',
      };
    });

    it('should return owner, target, and selector for valid UserOps', async function () {
      // Set up the mock factory contract to return the correct address
      await mockLightAccountFactory.setAccountAddress(
        await mockLightAccount.owner(),
        0n,
        await mockLightAccount.getAddress(),
      );

      const [lightAccountOwner, target, returnedInnerCallData] =
        await concreteSmartAccountValidation.validateUserOpPublic(mockUserOp);
      expect(lightAccountOwner).to.equal(await mockLightAccount.owner());
      expect(target).to.equal(await mockTarget.getAddress());
      expect(returnedInnerCallData.slice(0, 10)).to.equal(FOO_SELECTOR);
      expect(returnedInnerCallData).to.equal(expectedInnerCallData);
    });

    it('should revert when the sender is not a valid smart account', async function () {
      // Not setting up the mock factory to return the correct address
      // This will make validateSmartAccount return false, triggering InvalidSmartAccount

      await expect(
        concreteSmartAccountValidation.validateUserOpPublic(mockUserOp),
      ).to.be.revertedWithCustomError(concreteSmartAccountValidation, 'InvalidSmartAccount');
    });

    it('should revert when calldata length is invalid', async function () {
      // Set up the mock factory contract to return the correct address
      await mockLightAccountFactory.setAccountAddress(
        await mockLightAccount.owner(),
        0n,
        await mockLightAccount.getAddress(),
      );

      const invalidCallData = '0x1234'; // Too short
      const invalidUserOp = { ...mockUserOp, callData: invalidCallData };

      await expect(
        concreteSmartAccountValidation.validateUserOpPublic(invalidUserOp),
      ).to.be.revertedWithCustomError(
        concreteSmartAccountValidation,
        'InvalidUserOpCallDataLength',
      );
    });

    it('should revert when the calldata function selector is not authorized', async function () {
      // Set up the mock factory contract to return the correct address
      await mockLightAccountFactory.setAccountAddress(
        await mockLightAccount.owner(),
        0n,
        await mockLightAccount.getAddress(),
      );

      const unauthorizedCallData = ethers.concat([
        '0x99999999',
        ethers.zeroPadValue(await mockTarget.getAddress(), 20),
        '0x',
      ]);

      const unauthorizedUserOp = { ...mockUserOp, callData: unauthorizedCallData };

      await expect(
        concreteSmartAccountValidation.validateUserOpPublic(unauthorizedUserOp),
      ).to.be.revertedWithCustomError(concreteSmartAccountValidation, 'InvalidCallData');
    });

    it('should revert when inner calldata length is invalid', async function () {
      // Set up the mock factory contract to return the correct address
      await mockLightAccountFactory.setAccountAddress(
        await mockLightAccount.owner(),
        0n,
        await mockLightAccount.getAddress(),
      );

      // Create execute calldata with too short inner calldata
      const executeCalldata = mockLightAccount.interface.encodeFunctionData('execute', [
        await mockTarget.getAddress(),
        0n, // value
        '0x12', // inner calldata less than 4 bytes
      ]);

      const userOp = { ...mockUserOp, callData: executeCalldata };

      await expect(
        concreteSmartAccountValidation.validateUserOpPublic(userOp),
      ).to.be.revertedWithCustomError(concreteSmartAccountValidation, 'InvalidInnerCallDataLength');
    });
  });
});
