import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  DecentAutonomousAdminV1,
  DecentAutonomousAdminV1__factory,
  ERC1967Proxy__factory,
  IDecentAutonomousAdminV1__factory,
  IERC165__factory,
  IVersion__factory,
} from '../../../typechain-types';
import { calculateInterfaceId } from '../../helpers/utils';
import { runUUPSUpgradeabilityTests } from '../../helpers/uupsUpgradeabilityTests';

// Helper function for deploying DecentAutonomousAdminV1 instances using ERC1967Proxy
async function deployDecentAutonomousAdminProxy(
  proxyDeployer: SignerWithAddress,
  implementation: string,
  owner: SignerWithAddress,
): Promise<DecentAutonomousAdminV1> {
  // Create initialization data with function selector
  const fullInitData =
    DecentAutonomousAdminV1__factory.createInterface().getFunction('initialize').selector +
    ethers.AbiCoder.defaultAbiCoder().encode(['address'], [owner.address]).slice(2);

  // Deploy the proxy with the implementation
  const proxy = await new ERC1967Proxy__factory(proxyDeployer).deploy(implementation, fullInitData);

  // Return a contract instance connected to the proxy
  return DecentAutonomousAdminV1__factory.connect(await proxy.getAddress(), owner);
}

describe('DecentAutonomousAdminV1', function () {
  // Signer accounts
  let proxyDeployer: SignerWithAddress;
  let owner: SignerWithAddress;
  let nonOwner: SignerWithAddress;

  // Contract instances
  let decentAutonomousAdmin: DecentAutonomousAdminV1;
  let masterCopy: string;

  beforeEach(async function () {
    // Get signers
    [proxyDeployer, owner, nonOwner] = await ethers.getSigners();

    // Deploy DecentAutonomousAdminV1 implementation
    masterCopy = await (
      await new DecentAutonomousAdminV1__factory(proxyDeployer).deploy()
    ).getAddress();

    // Deploy DecentAutonomousAdminV1 via proxy
    decentAutonomousAdmin = await deployDecentAutonomousAdminProxy(
      proxyDeployer,
      masterCopy,
      owner,
    );
  });

  describe('Initialization', function () {
    it('Should set the owner correctly', async function () {
      expect(await decentAutonomousAdmin.owner()).to.equal(owner.address);
    });

    it('Should not allow reinitialization', async function () {
      await expect(
        decentAutonomousAdmin.initialize(nonOwner.address),
      ).to.be.revertedWithCustomError(decentAutonomousAdmin, 'InvalidInitialization');
    });
  });

  describe('Ownership', function () {
    it('Should allow owner to call owner-only functions', async function () {
      // The transfer ownership function is an example of an owner-only function
      await decentAutonomousAdmin.connect(owner).transferOwnership(nonOwner.address);
      expect(await decentAutonomousAdmin.owner()).to.equal(nonOwner.address);
    });

    it('Should prevent non-owners from calling owner-only functions', async function () {
      await expect(
        decentAutonomousAdmin.connect(nonOwner).transferOwnership(nonOwner.address),
      ).to.be.revertedWithCustomError(decentAutonomousAdmin, 'OwnableUnauthorizedAccount');
    });
  });

  describe('ERC165', function () {
    let iDecentAutonomousAdminV1InterfaceId: string;
    let iVersionInterfaceId: string;
    let iERC165InterfaceId: string;

    beforeEach(async function () {
      // Dynamically calculate interface IDs
      const IDecentAutonomousAdminV1Interface = IDecentAutonomousAdminV1__factory.createInterface();
      iDecentAutonomousAdminV1InterfaceId = calculateInterfaceId(IDecentAutonomousAdminV1Interface);

      const IVersionInterface = IVersion__factory.createInterface();
      iVersionInterfaceId = calculateInterfaceId(IVersionInterface);

      const IERC165Interface = IERC165__factory.createInterface();
      iERC165InterfaceId = calculateInterfaceId(IERC165Interface);
    });

    it('Should support IERC165 interface', async function () {
      const supported = await decentAutonomousAdmin.supportsInterface(iERC165InterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should support IDecentAutonomousAdminV1 interface', async function () {
      const supported = await decentAutonomousAdmin.supportsInterface(
        iDecentAutonomousAdminV1InterfaceId,
      );
      void expect(supported).to.be.true;
    });

    it('Should support IVersion interface', async function () {
      const supported = await decentAutonomousAdmin.supportsInterface(iVersionInterfaceId);
      void expect(supported).to.be.true;
    });

    it('should not support random interface', async function () {
      // Random interface id
      const randomInterfaceId = '0x12345678';

      const supported = await decentAutonomousAdmin.supportsInterface(randomInterfaceId);
      void expect(supported).to.be.false;
    });
  });

  describe('Version', () => {
    it('should return the correct version number', async () => {
      expect(await decentAutonomousAdmin.getVersion()).to.equal(1);
    });
  });

  describe('UUPS Upgradeability', function () {
    runUUPSUpgradeabilityTests({
      getContract: () => decentAutonomousAdmin,
      createNewImplementation: async () => {
        const newImplementation = await new DecentAutonomousAdminV1__factory(owner).deploy();
        return newImplementation;
      },
      owner: () => owner,
      nonOwner: () => nonOwner,
    });
  });
});
