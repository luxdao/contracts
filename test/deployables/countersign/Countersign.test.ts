import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { time } from '@nomicfoundation/hardhat-network-helpers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  CountersignV1,
  CountersignV1__factory,
  ERC1967Proxy__factory,
  ICountersignV1__factory,
  IERC165__factory,
  IVersion__factory,
  MockERC20Votes,
  MockERC20Votes__factory,
  MockKYCVerifier,
  MockKYCVerifier__factory,
  MultiSend,
  MultiSend__factory,
} from '../../../typechain-types';
import { calculateInterfaceId } from '../../helpers/utils';

// Helper function for deploying Countersign instances using ERC1967Proxy
async function deployCountersignProxy(
  proxyDeployer: SignerWithAddress,
  implementation: string,
  owner: string,
  agreementUri: string,
  verificationContract: string,
  signingDeadline: bigint,
  executionDeadline: bigint,
  multisend: string,
  minWeight: bigint,
  preExecutionTransactions: any,
  signerInitializations: any[],
): Promise<CountersignV1> {
  // Create initialization data with function selector

  const fullInitData = CountersignV1__factory.createInterface().encodeFunctionData('initialize', [
    owner,
    agreementUri,
    verificationContract,
    signingDeadline,
    executionDeadline,
    multisend,
    minWeight,
    preExecutionTransactions,
    signerInitializations,
  ]);

  // Deploy the proxy with the implementation
  const proxy = await new ERC1967Proxy__factory(proxyDeployer).deploy(implementation, fullInitData);

  // Return a contract instance connected to the proxy
  return CountersignV1__factory.connect(await proxy.getAddress(), proxyDeployer);
}

