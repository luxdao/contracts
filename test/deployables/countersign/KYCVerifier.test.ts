import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  IERC165__factory,
  IVersion__factory,
  KYCVerifierV1,
  KYCVerifierV1__factory,
  IKYCVerifierV1__factory,
  ERC1967Proxy__factory,
} from '../../../typechain-types';
import { calculateInterfaceId } from '../../helpers/utils';

// Helper function for deploying Countersign instances using ERC1967Proxy
async function deployKYCVerifierProxy(
  proxyDeployer: SignerWithAddress,
  implementation: string,
  decentVerifier: string,
  name: string,
  version: string,
): Promise<KYCVerifierV1> {
  // Create initialization data with function selector
  const fullInitData =
    KYCVerifierV1__factory.createInterface().getFunction('initialize').selector +
    ethers.AbiCoder.defaultAbiCoder()
      .encode(
        [
          'address',
          'string',
          'string',
        ],
        [
          decentVerifier,
          name,
          version,
        ],
      )
      .slice(2);

  // Deploy the proxy with the implementation
  const proxy = await new ERC1967Proxy__factory(proxyDeployer).deploy(implementation, fullInitData);

  // Return a contract instance connected to the proxy
  return KYCVerifierV1__factory.connect(await proxy.getAddress(), proxyDeployer);
}

describe.only('KYCVerifierV1', () => {
  // signers
  let decentVerifier: SignerWithAddress;
  let mockCountersign: SignerWithAddress;
  let investorAlice: SignerWithAddress;
  let investorBob: SignerWithAddress;
  let investorCarol: SignerWithAddress;

  // contracts
  let kycVerifier: KYCVerifierV1;

  beforeEach(async () => {
    // Get signers
    [
      decentVerifier,
      investorAlice,
      investorBob,
      investorCarol,
    ] = await ethers.getSigners();

    // deploy KYC verifier
    const implementation = await new KYCVerifierV1__factory(decentVerifier).deploy();
    kycVerifier = await deployKYCVerifierProxy(
      decentVerifier,
      await implementation.getAddress(),
      decentVerifier.address,
      'KYCVerifier',
      '1',
    );
  });

  describe('Initialization', () => {
    it('should not allow reinitialization', async () => {
      await expect(
        kycVerifier.initialize(
          decentVerifier.address,
          'KYCVerifier',
          '1',
        ),
      ).to.be.revertedWithCustomError(kycVerifier, 'InvalidInitialization');
    });

    it('should return correct verifier', async () => {
      expect(await kycVerifier.verifier()).to.equal(decentVerifier.address);
    });
  });

  describe('Version', () => {
    it('should return the correct version number', async () => {
      expect(await kycVerifier.version()).to.equal(1);
    });
  });

  describe('ERC165', function () {
    // Interface IDs
    let iVersionInterfaceId: string;
    let iKYCVerifierV1InterfaceId: string;
    let iERC165InterfaceId: string;
    beforeEach(async function () {
      // Calculate interface IDs
      const IVersionInterface = IVersion__factory.createInterface();
      iVersionInterfaceId = calculateInterfaceId(IVersionInterface);

      const IKYCVerifierV1Interface = IKYCVerifierV1__factory.createInterface();
      iKYCVerifierV1InterfaceId = calculateInterfaceId(IKYCVerifierV1Interface);

      const IERC165Interface = IERC165__factory.createInterface();
      iERC165InterfaceId = calculateInterfaceId(IERC165Interface);
    });

    it('Should support IERC165 interface', async function () {
      const supported = await kycVerifier.supportsInterface(iERC165InterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should support IKYCVerifierV1 interface', async function () {
      const supported = await kycVerifier.supportsInterface(iKYCVerifierV1InterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should support IVersion interface', async function () {
      const supported = await kycVerifier.supportsInterface(iVersionInterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should not support random interface', async function () {
      const randomInterfaceId = '0x12345678';
      const supported = await kycVerifier.supportsInterface(randomInterfaceId);
      void expect(supported).to.be.false;
    });
  });
});
