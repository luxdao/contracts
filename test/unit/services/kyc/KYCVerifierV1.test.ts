import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  IDeploymentBlock__factory,
  IERC165__factory,
  IKYCVerifierV1__factory,
  IVersion__factory,
  KYCVerifierV1,
  KYCVerifierV1__factory,
} from '../../../../typechain-types';
import { runDeploymentBlockTests } from '../../shared/deploymentBlockTests';
import { runSupportsInterfaceTests } from '../../shared/supportsInterfaceTests';

describe('KYCVerifierV1', () => {
  // signers
  let alice: SignerWithAddress;
  let verifier: SignerWithAddress;
  let deployer: SignerWithAddress;
  let mockOperatingContract: SignerWithAddress;

  // contracts
  let kycVerifier: KYCVerifierV1;

  beforeEach(async () => {
    // Get signers
    [alice, verifier, deployer, mockOperatingContract] = await ethers.getSigners();

    // deploy KYC verifier
    kycVerifier = await new KYCVerifierV1__factory(deployer).deploy(verifier.address);
  });

  describe('Verifications', () => {
    it('should return true when the signature is valid', async () => {
      const domain = {
        name: 'KYCVerifier',
        version: '1',
        chainId: await ethers.provider.getNetwork().then(n => n.chainId),
        verifyingContract: await kycVerifier.getAddress(),
      };

      const types = {
        VerificationData: [
          { name: 'operatingContract', type: 'address' },
          { name: 'account', type: 'address' },
        ],
      };

      const verificationMessage = {
        operatingContract: mockOperatingContract.address,
        account: alice.address,
      };

      const verifyingSignature = await verifier.signTypedData(domain, types, verificationMessage);

      expect(
        await kycVerifier.verify(mockOperatingContract.address, alice.address, verifyingSignature),
      ).to.be.true;
    });

    it('should return false when the signature is invalid', async () => {
      const domain = {
        name: 'KYCVerifier',
        version: '1',
        chainId: await ethers.provider.getNetwork().then(n => n.chainId),
        verifyingContract: await kycVerifier.getAddress(),
      };

      const types = {
        VerificationData: [
          { name: 'operatingContract', type: 'address' },
          { name: 'account', type: 'address' },
        ],
      };

      const verificationMessage = {
        operatingContract: mockOperatingContract.address,
        account: alice.address,
      };

      // invalid signature - message is signed by Alice rather than the verifier
      const verifyingSignature = await alice.signTypedData(domain, types, verificationMessage);

      expect(
        await kycVerifier.verify(mockOperatingContract.address, alice.address, verifyingSignature),
      ).to.be.false;
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
        IDeploymentBlock__factory,
      ],
    });
  });

  describe('Deployment Block', () => {
    runDeploymentBlockTests({
      getContract: () => kycVerifier,
    });
  });
});
