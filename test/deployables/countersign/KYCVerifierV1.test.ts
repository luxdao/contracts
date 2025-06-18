import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  ERC1967Proxy__factory,
  IDeploymentBlockV1__factory,
  IERC165__factory,
  IKYCVerifierV1__factory,
  IVersion__factory,
  KYCVerifierV1,
  KYCVerifierV1__factory,
  MockZKMEVerify,
  MockZKMEVerify__factory,
} from '../../../typechain-types';
import { runDeploymentBlockTests } from '../../shared/deploymentBlockTests';
import { runSupportsInterfaceTests } from '../../shared/supportsInterfaceTests';

// Helper function for deploying Countersign instances using ERC1967Proxy
async function deployKYCVerifierProxy(
  proxyDeployer: SignerWithAddress,
  implementation: string,
  zkMeVerify: string,
  cooperator: string,
): Promise<KYCVerifierV1> {
  // Create initialization data with function selector
  const fullInitData = KYCVerifierV1__factory.createInterface().encodeFunctionData('initialize', [
    zkMeVerify,
    cooperator,
  ]);

  // Deploy the proxy with the implementation
  const proxy = await new ERC1967Proxy__factory(proxyDeployer).deploy(implementation, fullInitData);

  // Return a contract instance connected to the proxy
  return KYCVerifierV1__factory.connect(await proxy.getAddress(), proxyDeployer);
}

describe('KYCVerifierV1', () => {
  // signers
  let investorAlice: SignerWithAddress;
  let cooperator: SignerWithAddress;
  let deployer: SignerWithAddress;

  // contracts
  let kycVerifier: KYCVerifierV1;
  let mockZKMEVerify: MockZKMEVerify;

  beforeEach(async () => {
    // Get signers
    [investorAlice, cooperator, deployer] = await ethers.getSigners();

    // deploy mock ZKMEVerify
    mockZKMEVerify = await new MockZKMEVerify__factory(deployer).deploy();

    // deploy KYC verifier
    const implementation = await new KYCVerifierV1__factory(deployer).deploy();
    kycVerifier = await deployKYCVerifierProxy(
      deployer,
      await implementation.getAddress(),
      await mockZKMEVerify.getAddress(),
      cooperator.address,
    );
  });

  describe('Initialization', () => {
    it('should not allow reinitialization', async () => {
      await expect(
        kycVerifier.initialize(await mockZKMEVerify.getAddress(), cooperator.address),
      ).to.be.revertedWithCustomError(kycVerifier, 'InvalidInitialization');
    });

    it('should return correct zkMeVerify', async () => {
      expect(await kycVerifier.zkMeVerify()).to.equal(await mockZKMEVerify.getAddress());
    });

    it('should return correct cooperator', async () => {
      expect(await kycVerifier.cooperator()).to.equal(cooperator.address);
    });
  });

  describe('Version', () => {
    it('should return the correct version number', async () => {
      expect(await kycVerifier.version()).to.equal(1);
    });
  });

  describe('ERC165 supportsInterface', function () {
    runSupportsInterfaceTests({
      getContract: () => kycVerifier,
      supportedInterfaceFactories: [
        IERC165__factory,
        IKYCVerifierV1__factory,
        IVersion__factory,
        IDeploymentBlockV1__factory,
      ],
    });
  });

  describe('Verifications', () => {
    it('should verify if zkMeVerify has approved', async () => {
      await mockZKMEVerify.setApproved(true);
      void expect(await kycVerifier.verify(investorAlice.address)).to.be.true;
    });

    it('should not verify if zkMeVerify has not approved', async () => {
      await mockZKMEVerify.setApproved(false);
      void expect(await kycVerifier.verify(investorAlice.address)).to.be.false;
    });
  });

  describe('Deployment Block', () => {
    runDeploymentBlockTests({
      getContract: () => kycVerifier,
    });
  });
});
