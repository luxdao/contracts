import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
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
} from '../../../typechain-types';
import { calculateInterfaceId } from '../../helpers/utils';

describe('CountersignV1', () => {
  // signers
  let founder: SignerWithAddress;
  let investorAlice: SignerWithAddress;
  let investorBob: SignerWithAddress;
  let investorCarol: SignerWithAddress;
  let mockVerificationContract: SignerWithAddress;
  let mockDAOTreasury: SignerWithAddress;

  // contracts
  let countersign: CountersignV1;
  let daoToken: MockERC20Votes;
  let usdc: MockERC20Votes;

  const agreementUri = 'ipfs://the-agreement-uri';

  beforeEach(async () => {
    // Get signers
    [
      founder,
      investorAlice,
      investorBob,
      investorCarol,
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

    countersign = await new CountersignV1__factory(founder).deploy(
      agreementUri,
      mockVerificationContract.address,
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

  describe('Deployment', () => {
    it('should return correct agreement URI', async () => {
      expect(await countersign.agreementUri()).to.equal(agreementUri);
    });

    it('should return correct verification contract', async () => {
      expect(await countersign.verificationContract()).to.equal(mockVerificationContract.address);
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
});
