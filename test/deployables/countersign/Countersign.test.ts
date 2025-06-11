import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { time } from '@nomicfoundation/hardhat-network-helpers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  IERC165__factory,
  IVersion__factory,
  CountersignV1,
  CountersignV1__factory,
  MockERC20Votes,
  MockERC20Votes__factory,
  ICountersignV1__factory,
  ERC1967Proxy__factory,
} from '../../../typechain-types';
import { calculateInterfaceId } from '../../helpers/utils';

// Helper function for deploying Countersign instances using ERC1967Proxy
async function deployCountersignProxy(
  proxyDeployer: SignerWithAddress,
  implementation: string,
  agreementUri: string,
  verificationContract: string,
  signingDeadline: bigint,
  executionDeadline: bigint,
  minWeight: bigint,
  signerInitializations: any[],
  preExecutionTransactions: any[],
): Promise<CountersignV1> {
  // Create initialization data with function selector
  const fullInitData =
    CountersignV1__factory.createInterface().getFunction('initialize').selector +
    ethers.AbiCoder.defaultAbiCoder()
      .encode(
        [
          'string',
          'address',
          'uint256',
          'uint256',
          'uint256',
          'tuple(address account, bool required, uint256 weight, tuple(address target, uint256 value, bytes data)[] transactions)[]',
          'tuple(address target, uint256 value, bytes data)[]',
        ],
        [
          agreementUri,
          verificationContract,
          signingDeadline,
          executionDeadline,
          minWeight,
          signerInitializations,
          preExecutionTransactions,
        ],
      )
      .slice(2);

  // Deploy the proxy with the implementation
  const proxy = await new ERC1967Proxy__factory(proxyDeployer).deploy(implementation, fullInitData);

  // Return a contract instance connected to the proxy
  return CountersignV1__factory.connect(await proxy.getAddress(), proxyDeployer);
}

