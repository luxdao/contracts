import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  ERC1967Proxy__factory,
  ERC20ProposerAdapterV1,
  ERC20ProposerAdapterV1__factory,
  IERC165__factory,
  IProposerAdapterBaseV1__factory,
  IProposerAdapterV1__factory,
  IVersion__factory,
  MockERC20Votes,
  MockERC20Votes__factory,
} from '../../../../typechain-types';
import { calculateInterfaceId } from '../../../helpers/utils';

async function deployERC20ProposerAdapterProxy(
  deployer: SignerWithAddress,
  implementationAddress: string,
  tokenAddress: string,
  proposerThreshold: bigint,
  weightPerToken: bigint,
): Promise<ERC20ProposerAdapterV1> {
  const adapterInterface = ERC20ProposerAdapterV1__factory.createInterface();
  const initializeCalldata = adapterInterface.encodeFunctionData('initialize', [
    tokenAddress,
    proposerThreshold,
    weightPerToken,
  ]);
  const proxyFactory = new ERC1967Proxy__factory(deployer);
  const proxy = await proxyFactory.deploy(implementationAddress, initializeCalldata);
  await proxy.waitForDeployment();
  return ERC20ProposerAdapterV1__factory.connect(await proxy.getAddress(), deployer);
}

describe('ERC20ProposerAdapterV1', () => {
  let deployer: SignerWithAddress;
  let user1: SignerWithAddress;

  let adapterImplementation: ERC20ProposerAdapterV1;
  let adapter: ERC20ProposerAdapterV1;
  let mockToken: MockERC20Votes;

  const DEFAULT_PROPOSER_THRESHOLD = ethers.parseUnits('100', 18);
  const DEFAULT_WEIGHT_PER_TOKEN = 1n;

  beforeEach(async () => {
    [deployer, user1] = await ethers.getSigners();

    const mockTokenFactory = new MockERC20Votes__factory(deployer);
    mockToken = await mockTokenFactory.deploy();
    await mockToken.waitForDeployment();

    if (!adapterImplementation) {
      const adapterFactory = new ERC20ProposerAdapterV1__factory(deployer);
      adapterImplementation = await adapterFactory.deploy();
      await adapterImplementation.waitForDeployment();
    }

    adapter = await deployERC20ProposerAdapterProxy(
      deployer,
      await adapterImplementation.getAddress(),
      await mockToken.getAddress(),
      DEFAULT_PROPOSER_THRESHOLD,
      DEFAULT_WEIGHT_PER_TOKEN,
    );
  });

  describe('Initialization (via Proxy)', () => {
    it('should initialize correctly with valid parameters', async () => {
      expect(await adapter.token()).to.equal(await mockToken.getAddress());
      expect(await adapter.proposerThreshold()).to.equal(DEFAULT_PROPOSER_THRESHOLD);
      expect(await adapter.weightPerToken()).to.equal(DEFAULT_WEIGHT_PER_TOKEN);
    });

    it('should revert if token address is zero during proxy initialization', async () => {
      await expect(
        deployERC20ProposerAdapterProxy(
          deployer,
          await adapterImplementation.getAddress(),
          ethers.ZeroAddress,
          DEFAULT_PROPOSER_THRESHOLD,
          DEFAULT_WEIGHT_PER_TOKEN,
        ),
      ).to.be.revertedWithCustomError(adapterImplementation, 'InvalidTokenAddress');
    });

    it('should revert if weightPerToken is zero during proxy initialization', async () => {
      await expect(
        deployERC20ProposerAdapterProxy(
          deployer,
          await adapterImplementation.getAddress(),
          await mockToken.getAddress(),
          DEFAULT_PROPOSER_THRESHOLD,
          0n,
        ),
      ).to.be.revertedWithCustomError(adapterImplementation, 'InvalidWeightPerToken');
    });

    it('should allow proposerThreshold to be zero during proxy initialization', async () => {
      const localAdapter = await deployERC20ProposerAdapterProxy(
        deployer,
        await adapterImplementation.getAddress(),
        await mockToken.getAddress(),
        0n,
        DEFAULT_WEIGHT_PER_TOKEN,
      );
      expect(await localAdapter.proposerThreshold()).to.equal(0n);
    });

    it('should prevent reinitialization on proxied adapter', async () => {
      await expect(
        adapter.initialize(
          await mockToken.getAddress(),
          DEFAULT_PROPOSER_THRESHOLD,
          DEFAULT_WEIGHT_PER_TOKEN,
        ),
      ).to.be.revertedWithCustomError(adapter, 'InvalidInitialization');
    });

    it('Implementation contract should remain uninitialized', async () => {
      await expect(
        adapterImplementation.initialize(
          await mockToken.getAddress(),
          DEFAULT_PROPOSER_THRESHOLD,
          DEFAULT_WEIGHT_PER_TOKEN,
        ),
      ).to.be.revertedWithCustomError(adapterImplementation, 'InvalidInitialization');
    });
  });

  describe('isProposer', () => {
    it('should return true if user meets the proposer threshold', async () => {
      const userVotes = DEFAULT_PROPOSER_THRESHOLD / DEFAULT_WEIGHT_PER_TOKEN;
      await mockToken.connect(deployer).mint(user1.address, userVotes);
      await mockToken.connect(user1).delegate(user1.address);
      const canPropose = await adapter.isProposer(user1.address);
      void expect(canPropose).to.be.true;
    });

    it('should return true if user exceeds the proposer threshold', async () => {
      const userVotes = DEFAULT_PROPOSER_THRESHOLD / DEFAULT_WEIGHT_PER_TOKEN + 1n;
      await mockToken.connect(deployer).mint(user1.address, userVotes);
      await mockToken.connect(user1).delegate(user1.address);
      const canPropose = await adapter.isProposer(user1.address);
      void expect(canPropose).to.be.true;
    });

    it('should return false if user is below the proposer threshold', async () => {
      if (DEFAULT_PROPOSER_THRESHOLD > 0n) {
        const userVotes = DEFAULT_PROPOSER_THRESHOLD / DEFAULT_WEIGHT_PER_TOKEN - 1n;
        if (userVotes > 0) {
          await mockToken.connect(deployer).mint(user1.address, userVotes);
        }
        await mockToken.connect(user1).delegate(user1.address);
      }
      const canPropose = await adapter.isProposer(user1.address);
      void expect(canPropose).to.be.false;
    });

    it('should return false if user has no votes (or token balance)', async () => {
      await mockToken.connect(user1).delegate(user1.address);
      const canPropose = await adapter.isProposer(user1.address);
      void expect(canPropose).to.be.false;
    });

    it('should return true if proposerThreshold is 0, even with zero votes', async () => {
      const localAdapter = await deployERC20ProposerAdapterProxy(
        deployer,
        await adapterImplementation.getAddress(),
        await mockToken.getAddress(),
        0n,
        DEFAULT_WEIGHT_PER_TOKEN,
      );
      await mockToken.connect(user1).delegate(user1.address);
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

      const iProposerAdapterV1Id = calculateInterfaceId(iProposerAdapterV1Interface, [
        iProposerAdapterBaseV1Interface,
      ]);
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
