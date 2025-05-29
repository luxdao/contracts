import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  ConcreteBaseFreezeGuardV1,
  ConcreteBaseFreezeGuardV1__factory,
  ERC1967Proxy__factory,
  IERC165__factory,
  IGuard__factory,
} from '../../../typechain-types';
import { calculateInterfaceId } from '../../helpers/utils';
import { runUUPSUpgradeabilityTests } from '../../helpers/uupsUpgradeabilityTests';

/**
 * Deploy a ConcreteBaseFreezeGuardV1 instance using a proxy
 */
async function deployConcreteBaseFreezeGuardProxy(
  proxyDeployer: SignerWithAddress,
  implementation: string,
  owner: SignerWithAddress,
): Promise<ConcreteBaseFreezeGuardV1> {
  // Combine selector and encoded params
  const fullInitData =
    ConcreteBaseFreezeGuardV1__factory.createInterface().getFunction('__BaseFreezeGuardV1_init')
      .selector + ethers.AbiCoder.defaultAbiCoder().encode(['address'], [owner.address]).slice(2);

  // Deploy the proxy with the implementation
  const proxy = await new ERC1967Proxy__factory(proxyDeployer).deploy(implementation, fullInitData);

  // Return a contract instance connected to the proxy
  return ConcreteBaseFreezeGuardV1__factory.connect(await proxy.getAddress(), owner);
}

describe('BaseFreezeGuardV1', () => {
  // Signers
  let proxyDeployer: SignerWithAddress;
  let owner: SignerWithAddress;
  let nonOwner: SignerWithAddress;

  // Contracts
  let concreteBaseFreezeGuard: ConcreteBaseFreezeGuardV1;
  let masterCopy: string;

  beforeEach(async () => {
    [proxyDeployer, owner, nonOwner] = await ethers.getSigners();
    // Deploy MockBaseGuardV1
    concreteBaseFreezeGuard = await new ConcreteBaseFreezeGuardV1__factory(proxyDeployer).deploy();
  });

  describe('ERC165', function () {
    let iGuardInterfaceId: string;
    let iERC165InterfaceId: string;

    beforeEach(async function () {
      // Dynamically calculate interface IDs
      const IGuardInterface = IGuard__factory.createInterface();
      iGuardInterfaceId = calculateInterfaceId(IGuardInterface);

      const IERC165Interface = IERC165__factory.createInterface();
      iERC165InterfaceId = calculateInterfaceId(IERC165Interface);
    });

    it('Should support IERC165 interface', async function () {
      const supported = await concreteBaseFreezeGuard.supportsInterface(iERC165InterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should support IGuard interface', async function () {
      const supported = await concreteBaseFreezeGuard.supportsInterface(iGuardInterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should not support random interface', async function () {
      const randomInterfaceId = '0x12345678';
      const supported = await concreteBaseFreezeGuard.supportsInterface(randomInterfaceId);
      void expect(supported).to.be.false;
    });
  });

  describe('UUPS Upgradeability', function () {
    beforeEach(async function () {
      // Deploy mastercopy
      const implementation = await new ConcreteBaseFreezeGuardV1__factory(proxyDeployer).deploy();
      masterCopy = await implementation.getAddress();

      // Deploy proxy
      concreteBaseFreezeGuard = await deployConcreteBaseFreezeGuardProxy(
        proxyDeployer,
        masterCopy,
        owner,
      );
    });

    // Run UUPS upgradeability tests
    runUUPSUpgradeabilityTests({
      getContract: () => concreteBaseFreezeGuard,
      createNewImplementation: async () => {
        const newImplementation = await new ConcreteBaseFreezeGuardV1__factory(owner).deploy();
        return newImplementation;
      },
      owner: () => owner,
      nonOwner: () => nonOwner,
    });
  });
});
