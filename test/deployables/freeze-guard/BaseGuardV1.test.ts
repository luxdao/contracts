import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  ConcreteBaseGuardV1,
  ConcreteBaseGuardV1__factory,
  IERC165__factory,
  IGuard__factory,
} from '../../../typechain-types';
import { calculateInterfaceId } from '../../helpers/utils';

describe('BaseGuardV1', () => {
  // Signers
  let deployer: SignerWithAddress;

  // Contracts
  let concreteBaseGuard: ConcreteBaseGuardV1;

  beforeEach(async () => {
    [deployer] = await ethers.getSigners();

    // Deploy MockBaseGuardV1
    concreteBaseGuard = await new ConcreteBaseGuardV1__factory(deployer).deploy();
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
      const supported = await concreteBaseGuard.supportsInterface(iERC165InterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should support IGuard interface', async function () {
      const supported = await concreteBaseGuard.supportsInterface(iGuardInterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should not support random interface', async function () {
      const randomInterfaceId = '0x12345678';
      const supported = await concreteBaseGuard.supportsInterface(randomInterfaceId);
      void expect(supported).to.be.false;
    });
  });
});
