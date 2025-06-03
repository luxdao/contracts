import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  ERC1967Proxy__factory,
  HatsProposerAdapterV1,
  HatsProposerAdapterV1__factory,
  IERC165__factory,
  IHatsProposerAdapterV1__factory,
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
      const whitelistedHats = await adapter.whitelistedHatIds();
      expect(whitelistedHats).to.deep.equal([HAT_ID_1]);
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

  describe('version', () => {
    it('should return the correct version', async () => {
      expect(await adapter.version()).to.equal(1n);
    });
  });

  describe('ERC165 supportsInterface', () => {
    it('should support IHatsProposerAdapterV1', async () => {
      void expect(
        await adapter.supportsInterface(
          calculateInterfaceId(IHatsProposerAdapterV1__factory.createInterface(), [
            IProposerAdapterV1__factory.createInterface(),
            IProposerAdapterBaseV1__factory.createInterface(),
          ]),
        ),
      ).to.be.true;
    });

    it('should support IProposerAdapterV1', async () => {
      void expect(
        await adapter.supportsInterface(
          calculateInterfaceId(IProposerAdapterV1__factory.createInterface(), [
            IProposerAdapterBaseV1__factory.createInterface(),
          ]),
        ),
      ).to.be.true;
    });

    it('should support IProposerAdapterBaseV1', async () => {
      void expect(
        await adapter.supportsInterface(
          calculateInterfaceId(IProposerAdapterBaseV1__factory.createInterface()),
        ),
      ).to.be.true;
    });

    it('should support IVersion', async () => {
      void expect(
        await adapter.supportsInterface(calculateInterfaceId(IVersion__factory.createInterface())),
      ).to.be.true;
    });

    it('should support IERC165', async () => {
      void expect(
        await adapter.supportsInterface(calculateInterfaceId(IERC165__factory.createInterface())),
      ).to.be.true;
    });

    it('should not support a random interfaceId', async () => {
      void expect(await adapter.supportsInterface('0x12345678')).to.be.false;
    });
  });
});
