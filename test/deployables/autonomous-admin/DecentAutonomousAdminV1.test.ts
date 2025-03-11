import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  DecentAutonomousAdminV1,
  DecentAutonomousAdminV1__factory,
  IDecentAutonomousAdminV1__factory,
  IERC165__factory,
  IVersion__factory,
} from '../../../typechain-types';
import { calculateInterfaceId } from '../../helpers/utils';

describe('DecentAutonomousAdminV1', function () {
  // Signer accounts
  let deployer: SignerWithAddress;

  // Contract instance
  let decentAutonomousAdminInstance: DecentAutonomousAdminV1;

  beforeEach(async function () {
    // Get signers
    [deployer] = await ethers.getSigners();

    // Deploy DecentAutonomousAdminV1 contract
    decentAutonomousAdminInstance = await new DecentAutonomousAdminV1__factory(deployer).deploy();
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
      const supported = await decentAutonomousAdminInstance.supportsInterface(iERC165InterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should support IDecentAutonomousAdminV1 interface', async function () {
      const supported = await decentAutonomousAdminInstance.supportsInterface(
        iDecentAutonomousAdminV1InterfaceId,
      );
      void expect(supported).to.be.true;
    });

    it('Should support IVersion interface', async function () {
      const supported = await decentAutonomousAdminInstance.supportsInterface(iVersionInterfaceId);
      void expect(supported).to.be.true;
    });

    it('should not support random interface', async function () {
      // Random interface id
      const randomInterfaceId = '0x12345678';

      const supported = await decentAutonomousAdminInstance.supportsInterface(randomInterfaceId);
      void expect(supported).to.be.false;
    });
  });

  describe('Version', () => {
    it('should return the correct version number', async () => {
      expect(await decentAutonomousAdminInstance.getVersion()).to.equal(1);
    });
  });
});
