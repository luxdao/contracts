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
  let investorAlice: SignerWithAddress;
  let deployer: SignerWithAddress;

  // contracts
  let kycVerifier: KYCVerifierV1;

  beforeEach(async () => {
    // Get signers
    [investorAlice, deployer] = await ethers.getSigners();

    // deploy KYC verifier
    kycVerifier = await new KYCVerifierV1__factory(deployer).deploy();
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

  describe('Verifications', () => {
    it('should verify', async () => {
      expect(await kycVerifier.verify(investorAlice.address)).to.be.true;
    });
  });

  describe('Deployment Block', () => {
    runDeploymentBlockTests({
      getContract: () => kycVerifier,
    });
  });
});
