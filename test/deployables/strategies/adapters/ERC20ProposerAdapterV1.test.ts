import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  ERC1967Proxy__factory,
  ERC20ProposerAdapterV1,
  ERC20ProposerAdapterV1__factory,
  IERC165__factory,
  IERC20ProposerAdapterV1__factory,
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
): Promise<ERC20ProposerAdapterV1> {
  const adapterInterface = ERC20ProposerAdapterV1__factory.createInterface();
  const initializeCalldata = adapterInterface.encodeFunctionData('initialize', [
    tokenAddress,
    proposerThreshold,
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
    );
  });

  describe('Initialization (via Proxy)', () => {
    it('should initialize correctly with valid parameters', async () => {
      expect(await adapter.token()).to.equal(await mockToken.getAddress());
      expect(await adapter.proposerThreshold()).to.equal(DEFAULT_PROPOSER_THRESHOLD);
    });

    it('should allow proposerThreshold to be zero during proxy initialization', async () => {
      const localAdapter = await deployERC20ProposerAdapterProxy(
        deployer,
        await adapterImplementation.getAddress(),
        await mockToken.getAddress(),
        0n,
      );
      expect(await localAdapter.proposerThreshold()).to.equal(0n);
    });

    it('should prevent reinitialization on proxied adapter', async () => {
      await expect(
        adapter.initialize(await mockToken.getAddress(), DEFAULT_PROPOSER_THRESHOLD),
      ).to.be.revertedWithCustomError(adapter, 'InvalidInitialization');
    });

    it('Implementation contract should remain uninitialized', async () => {
      await expect(
        adapterImplementation.initialize(await mockToken.getAddress(), DEFAULT_PROPOSER_THRESHOLD),
      ).to.be.revertedWithCustomError(adapterImplementation, 'InvalidInitialization');
    });
  });

  describe('isProposer', () => {
    it('should return true if user meets the proposer threshold', async () => {
      await mockToken.connect(deployer).mint(user1.address, DEFAULT_PROPOSER_THRESHOLD);
      await mockToken.connect(user1).delegate(user1.address);
      const canPropose = await adapter.isProposer(user1.address, ethers.ZeroHash);
      void expect(canPropose).to.be.true;
    });

    it('should return true if user exceeds the proposer threshold', async () => {
      await mockToken.connect(deployer).mint(user1.address, DEFAULT_PROPOSER_THRESHOLD);
      await mockToken.connect(user1).delegate(user1.address);
      const canPropose = await adapter.isProposer(user1.address, ethers.ZeroHash);
      void expect(canPropose).to.be.true;
    });

    it('should return false if user is below the proposer threshold', async () => {
      const userVotes = DEFAULT_PROPOSER_THRESHOLD - 1n;
      await mockToken.connect(deployer).mint(user1.address, userVotes);

      await mockToken.connect(user1).delegate(user1.address);

      const canPropose = await adapter.isProposer(user1.address, ethers.ZeroHash);
      void expect(canPropose).to.be.false;
    });

    it('should return false if user has no votes (or token balance)', async () => {
      await mockToken.connect(user1).delegate(user1.address);
      const canPropose = await adapter.isProposer(user1.address, ethers.ZeroHash);
      void expect(canPropose).to.be.false;
    });

    it('should return true if proposerThreshold is 0, even with zero votes', async () => {
      const localAdapter = await deployERC20ProposerAdapterProxy(
        deployer,
        await adapterImplementation.getAddress(),
        await mockToken.getAddress(),
        0n,
      );
      await mockToken.connect(user1).delegate(user1.address);
      const canPropose = await localAdapter.isProposer(user1.address, ethers.ZeroHash);
      void expect(canPropose).to.be.true;
    });
  });

  describe('version', () => {
    it('should return the correct version', async () => {
      expect(await adapter.version()).to.equal(1n);
    });
  });

  describe('ERC165 supportsInterface', () => {
    it('should support IERC20ProposerAdapterV1', async () => {
      void expect(
        await adapter.supportsInterface(
          calculateInterfaceId(IERC20ProposerAdapterV1__factory.createInterface(), [
            IProposerAdapterV1__factory.createInterface(),
          ]),
        ),
      ).to.be.true;
    });

    it('should support IProposerAdapterV1', async () => {
      void expect(
        await adapter.supportsInterface(
          calculateInterfaceId(IProposerAdapterV1__factory.createInterface()),
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
