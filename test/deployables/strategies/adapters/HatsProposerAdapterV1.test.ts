import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  ERC1967Proxy__factory,
  HatsProposerAdapterV1,
  HatsProposerAdapterV1__factory,
  IERC165__factory,
  IProposerAdapterBaseV1__factory,
  IProposerAdapterV1__factory,
  IVersion__factory,
  MockHats,
  MockHats__factory,
} from '../../../../typechain-types';
import { calculateInterfaceId } from '../../../helpers/utils';

async function deployHatsProposerAdapterProxy(
  deployer: SignerWithAddress,
  implementationAddress: string,
  hatsContractAddress: string,
  initialWhitelistedHats: bigint[],
): Promise<HatsProposerAdapterV1> {
  const adapterInterface = HatsProposerAdapterV1__factory.createInterface();
  const initializeCalldata = adapterInterface.encodeFunctionData('initialize', [
    hatsContractAddress,
    initialWhitelistedHats,
  ]);
  const proxyFactory = new ERC1967Proxy__factory(deployer);
  const proxy = await proxyFactory.deploy(implementationAddress, initializeCalldata);
  await proxy.waitForDeployment();
  return HatsProposerAdapterV1__factory.connect(await proxy.getAddress(), deployer);
}

describe('HatsProposerAdapterV1', () => {
  let deployer: SignerWithAddress;
  let user1: SignerWithAddress;

  let adapterImplementation: HatsProposerAdapterV1;
  let adapter: HatsProposerAdapterV1;
  let mockHats: MockHats;

  const HAT_ID_1 = 111n;
  const HAT_ID_2 = 222n;

  beforeEach(async () => {
    [deployer, user1] = await ethers.getSigners();

    const mockHatsFactory = new MockHats__factory(deployer);
    mockHats = await mockHatsFactory.deploy();
    await mockHats.waitForDeployment();

    if (!adapterImplementation) {
      const adapterFactory = new HatsProposerAdapterV1__factory(deployer);
      adapterImplementation = await adapterFactory.deploy();
      await adapterImplementation.waitForDeployment();
    }

    // Deploy with a default whitelisted hat for most tests
    adapter = await deployHatsProposerAdapterProxy(
      deployer,
      await adapterImplementation.getAddress(),
      await mockHats.getAddress(),
      [HAT_ID_1],
    );
  });

  describe('Initialization (via Proxy)', () => {
    it('should initialize correctly with valid parameters', async () => {
      expect(await adapter.hatsContract()).to.equal(await mockHats.getAddress());
      const whitelistedHats = await adapter.getWhitelistedHatIds();
      expect(whitelistedHats).to.deep.equal([HAT_ID_1]);
    });

    it('should revert if hats contract address is zero', async () => {
      await expect(
        deployHatsProposerAdapterProxy(
          deployer,
          await adapterImplementation.getAddress(),
          ethers.ZeroAddress,
          [HAT_ID_1],
        ),
      ).to.be.revertedWithCustomError(adapterImplementation, 'MissingHatsContract');
    });

    it('should revert if initialWhitelistedHats is empty', async () => {
      await expect(
        deployHatsProposerAdapterProxy(
          deployer,
          await adapterImplementation.getAddress(),
          await mockHats.getAddress(),
          [],
        ),
      ).to.be.revertedWithCustomError(adapterImplementation, 'NoHatsWhitelisted');
    });

    it('should prevent reinitialization on proxied adapter', async () => {
      await expect(
        adapter.initialize(await mockHats.getAddress(), [HAT_ID_1]),
      ).to.be.revertedWithCustomError(adapter, 'InvalidInitialization');
    });

    it('Implementation contract should remain uninitialized', async () => {
      await expect(
        adapterImplementation.initialize(await mockHats.getAddress(), [HAT_ID_1]),
      ).to.be.revertedWithCustomError(adapterImplementation, 'InvalidInitialization');
    });
  });

  describe('isProposer', () => {
    // Adapter is initialized with HAT_ID_1 in beforeEach

    it('should return true if user wears a whitelisted hat', async () => {
      await mockHats.setWearerStatus(user1.address, HAT_ID_1, true);
      const canPropose = await adapter.isProposer(user1.address);
      void expect(canPropose).to.be.true;
    });

    it('should return false if user does not wear any whitelisted hat', async () => {
      await mockHats.setWearerStatus(user1.address, HAT_ID_1, false);
      await mockHats.setWearerStatus(user1.address, HAT_ID_2, true); // Wears a non-whitelisted hat
      const canPropose = await adapter.isProposer(user1.address);
      void expect(canPropose).to.be.false;
    });

    it('should return false if user wears no hats', async () => {
      const canPropose = await adapter.isProposer(user1.address);
      void expect(canPropose).to.be.false;
    });

    it('should work with multiple whitelisted hats', async () => {
      const localAdapter = await deployHatsProposerAdapterProxy(
        deployer,
        await adapterImplementation.getAddress(),
        await mockHats.getAddress(),
        [HAT_ID_1, HAT_ID_2],
      );
      await mockHats.setWearerStatus(user1.address, HAT_ID_1, false);
      await mockHats.setWearerStatus(user1.address, HAT_ID_2, true); // Wears the second whitelisted hat
      const canPropose = await localAdapter.isProposer(user1.address);
      void expect(canPropose).to.be.true;
    });
  });

  describe('getVersion', () => {
    it('should return the correct version', async () => {
      expect(await adapter.getVersion()).to.equal(1n);
    });
  });

  describe('supportsInterface', () => {
    it('should support IProposerAdapterV1, IProposerAdapterBaseV1, IVersion and IERC165', async () => {
      const iProposerAdapterV1Interface = IProposerAdapterV1__factory.createInterface();
      const iProposerAdapterBaseV1Interface = IProposerAdapterBaseV1__factory.createInterface();
      const iVersionInterface = IVersion__factory.createInterface();
      const iERC165Interface = IERC165__factory.createInterface();

      const iProposerAdapterV1Id = calculateInterfaceId(iProposerAdapterV1Interface);
      const iProposerAdapterBaseV1Id = calculateInterfaceId(iProposerAdapterBaseV1Interface);
      const iVersionId = calculateInterfaceId(iVersionInterface);
      const iERC165Id = calculateInterfaceId(iERC165Interface);

      void expect(await adapter.supportsInterface(iProposerAdapterV1Id)).to.be.true;
      void expect(await adapter.supportsInterface(iProposerAdapterBaseV1Id)).to.be.true;
      void expect(await adapter.supportsInterface(iVersionId)).to.be.true;
      void expect(await adapter.supportsInterface(iERC165Id)).to.be.true;
    });

    it('should not support a random interfaceId', async () => {
      const randomInterfaceId = '0x12345678';
      void expect(await adapter.supportsInterface(randomInterfaceId)).to.be.false;
    });
  });
});