describe.only('CountersignV1', () => {
  // signers
  let founder: SignerWithAddress;
  let investorAlice: SignerWithAddress;
  let investorBob: SignerWithAddress;
  let investorCarol: SignerWithAddress;
  let anon: SignerWithAddress;
  let mockVerificationContract: SignerWithAddress;
  let mockDAOTreasury: SignerWithAddress;

  // contracts
  let countersign: CountersignV1;
  let daoToken: MockERC20Votes;
  let usdc: MockERC20Votes;

  let signingDeadline: bigint;
  let executionDeadline: bigint;

  const agreementUri = 'ipfs://the-agreement-uri';

  beforeEach(async () => {
    // Get signers
    [
      founder,
      investorAlice,
      investorBob,
      investorCarol,
      anon,
      mockVerificationContract,
      mockDAOTreasury,
    ] = await ethers.getSigners();

    daoToken = await new MockERC20Votes__factory(founder).deploy();
    usdc = await new MockERC20Votes__factory(founder).deploy();

    // mint Alice 100 USDC
    await usdc.mint(investorAlice.address, ethers.parseEther('100'));

    // mint Bob 50 USDC
    await usdc.mint(investorBob.address, ethers.parseEther('50'));

    // mint Carol 10 USDC
    await usdc.mint(investorCarol.address, ethers.parseEther('10'));

    // mint DAO treasury 100,000 DAO tokens
    await daoToken.mint(mockDAOTreasury.address, ethers.parseEther('100000'));

    // create signer addresses array
    const signerInitializations = [
      {
        account: founder.address,
        required: true,
        weight: 0,
        transactions: [], // founder: empty array
      },
      {
        account: investorAlice.address,
        required: true,
        weight: ethers.parseEther('100'),
        transactions: [
          // investor Alice
          {
            target: await usdc.getAddress(),
            value: 0,
            data: usdc.interface.encodeFunctionData('transferFrom', [
              investorAlice.address,
              mockDAOTreasury.address,
              ethers.parseEther('100'), // 100 USDC
            ]),
          },
          {
            target: await daoToken.getAddress(),
            value: 0,
            data: daoToken.interface.encodeFunctionData('transferFrom', [
              mockDAOTreasury.address,
              investorAlice.address,
              ethers.parseEther('100000'), // 100,000 daoToken
            ]),
          },
        ],
      },
      {
        account: investorBob.address,
        required: false,
        weight: ethers.parseEther('50'),
        transactions: [
          // investor Bob
          {
            target: await usdc.getAddress(),
            value: 0,
            data: usdc.interface.encodeFunctionData('transferFrom', [
              investorBob.address,
              mockDAOTreasury.address,
              ethers.parseEther('50'), // 50 USDC
            ]),
          },
          {
            target: await daoToken.getAddress(),
            value: 0,
            data: daoToken.interface.encodeFunctionData('transferFrom', [
              mockDAOTreasury.address,
              investorAlice.address,
              ethers.parseEther('50000'), // 50,000 daoToken
            ]),
          },
        ],
      },
      {
        account: investorCarol.address,
        required: false,
        weight: ethers.parseEther('20'),
        transactions: [
          // investor Carol
          {
            target: await usdc.getAddress(),
            value: 0,
            data: usdc.interface.encodeFunctionData('transferFrom', [
              investorCarol.address,
              mockDAOTreasury.address,
              ethers.parseEther('10'), // 10 USDC
            ]),
          },
          {
            target: await daoToken.getAddress(),
            value: 0,
            data: daoToken.interface.encodeFunctionData('transferFrom', [
              mockDAOTreasury.address,
              investorCarol.address,
              ethers.parseEther('10000'), // 10,000 daoToken
            ]),
          },
        ],
      },
    ];

    // preExecution transaction transfer 100,000 DAO tokens from treasury to address zero
    const preExecutionTransactions = [
      {
        target: await daoToken.getAddress(),
        value: 0,
        data: daoToken.interface.encodeFunctionData('transferFrom', [
          mockDAOTreasury.address,
          ethers.ZeroAddress,
          ethers.parseEther('100000'),
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
      agreementUri,
      mockVerificationContract.address,
      signingDeadline,
      executionDeadline,
      ethers.parseEther('100'), // minWeight
      signerInitializations,
      preExecutionTransactions,
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
      .approve(await countersign.getAddress(), ethers.parseEther('100000'));
  });

  describe('Initialization', () => {
    it('should not allow reinitialization', async () => {
      await expect(
        countersign.initialize(
          agreementUri,
          mockVerificationContract.address,
          signingDeadline,
          executionDeadline,
          ethers.parseEther('100'),
          [],
          [],
        ),
      ).to.be.revertedWithCustomError(countersign, 'InvalidInitialization');
    });

    it('should return correct agreement URI', async () => {
      expect(await countersign.agreementUri()).to.equal(agreementUri);
    });

    it('should return correct verification contract', async () => {
      expect(await countersign.verificationContract()).to.equal(mockVerificationContract.address);
    });

    it('should return correct signing deadline', async () => {
      expect(await countersign.signingDeadline()).to.equal(signingDeadline);
    });

    it('should return correct execution deadline', async () => {
      expect(await countersign.executionDeadline()).to.equal(executionDeadline);
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
      const [founderIsSigner, founderRequired, founderSigned, founderWeight, founderTransactions] =
        await countersign.signerData(founder.address);
      void expect(founderIsSigner).to.be.true;
      void expect(founderRequired).to.be.true;
      void expect(founderSigned).to.be.false;
      void expect(founderWeight).to.equal(0n);
      void expect(founderTransactions).to.deep.equal([]);

      // Alice data: isSigner=true, required=true, signed=false, weight=100, transactions=[2 transactions]
      const [aliceIsSigner, aliceRequired, aliceSigned, aliceWeight, aliceTransactions] =
        await countersign.signerData(investorAlice.address);
      void expect(aliceIsSigner).to.be.true;
      void expect(aliceRequired).to.be.true;
      void expect(aliceSigned).to.be.false;
      void expect(aliceWeight).to.equal(ethers.parseEther('100'));
      void expect(aliceTransactions).to.have.lengthOf(2);

      // Verify Alice's USDC transfer transaction
      void expect(aliceTransactions[0].target).to.equal(await usdc.getAddress());
      void expect(aliceTransactions[0].value).to.equal(0n);
      void expect(aliceTransactions[0].data).to.equal(
        usdc.interface.encodeFunctionData('transferFrom', [
          investorAlice.address,
          mockDAOTreasury.address,
          ethers.parseEther('100'), // 100 USDC
        ]),
      );

      // Verify Alice's DAO token transfer transaction
      void expect(aliceTransactions[1].target).to.equal(await daoToken.getAddress());
      void expect(aliceTransactions[1].value).to.equal(0n);
      void expect(aliceTransactions[1].data).to.equal(
        daoToken.interface.encodeFunctionData('transferFrom', [
          mockDAOTreasury.address,
          investorAlice.address,
          ethers.parseEther('100000'), // 100,000 daoToken
        ]),
      );

      // Bob data: isSigner=true, required=false, signed=false, weight=50, transactions=[2 transactions]
      const [bobIsSigner, bobRequired, bobSigned, bobWeight, bobTransactions] =
        await countersign.signerData(investorBob.address);
      void expect(bobIsSigner).to.be.true;
      void expect(bobRequired).to.be.false;
      void expect(bobSigned).to.be.false;
      void expect(bobWeight).to.equal(ethers.parseEther('50'));
      void expect(bobTransactions).to.have.lengthOf(2);

      // Verify Bob's USDC transfer transaction
      void expect(bobTransactions[0].target).to.equal(await usdc.getAddress());
      void expect(bobTransactions[0].value).to.equal(0n);
      void expect(bobTransactions[0].data).to.equal(
        usdc.interface.encodeFunctionData('transferFrom', [
          investorBob.address,
          mockDAOTreasury.address,
          ethers.parseEther('50'), // 50 USDC
        ]),
      );

      // Verify Bob's DAO token transfer transaction
      void expect(bobTransactions[1].target).to.equal(await daoToken.getAddress());
      void expect(bobTransactions[1].value).to.equal(0n);
      void expect(bobTransactions[1].data).to.equal(
        daoToken.interface.encodeFunctionData('transferFrom', [
          mockDAOTreasury.address,
          investorAlice.address,
          ethers.parseEther('50000'), // 50,000 daoToken
        ]),
      );

      // Carol data: isSigner=true, required=false, signed=false, weight=20, transactions=[2 transactions]
      const [carolIsSigner, carolRequired, carolSigned, carolWeight, carolTransactions] =
        await countersign.signerData(investorCarol.address);
      void expect(carolIsSigner).to.be.true;
      void expect(carolRequired).to.be.false;
      void expect(carolSigned).to.be.false;
      void expect(carolWeight).to.equal(ethers.parseEther('20'));
      void expect(carolTransactions).to.have.lengthOf(2);

      // Verify Carol's USDC transfer transaction
      void expect(carolTransactions[0].target).to.equal(await usdc.getAddress());
      void expect(carolTransactions[0].value).to.equal(0n);
      void expect(carolTransactions[0].data).to.equal(
        usdc.interface.encodeFunctionData('transferFrom', [
          investorCarol.address,
          mockDAOTreasury.address,
          ethers.parseEther('10'), // 10 USDC
        ]),
      );

      // Verify Carol's DAO token transfer transaction
      void expect(carolTransactions[1].target).to.equal(await daoToken.getAddress());
      void expect(carolTransactions[1].value).to.equal(0n);
      void expect(carolTransactions[1].data).to.equal(
        daoToken.interface.encodeFunctionData('transferFrom', [
          mockDAOTreasury.address,
          investorCarol.address,
          ethers.parseEther('10000'), // 10,000 daoToken
        ]),
      );
    });

    it('should return correct preExecutionTransactions', async () => {
      const preExecutionTransactions = await countersign.preExecutionTransactions();
      void expect(preExecutionTransactions).to.have.lengthOf(1);
      void expect(preExecutionTransactions[0].target).to.equal(await daoToken.getAddress());
      void expect(preExecutionTransactions[0].value).to.equal(0n);
      void expect(preExecutionTransactions[0].data).to.equal(
        daoToken.interface.encodeFunctionData('transferFrom', [
          mockDAOTreasury.address,
          ethers.ZeroAddress,
          ethers.parseEther('100000'),
        ]),
      );
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
      const [, , aliceBeforeSigned, ,] = await countersign.signerData(investorAlice.address);
      void expect(aliceBeforeSigned).to.be.false;
      await countersign.connect(investorAlice).sign();
      const [, , aliceAfterSigned, ,] = await countersign.signerData(investorAlice.address);
      void expect(aliceAfterSigned).to.be.true;

      const [, , bobBeforeSigned, ,] = await countersign.signerData(investorBob.address);
      void expect(bobBeforeSigned).to.be.false;
      await countersign.connect(investorBob).sign();
      const [, , bobAfterSigned, ,] = await countersign.signerData(investorBob.address);
      void expect(bobAfterSigned).to.be.true;

      const [, , carolBeforeSigned, ,] = await countersign.signerData(investorCarol.address);
      void expect(carolBeforeSigned).to.be.false;
      await countersign.connect(investorCarol).sign();
      const [, , carolAfterSigned, ,] = await countersign.signerData(investorCarol.address);
      void expect(carolAfterSigned).to.be.true;
    });

    it('should not allow signers to sign after the signing deadline', async () => {
      await time.increaseTo(signingDeadline + 1n);
      await expect(countersign.connect(investorAlice).sign()).to.be.revertedWithCustomError(countersign, 'SigningDeadlineElapsed');
    });

    it('should not allow signers to sign if they are not a signer', async () => {
      await expect(countersign.connect(anon).sign()).to.be.revertedWithCustomError(countersign, 'InvalidSigner');
    });

    it('should not allow signers to sign if they have already signed', async () => {
      await countersign.connect(investorAlice).sign();
      await expect(countersign.connect(investorAlice).sign()).to.be.revertedWithCustomError(countersign, 'SignerAlreadySigned');
    });
  });
});