describe('CountersignV1', () => {
  // signers
  let founder: SignerWithAddress;
  let investorAlice: SignerWithAddress;
  let investorBob: SignerWithAddress;
  let investorCarol: SignerWithAddress;
  let anon: SignerWithAddress;
  let mockDAOTreasury: SignerWithAddress;

  // contracts
  let countersign: CountersignV1;
  let daoToken: MockERC20Votes;
  let usdc: MockERC20Votes;
  let mockKYCVerifier: MockKYCVerifier;
  let multisend: MultiSend;

  let signingDeadline: bigint;
  let executionDeadline: bigint;

  const agreementUri = 'ipfs://the-agreement-uri';

  beforeEach(async () => {
    // Get signers
    [founder, investorAlice, investorBob, investorCarol, anon, mockDAOTreasury] =
      await ethers.getSigners();

    // deploy tokens
    daoToken = await new MockERC20Votes__factory(founder).deploy();
    usdc = await new MockERC20Votes__factory(founder).deploy();

    // deploy mock contracts
    mockKYCVerifier = await new MockKYCVerifier__factory(founder).deploy();
    multisend = await new MultiSend__factory(founder).deploy();

    // mint Alice 100 USDC
    await usdc.mint(investorAlice.address, ethers.parseEther('100'));

    // mint Bob 50 USDC
    await usdc.mint(investorBob.address, ethers.parseEther('50'));

    // mint Carol 10 USDC
    await usdc.mint(investorCarol.address, ethers.parseEther('10'));

    // preExecution transaction mints 200,000 DAO tokens into DAO treasury
    const preExecutionTransactions = ethers.solidityPacked(
      ['uint8', 'address', 'uint256', 'uint256', 'bytes'],
      [
        0, // operation: CALL
        await daoToken.getAddress(),
        0, // value: 0 ETH
        ethers.dataLength(
          daoToken.interface.encodeFunctionData('mint', [
            mockDAOTreasury.address,
            ethers.parseEther('200000'),
          ]),
        ),
        daoToken.interface.encodeFunctionData('mint', [
          mockDAOTreasury.address,
          ethers.parseEther('200000'),
        ]),
      ],
    );

    // create signer transactions array
    const signerInitializations = [
      {
        account: founder.address,
        required: true,
        weight: 0,
        transactions: '0x', // founder: empty bytes
      },
      {
        account: investorAlice.address,
        required: true,
        weight: ethers.parseEther('100'),
        transactions: ethers.concat([
          // First transaction: USDC transfer
          ethers.solidityPacked(
            ['uint8', 'address', 'uint256', 'uint256', 'bytes'],
            [
              0, // operation: CALL
              await usdc.getAddress(),
              0, // value: 0 ETH
              ethers.dataLength(
                usdc.interface.encodeFunctionData('transferFrom', [
                  investorAlice.address,
                  mockDAOTreasury.address,
                  ethers.parseEther('100'), // 100 USDC
                ]),
              ),
              usdc.interface.encodeFunctionData('transferFrom', [
                investorAlice.address,
                mockDAOTreasury.address,
                ethers.parseEther('100'), // 100 USDC
              ]),
            ],
          ),
          // Second transaction: DAO token transfer
          ethers.solidityPacked(
            ['uint8', 'address', 'uint256', 'uint256', 'bytes'],
            [
              0, // operation: CALL
              await daoToken.getAddress(),
              0, // value: 0 ETH
              ethers.dataLength(
                daoToken.interface.encodeFunctionData('transferFrom', [
                  mockDAOTreasury.address,
                  investorAlice.address,
                  ethers.parseEther('100000'), // 100,000 daoToken
                ]),
              ),
              daoToken.interface.encodeFunctionData('transferFrom', [
                mockDAOTreasury.address,
                investorAlice.address,
                ethers.parseEther('100000'), // 100,000 daoToken
              ]),
            ],
          ),
        ]),
      },
      {
        account: investorBob.address,
        required: false,
        weight: ethers.parseEther('50'),
        transactions: ethers.concat([
          // First transaction: USDC transfer
          ethers.solidityPacked(
            ['uint8', 'address', 'uint256', 'uint256', 'bytes'],
            [
              0, // operation: CALL
              await usdc.getAddress(),
              0, // value: 0 ETH
              ethers.dataLength(
                usdc.interface.encodeFunctionData('transferFrom', [
                  investorBob.address,
                  mockDAOTreasury.address,
                  ethers.parseEther('50'), // 50 USDC
                ]),
              ),
              usdc.interface.encodeFunctionData('transferFrom', [
                investorBob.address,
                mockDAOTreasury.address,
                ethers.parseEther('50'), // 50 USDC
              ]),
            ],
          ),
          // Second transaction: DAO token transfer
          ethers.solidityPacked(
            ['uint8', 'address', 'uint256', 'uint256', 'bytes'],
            [
              0, // operation: CALL
              await daoToken.getAddress(),
              0, // value: 0 ETH
              ethers.dataLength(
                daoToken.interface.encodeFunctionData('transferFrom', [
                  mockDAOTreasury.address,
                  investorBob.address,
                  ethers.parseEther('50000'), // 50,000 daoToken
                ]),
              ),
              daoToken.interface.encodeFunctionData('transferFrom', [
                mockDAOTreasury.address,
                investorBob.address,
                ethers.parseEther('50000'), // 50,000 daoToken
              ]),
            ],
          ),
        ]),
      },
      {
        account: investorCarol.address,
        required: false,
        weight: ethers.parseEther('20'),
        transactions: ethers.concat([
          // First transaction: USDC transfer
          ethers.solidityPacked(
            ['uint8', 'address', 'uint256', 'uint256', 'bytes'],
            [
              0, // operation: CALL
              await usdc.getAddress(),
              0, // value: 0 ETH
              ethers.dataLength(
                usdc.interface.encodeFunctionData('transferFrom', [
                  investorCarol.address,
                  mockDAOTreasury.address,
                  ethers.parseEther('10'), // 10 USDC
                ]),
              ),
              usdc.interface.encodeFunctionData('transferFrom', [
                investorCarol.address,
                mockDAOTreasury.address,
                ethers.parseEther('10'), // 10 USDC
              ]),
            ],
          ),
          // Second transaction: DAO token transfer
          ethers.solidityPacked(
            ['uint8', 'address', 'uint256', 'uint256', 'bytes'],
            [
              0, // operation: CALL
              await daoToken.getAddress(),
              0, // value: 0 ETH
              ethers.dataLength(
                daoToken.interface.encodeFunctionData('transferFrom', [
                  mockDAOTreasury.address,
                  investorCarol.address,
                  ethers.parseEther('10000'), // 10,000 daoToken
                ]),
              ),
              daoToken.interface.encodeFunctionData('transferFrom', [
                mockDAOTreasury.address,
                investorCarol.address,
                ethers.parseEther('10000'), // 10,000 daoToken
              ]),
            ],
          ),
        ]),
      },
    ];

    const currentTime = await time.latest();
    signingDeadline = BigInt(currentTime) + BigInt(7 * 24 * 60 * 60); // one week
    executionDeadline = BigInt(currentTime) + BigInt(14 * 24 * 60 * 60); // two weeks

    const countersignImplementation = await new CountersignV1__factory(founder).deploy();
    countersign = await deployCountersignProxy(
      founder,
      await countersignImplementation.getAddress(),
      founder.address,
      agreementUri,
      await mockKYCVerifier.getAddress(),
      signingDeadline,
      executionDeadline,
      await multisend.getAddress(),
      ethers.parseEther('100'), // minWeight
      preExecutionTransactions,
      signerInitializations,
    );

    // Alice approves countersign to spend her USDC
    await usdc
      .connect(investorAlice)
      .approve(await countersign.getAddress(), ethers.parseEther('100'));

    // Bob approves countersign to spend his USDC
    await usdc
      .connect(investorBob)
      .approve(await countersign.getAddress(), ethers.parseEther('50'));

    // Carol approves countersign to spend her USDC
    await usdc
      .connect(investorCarol)
      .approve(await countersign.getAddress(), ethers.parseEther('10'));

    // DAO treasury approves countersign to spend its DAO tokens
    await daoToken
      .connect(mockDAOTreasury)
      .approve(await countersign.getAddress(), ethers.parseEther('160000'));
  });

  describe('Initialization', () => {
    it('should not allow reinitialization', async () => {
      await expect(
        countersign.initialize(
          founder.address,
          agreementUri,
          await mockKYCVerifier.getAddress(),
          signingDeadline,
          executionDeadline,
          await multisend.getAddress(),
          ethers.parseEther('100'),
          '0x', // empty preExecutionTransactions
          [], // empty signerInitializations
        ),
      ).to.be.revertedWithCustomError(countersign, 'InvalidInitialization');
    });

    it('should return correct owner', async () => {
      expect(await countersign.owner()).to.equal(founder.address);
    });

    it('should return correct agreement URI', async () => {
      expect(await countersign.agreementUri()).to.equal(agreementUri);
    });

    it('should return correct kyc verifier', async () => {
      expect(await countersign.kycVerifier()).to.equal(await mockKYCVerifier.getAddress());
    });

    it('should return correct signing deadline', async () => {
      expect(await countersign.signingDeadline()).to.equal(signingDeadline);
    });

    it('should return correct execution deadline', async () => {
      expect(await countersign.executionDeadline()).to.equal(executionDeadline);
    });

    it('should return correct multisend', async () => {
      expect(await countersign.multisend()).to.equal(await multisend.getAddress());
    });

    it('should return correct minWeight', async () => {
      expect(await countersign.minWeight()).to.equal(ethers.parseEther('100'));
    });

    it('should return correct signer addresses', async () => {
      expect(await countersign.signerAddresses()).to.deep.equal([
        founder.address,
        investorAlice.address,
        investorBob.address,
        investorCarol.address,
      ]);
    });

    it('should return correct signer data', async () => {
      // Founder data: isSigner=true, required=true, signed=false, weight=0, transactions=[]
      const [
        founderIsSigner,
        founderRequired,
        founderSigned,
        founderExecuted,
        founderSignedTimestamp,
        founderWeight,
        founderTransactions,
      ] = await countersign.signerData(founder.address);
      void expect(founderIsSigner).to.be.true;
      void expect(founderRequired).to.be.true;
      void expect(founderSigned).to.be.false;
      void expect(founderExecuted).to.be.false;
      void expect(founderSignedTimestamp).to.equal(0n);
      void expect(founderWeight).to.equal(0n);
      void expect(founderTransactions).to.equal('0x');

      // Alice data: isSigner=true, required=true, signed=false, weight=100, transactions=[2 transactions]
      const [
        aliceIsSigner,
        aliceRequired,
        aliceSigned,
        aliceExecuted,
        aliceBeforeSignedTimestamp,
        aliceWeight,
        aliceTransactions,
      ] = await countersign.signerData(investorAlice.address);
      void expect(aliceIsSigner).to.be.true;
      void expect(aliceRequired).to.be.true;
      void expect(aliceSigned).to.be.false;
      void expect(aliceExecuted).to.be.false;
      void expect(aliceBeforeSignedTimestamp).to.equal(0n);
      void expect(aliceWeight).to.equal(ethers.parseEther('100'));
      void expect(aliceTransactions).to.equal(
        ethers.concat([
          // First transaction: USDC transfer
          ethers.solidityPacked(
            ['uint8', 'address', 'uint256', 'uint256', 'bytes'],
            [
              0, // operation: CALL
              await usdc.getAddress(),
              0, // value: 0 ETH
              ethers.dataLength(
                usdc.interface.encodeFunctionData('transferFrom', [
                  investorAlice.address,
                  mockDAOTreasury.address,
                  ethers.parseEther('100'), // 100 USDC
                ]),
              ),
              usdc.interface.encodeFunctionData('transferFrom', [
                investorAlice.address,
                mockDAOTreasury.address,
                ethers.parseEther('100'), // 100 USDC
              ]),
            ],
          ),
          // Second transaction: DAO token transfer
          ethers.solidityPacked(
            ['uint8', 'address', 'uint256', 'uint256', 'bytes'],
            [
              0, // operation: CALL
              await daoToken.getAddress(),
              0, // value: 0 ETH
              ethers.dataLength(
                daoToken.interface.encodeFunctionData('transferFrom', [
                  mockDAOTreasury.address,
                  investorAlice.address,
                  ethers.parseEther('100000'), // 100,000 daoToken
                ]),
              ),
              daoToken.interface.encodeFunctionData('transferFrom', [
                mockDAOTreasury.address,
                investorAlice.address,
                ethers.parseEther('100000'), // 100,000 daoToken
              ]),
            ],
          ),
        ]),
      );

      // Bob data: isSigner=true, required=false, signed=false, weight=50, transactions=[2 transactions]
      const [
        bobIsSigner,
        bobRequired,
        bobSigned,
        bobExecuted,
        bobBeforeSignedTimestamp,
        bobWeight,
        bobTransactions,
      ] = await countersign.signerData(investorBob.address);
      void expect(bobIsSigner).to.be.true;
      void expect(bobRequired).to.be.false;
      void expect(bobSigned).to.be.false;
      void expect(bobExecuted).to.be.false;
      void expect(bobBeforeSignedTimestamp).to.equal(0n);
      void expect(bobWeight).to.equal(ethers.parseEther('50'));
      void expect(bobTransactions).to.equal(
        ethers.concat([
          // First transaction: USDC transfer
          ethers.solidityPacked(
            ['uint8', 'address', 'uint256', 'uint256', 'bytes'],
            [
              0, // operation: CALL
              await usdc.getAddress(),
              0, // value: 0 ETH
              ethers.dataLength(
                usdc.interface.encodeFunctionData('transferFrom', [
                  investorBob.address,
                  mockDAOTreasury.address,
                  ethers.parseEther('50'), // 50 USDC
                ]),
              ),
              usdc.interface.encodeFunctionData('transferFrom', [
                investorBob.address,
                mockDAOTreasury.address,
                ethers.parseEther('50'), // 50 USDC
              ]),
            ],
          ),
          // Second transaction: DAO token transfer
          ethers.solidityPacked(
            ['uint8', 'address', 'uint256', 'uint256', 'bytes'],
            [
              0, // operation: CALL
              await daoToken.getAddress(),
              0, // value: 0 ETH
              ethers.dataLength(
                daoToken.interface.encodeFunctionData('transferFrom', [
                  mockDAOTreasury.address,
                  investorBob.address,
                  ethers.parseEther('50000'), // 50,000 daoToken
                ]),
              ),
              daoToken.interface.encodeFunctionData('transferFrom', [
                mockDAOTreasury.address,
                investorBob.address,
                ethers.parseEther('50000'), // 50,000 daoToken
              ]),
            ],
          ),
        ]),
      );

      // Carol data: isSigner=true, required=false, signed=false, weight=20, transactions=[2 transactions]
      const [
        carolIsSigner,
        carolRequired,
        carolSigned,
        carolExecuted,
        carolBeforeSignedTimestamp,
        carolWeight,
        carolTransactions,
      ] = await countersign.signerData(investorCarol.address);
      void expect(carolIsSigner).to.be.true;
      void expect(carolRequired).to.be.false;
      void expect(carolSigned).to.be.false;
      void expect(carolExecuted).to.be.false;
      void expect(carolBeforeSignedTimestamp).to.equal(0n);
      void expect(carolWeight).to.equal(ethers.parseEther('20'));
      void expect(carolTransactions).to.equal(
        ethers.concat([
          // First transaction: USDC transfer
          ethers.solidityPacked(
            ['uint8', 'address', 'uint256', 'uint256', 'bytes'],
            [
              0, // operation: CALL
              await usdc.getAddress(),
              0, // value: 0 ETH
              ethers.dataLength(
                usdc.interface.encodeFunctionData('transferFrom', [
                  investorCarol.address,
                  mockDAOTreasury.address,
                  ethers.parseEther('10'), // 10 USDC
                ]),
              ),
              usdc.interface.encodeFunctionData('transferFrom', [
                investorCarol.address,
                mockDAOTreasury.address,
                ethers.parseEther('10'), // 10 USDC
              ]),
            ],
          ),
          // Second transaction: DAO token transfer
          ethers.solidityPacked(
            ['uint8', 'address', 'uint256', 'uint256', 'bytes'],
            [
              0, // operation: CALL
              await daoToken.getAddress(),
              0, // value: 0 ETH
              ethers.dataLength(
                daoToken.interface.encodeFunctionData('transferFrom', [
                  mockDAOTreasury.address,
                  investorCarol.address,
                  ethers.parseEther('10000'), // 10,000 daoToken
                ]),
              ),
              daoToken.interface.encodeFunctionData('transferFrom', [
                mockDAOTreasury.address,
                investorCarol.address,
                ethers.parseEther('10000'), // 10,000 daoToken
              ]),
            ],
          ),
        ]),
      );
    });

    it('should return correct preExecutionTransactions', async () => {
      const preExecutionTransactions = await countersign.preExecutionTransactions();
      void expect(preExecutionTransactions).to.equal(
        ethers.solidityPacked(
          ['uint8', 'address', 'uint256', 'uint256', 'bytes'],
          [
            0, // operation: CALL
            await daoToken.getAddress(),
            0, // value: 0 ETH
            ethers.dataLength(
              daoToken.interface.encodeFunctionData('transferFrom', [
                mockDAOTreasury.address,
                ethers.ZeroAddress,
                ethers.parseEther('100000'),
              ]),
            ),
            daoToken.interface.encodeFunctionData('transferFrom', [
              mockDAOTreasury.address,
              ethers.ZeroAddress,
              ethers.parseEther('100000'),
            ]),
          ],
        ),
      );
    });
  });

  describe('Ownership', () => {
    it('should set the owner correctly', async () => {
      const currentOwner = await countersign.owner();
      expect(currentOwner).to.equal(founder.address);
    });

    it('Should allow owner to transfer ownership', async function () {
      await countersign.connect(founder).transferOwnership(investorAlice.address);
      await countersign.connect(investorAlice).acceptOwnership();
      expect(await countersign.owner()).to.equal(investorAlice.address);
    });

    it('should allow the owner to call authorized functions', async () => {
      await countersign.connect(founder).renounceOwnership();
      expect(await countersign.owner()).to.equal(ethers.ZeroAddress);
    });

    it('should not allow non-owners to call owner-only functions', async () => {
      await expect(
        countersign.connect(investorAlice).renounceOwnership(),
      ).to.be.revertedWithCustomError(countersign, 'OwnableUnauthorizedAccount');
    });
  });

  describe('Version', () => {
    it('should return the correct version number', async () => {
      expect(await countersign.version()).to.equal(1);
    });
  });

  describe('ERC165', function () {
    // Interface IDs
    let iVersionInterfaceId: string;
    let iCountersignV1InterfaceId: string;
    let iERC165InterfaceId: string;
    beforeEach(async function () {
      // Calculate interface IDs
      const IVersionInterface = IVersion__factory.createInterface();
      iVersionInterfaceId = calculateInterfaceId(IVersionInterface);

      const ICountersignV1Interface = ICountersignV1__factory.createInterface();
      iCountersignV1InterfaceId = calculateInterfaceId(ICountersignV1Interface);

      const IERC165Interface = IERC165__factory.createInterface();
      iERC165InterfaceId = calculateInterfaceId(IERC165Interface);
    });

    it('Should support IERC165 interface', async function () {
      const supported = await countersign.supportsInterface(iERC165InterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should support ICountersignV1 interface', async function () {
      const supported = await countersign.supportsInterface(iCountersignV1InterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should support IVersion interface', async function () {
      const supported = await countersign.supportsInterface(iVersionInterfaceId);
      void expect(supported).to.be.true;
    });

    it('Should not support random interface', async function () {
      const randomInterfaceId = '0x12345678';
      const supported = await countersign.supportsInterface(randomInterfaceId);
      void expect(supported).to.be.false;
    });
  });

  describe('Signing', () => {
    it('should allow signers to sign', async () => {
      // set mock KYC verifier to verify all signatures
      await mockKYCVerifier.setVerify(true);

      const [, , aliceBeforeSigned, , aliceBeforeSignedTimestamp, ,] = await countersign.signerData(
        investorAlice.address,
      );
      void expect(aliceBeforeSigned).to.be.false;
      void expect(aliceBeforeSignedTimestamp).to.equal(0n);
      await countersign.connect(investorAlice).sign();
      const [, , aliceAfterSigned, , aliceAfterSignedTimestamp, ,] = await countersign.signerData(
        investorAlice.address,
      );
      void expect(aliceAfterSigned).to.be.true;
      void expect(aliceAfterSignedTimestamp).to.equal(await time.latest());

      const [, , bobBeforeSigned, , bobBeforeSignedTimestamp, ,] = await countersign.signerData(
        investorBob.address,
      );
      void expect(bobBeforeSigned).to.be.false;
      void expect(bobBeforeSignedTimestamp).to.equal(0n);
      await countersign.connect(investorBob).sign();
      const [, , bobAfterSigned, , bobAfterSignedTimestamp, ,] = await countersign.signerData(
        investorBob.address,
      );
      void expect(bobAfterSigned).to.be.true;
      void expect(bobAfterSignedTimestamp).to.equal(await time.latest());

      const [, , carolBeforeSigned, , carolBeforeSignedTimestamp, ,] = await countersign.signerData(
        investorCarol.address,
      );
      void expect(carolBeforeSigned).to.be.false;
      void expect(carolBeforeSignedTimestamp).to.equal(0n);
      await countersign.connect(investorCarol).sign();
      const [, , carolAfterSigned, , carolAfterSignedTimestamp, ,] = await countersign.signerData(
        investorCarol.address,
      );
      void expect(carolAfterSigned).to.be.true;
      void expect(carolAfterSignedTimestamp).to.equal(await time.latest());
    });

    it('should not allow signers to sign after the signing deadline', async () => {
      await mockKYCVerifier.setVerify(true);

      await time.increaseTo(signingDeadline + 1n);
      await expect(countersign.connect(investorAlice).sign()).to.be.revertedWithCustomError(
        countersign,
        'SigningDeadlineElapsed',
      );
    });

    it('should not allow signers to sign if they are not a signer', async () => {
      await mockKYCVerifier.setVerify(true);
      await expect(countersign.connect(anon).sign()).to.be.revertedWithCustomError(
        countersign,
        'InvalidSigner',
      );
    });

    it('should not allow signers to sign if they have already signed', async () => {
      await mockKYCVerifier.setVerify(true);
      await countersign.connect(investorAlice).sign();
      await expect(countersign.connect(investorAlice).sign()).to.be.revertedWithCustomError(
        countersign,
        'SignerAlreadySigned',
      );
    });

    it('should not allow signers to sign if the KYCVerifier does not verify', async () => {
      await mockKYCVerifier.setVerify(false);
      await expect(countersign.connect(investorAlice).sign()).to.be.revertedWithCustomError(
        countersign,
        'InvalidKYCSignature',
      );
    });
  });

  describe.only('Execution', () => {
    it('should allow for initial execution', async () => {
      // set mock KYC verifier to verify all signatures
      await mockKYCVerifier.setVerify(true);

      await countersign.connect(founder).sign();
      await countersign.connect(investorAlice).sign();
      await countersign.connect(investorBob).sign();
      await countersign.connect(investorCarol).sign();

      // move time to after signing deadline
      await time.increaseTo(signingDeadline + 1n);

      expect(await usdc.balanceOf(mockDAOTreasury.address)).to.equal(ethers.parseEther('0'));
      expect(await usdc.balanceOf(investorAlice.address)).to.equal(ethers.parseEther('100'));
      expect(await usdc.balanceOf(investorBob.address)).to.equal(ethers.parseEther('50'));
      expect(await usdc.balanceOf(investorCarol.address)).to.equal(ethers.parseEther('10'));

      expect(await daoToken.balanceOf(mockDAOTreasury.address)).to.equal(ethers.parseEther('0'));
      expect(await daoToken.balanceOf(investorAlice.address)).to.equal(ethers.parseEther('0'));
      expect(await daoToken.balanceOf(investorBob.address)).to.equal(ethers.parseEther('0'));
      expect(await daoToken.balanceOf(investorCarol.address)).to.equal(ethers.parseEther('0'));

      let [, , , founderExecuted, , ,] = await countersign.signerData(
        founder.address,
      );
      let [, , , aliceExecuted, , ,] = await countersign.signerData(
        investorAlice.address,
      );
      let [, , , bobExecuted, , ,] = await countersign.signerData(
        investorBob.address,
      );
      let [, , , carolExecuted, , ,] = await countersign.signerData(
        investorCarol.address,
      );

      void expect(founderExecuted).to.be.false;
      void expect(aliceExecuted).to.be.false;
      void expect(bobExecuted).to.be.false;
      void expect(carolExecuted).to.be.false;

      void expect(await countersign.initialExecutionComplete()).to.be.false;

      await countersign.connect(founder).execute();

      expect(await usdc.balanceOf(mockDAOTreasury.address)).to.equal(ethers.parseEther('160'));
      expect(await usdc.balanceOf(investorAlice.address)).to.equal(ethers.parseEther('0'));
      expect(await usdc.balanceOf(investorBob.address)).to.equal(ethers.parseEther('0'));
      expect(await usdc.balanceOf(investorCarol.address)).to.equal(ethers.parseEther('0'));

      expect(await daoToken.balanceOf(mockDAOTreasury.address)).to.equal(ethers.parseEther('40000'));
      expect(await daoToken.balanceOf(investorAlice.address)).to.equal(ethers.parseEther('100000'));
      expect(await daoToken.balanceOf(investorBob.address)).to.equal(ethers.parseEther('50000'));
      expect(await daoToken.balanceOf(investorCarol.address)).to.equal(ethers.parseEther('10000'));

       [, , , founderExecuted, , ,] = await countersign.signerData(
        founder.address,
      );
      [, , , aliceExecuted, , ,] = await countersign.signerData(
        investorAlice.address,
      );
      [, , , bobExecuted, , ,] = await countersign.signerData(
        investorBob.address,
      );
      [, , , carolExecuted, , ,] = await countersign.signerData(
        investorCarol.address,
      );
      
      void expect(founderExecuted).to.be.false;
      void expect(aliceExecuted).to.be.true;
      void expect(bobExecuted).to.be.true;
      void expect(carolExecuted).to.be.true;

      void expect(await countersign.initialExecutionComplete()).to.be.true;
    });

    it('should allow for final execution when some non-required signers have not signed', async () => {
      // set mock KYC verifier to verify all signatures
      await mockKYCVerifier.setVerify(true);

      // all signers but Carol sign
      await countersign.connect(founder).sign();
      await countersign.connect(investorAlice).sign();
      await countersign.connect(investorBob).sign();

      // move time to after signing deadline
      await time.increaseTo(signingDeadline + 1n);

      expect(await usdc.balanceOf(mockDAOTreasury.address)).to.equal(ethers.parseEther('0'));
      expect(await usdc.balanceOf(investorAlice.address)).to.equal(ethers.parseEther('100'));
      expect(await usdc.balanceOf(investorBob.address)).to.equal(ethers.parseEther('50'));
      expect(await usdc.balanceOf(investorCarol.address)).to.equal(ethers.parseEther('10'));

      expect(await daoToken.balanceOf(mockDAOTreasury.address)).to.equal(ethers.parseEther('0'));
      expect(await daoToken.balanceOf(investorAlice.address)).to.equal(ethers.parseEther('0'));
      expect(await daoToken.balanceOf(investorBob.address)).to.equal(ethers.parseEther('0'));
      expect(await daoToken.balanceOf(investorCarol.address)).to.equal(ethers.parseEther('0'));

      let [, , , founderExecuted, , ,] = await countersign.signerData(
        founder.address,
      );
      let [, , , aliceExecuted, , ,] = await countersign.signerData(
        investorAlice.address,
      );
      let [, , , bobExecuted, , ,] = await countersign.signerData(
        investorBob.address,
      );
      let [, , , carolExecuted, , ,] = await countersign.signerData(
        investorCarol.address,
      );

      void expect(founderExecuted).to.be.false;
      void expect(aliceExecuted).to.be.false;
      void expect(bobExecuted).to.be.false;
      void expect(carolExecuted).to.be.false;

      void expect(await countersign.initialExecutionComplete()).to.be.false;

      await countersign.connect(founder).execute();

      expect(await usdc.balanceOf(mockDAOTreasury.address)).to.equal(ethers.parseEther('150'));
      expect(await usdc.balanceOf(investorAlice.address)).to.equal(ethers.parseEther('0'));
      expect(await usdc.balanceOf(investorBob.address)).to.equal(ethers.parseEther('0'));
      expect(await usdc.balanceOf(investorCarol.address)).to.equal(ethers.parseEther('10'));

      expect(await daoToken.balanceOf(mockDAOTreasury.address)).to.equal(ethers.parseEther('50000'));
      expect(await daoToken.balanceOf(investorAlice.address)).to.equal(ethers.parseEther('100000'));
      expect(await daoToken.balanceOf(investorBob.address)).to.equal(ethers.parseEther('50000'));
      expect(await daoToken.balanceOf(investorCarol.address)).to.equal(ethers.parseEther('0'));

      [, , , founderExecuted, , ,] = await countersign.signerData(
        founder.address,
      );
      [, , , aliceExecuted, , ,] = await countersign.signerData(
        investorAlice.address,
      );
      [, , , bobExecuted, , ,] = await countersign.signerData(
        investorBob.address,
      );
      [, , , carolExecuted, , ,] = await countersign.signerData(
        investorCarol.address,
      );

      void expect(founderExecuted).to.be.false;
      void expect(aliceExecuted).to.be.true;
      void expect(bobExecuted).to.be.true;
      void expect(carolExecuted).to.be.false;

      void expect(await countersign.initialExecutionComplete()).to.be.true;
    });
  });
});
