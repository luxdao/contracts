import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  ConcreteLightAccountValidator,
  ConcreteLightAccountValidator__factory,
  ERC1967Proxy__factory,
  MockGaslessTarget,
  MockGaslessTarget__factory,
  MockInvalidLightAccount,
  MockInvalidLightAccount__factory,
  MockLightAccount,
  MockLightAccount__factory,
  MockLightAccountFactory,
  MockLightAccountFactory__factory,
} from '../../../../typechain-types';

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

async function deployLightAccountValidator(
  deployer: SignerWithAddress,
  implementation: ConcreteLightAccountValidator,
  mockLightAccountFactoryAddress: string,
) {
  // Create full initialization data with function selector
  const fullInitData = ConcreteLightAccountValidator__factory.createInterface().encodeFunctionData(
    'initialize',
    [mockLightAccountFactoryAddress],
  );

  // Deploy the proxy with the implementation
  const proxy = await new ERC1967Proxy__factory(deployer).deploy(implementation, fullInitData);

  return ConcreteLightAccountValidator__factory.connect(await proxy.getAddress(), deployer);
}

describe('LightAccountValidatorV1', function () {
  // contracts
  let concreteLightAccountValidator: ConcreteLightAccountValidator;
  let mockLightAccount: MockLightAccount;
  let mockInvalidLightAccount: MockInvalidLightAccount;
  let mockLightAccountFactory: MockLightAccountFactory;

  // signers
  let deployer: SignerWithAddress;
  let owner: SignerWithAddress;
  let user: SignerWithAddress;

  beforeEach(async function () {
    // Get signers
    [deployer, owner, user] = await ethers.getSigners();

    // Deploy MockLightAccount
    mockLightAccount = await new MockLightAccount__factory(deployer).deploy(owner.address);

    // Deploy MockInvalidLightAccount
    mockInvalidLightAccount = await new MockInvalidLightAccount__factory(deployer).deploy();

    // Deploy MockLightAccountFactory
    mockLightAccountFactory = await new MockLightAccountFactory__factory(deployer).deploy();

    // Deploy ConcreteSmartAccountValidation
    const concreteValidationImplementation = await new ConcreteLightAccountValidator__factory(
      deployer,
    ).deploy();

    concreteLightAccountValidator = await deployLightAccountValidator(
      deployer,
      concreteValidationImplementation,
      mockLightAccountFactory.target.toString(),
    );
  });

  describe('validateLightAccount', function () {
    describe('When the light account is valid', function () {
      it('should return true and the owner address', async function () {
        // set up the mock factory contract to return the correct address to `validateSmartAccount`
        await mockLightAccountFactory.setAccountAddress(
          await mockLightAccount.owner(),
          0n,
          await mockLightAccount.getAddress(),
        );

        const [isValid, lightAccountOwner] =
          await concreteLightAccountValidator.validateLightAccountPublic(
            await mockLightAccount.getAddress(),
          );
        void expect(isValid).to.be.true;
        expect(lightAccountOwner).to.equal(await mockLightAccount.owner());
      });
    });

    describe('When the light account is invalid', function () {
      describe('When the address is not a contract', function () {
        it('should return false and the zero address', async function () {
          const randomAddress = ethers.Wallet.createRandom().address;

          // Should return false since the address won't have the owner() function
          const [isValid, lightAccountOwner] =
            await concreteLightAccountValidator.validateLightAccountPublic(randomAddress);
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
            await concreteLightAccountValidator.validateLightAccountPublic(
              await mockLightAccount.getAddress(),
            );
          void expect(isValid).to.be.false;
          expect(lightAccountOwner).to.equal(await mockLightAccount.owner());
        });

        it('should return false when owner() call reverts', async function () {
          // Hits the "catch" block in the `validateSmartAccount` function
          const [isValid, lightAccountOwner] =
            await concreteLightAccountValidator.validateLightAccountPublic(
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
        await concreteLightAccountValidator.validateUserOpPublic(mockUserOp);
      expect(lightAccountOwner).to.equal(await mockLightAccount.owner());
      expect(target).to.equal(await mockTarget.getAddress());
      expect(returnedInnerCallData.slice(0, 10)).to.equal(FOO_SELECTOR);
      expect(returnedInnerCallData).to.equal(expectedInnerCallData);
    });

    it('should revert when the sender is not a valid light account', async function () {
      // Not setting up the mock factory to return the correct address
      // This will make validateSmartAccount return false, triggering InvalidSmartAccount

      await expect(
        concreteLightAccountValidator.validateUserOpPublic(mockUserOp),
      ).to.be.revertedWithCustomError(concreteLightAccountValidator, 'InvalidLightAccount');
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
        concreteLightAccountValidator.validateUserOpPublic(invalidUserOp),
      ).to.be.revertedWithCustomError(concreteLightAccountValidator, 'InvalidUserOpCallDataLength');
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
        concreteLightAccountValidator.validateUserOpPublic(unauthorizedUserOp),
      ).to.be.revertedWithCustomError(concreteLightAccountValidator, 'InvalidCallData');
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
        concreteLightAccountValidator.validateUserOpPublic(userOp),
      ).to.be.revertedWithCustomError(concreteLightAccountValidator, 'InvalidInnerCallDataLength');
    });
  });

  describe('lightAccountOwner', () => {
    // Set up the mock light account factory to return our mock account
    beforeEach(async function () {
      await mockLightAccountFactory.setAccountAddress(
        await mockLightAccount.owner(),
        0n,
        await mockLightAccount.getAddress(),
      );
    });

    describe('light accounts', function () {
      it('should return the owner of the light account', async () => {
        // Test with our mock ownership contract
        const lightAccountOwner =
          await concreteLightAccountValidator.potentialLightAccountResolvedOwner(
            await mockLightAccount.getAddress(),
          );
        expect(lightAccountOwner).to.equal(owner.address);
      });
    });

    describe('non-light accounts', function () {
      describe('when the msgSender is an EOA', () => {
        it('should return the msgSender', async () => {
          // For EOAs, the voter function should just return the address itself
          const eoaAddress = user.address;
          const voter =
            await concreteLightAccountValidator.potentialLightAccountResolvedOwner(eoaAddress);
          expect(voter).to.equal(eoaAddress);
        });
      });

      describe('when the msgSender is a contract that does not implement IOwnership', () => {
        it('should return the contract address', async () => {
          // Use the ConcreteLightAccountValidator contract itself as a contract that doesn't implement IOwnership
          const contractAddress = await concreteLightAccountValidator.getAddress();
          const voter =
            await concreteLightAccountValidator.potentialLightAccountResolvedOwner(contractAddress);
          expect(voter).to.equal(contractAddress);
        });
      });
    });
  });
});
