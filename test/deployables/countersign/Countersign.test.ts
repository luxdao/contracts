import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { mine, time } from '@nomicfoundation/hardhat-network-helpers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  IERC165__factory,
  IERC20__factory,
  IVersion__factory,
  CountersignV1,
  CountersignV1__factory,
  MockERC20Votes,
  MockERC20Votes__factory,
  ICountersignV1__factory,
} from '../../../typechain-types';
import { calculateInterfaceId } from '../../helpers/utils';

describe.only('CountersignV1', () => {
  // signers
  let founder: SignerWithAddress;
  let investorAlice: SignerWithAddress;
  let investorBob: SignerWithAddress;
  let investorCarol: SignerWithAddress;
  let mockVerificationContract: SignerWithAddress;
  let mockDAOTreasury: SignerWithAddress;

  // contracts
  let countersign: CountersignV1;
  let masterCopy: string;
  let daoToken: MockERC20Votes;
  let usdc: MockERC20Votes;

  const agreeumentUri = 'ipfs://the-agreement-uri';

  beforeEach(async () => {
    // Get signers
    [founder, investorAlice, investorBob, investorCarol, mockVerificationContract, mockDAOTreasury] = await ethers.getSigners();

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
    const signerAddresses = [founder.address, investorAlice.address, investorBob.address, investorCarol.address];
    const signerRequired = [true, true, false, false];
    const signerWeights = [0, ethers.parseEther('100'), ethers.parseEther('50'), ethers.parseEther('20')];

    const signerTransactions = [
      [], // founder: empty array
      [ // investor Alice
        {
          target: await usdc.getAddress(),
          value: 0,
          data: usdc.interface.encodeFunctionData('transferFrom', [
            investorAlice.address,
            mockDAOTreasury.address,
            ethers.parseEther('100') // 100 USDC
          ]),
        },
        {
          target: await daoToken.getAddress(),
          value: 0,
          data: daoToken.interface.encodeFunctionData('transferFrom', [
            mockDAOTreasury.address,
            investorAlice.address,
            ethers.parseEther('100000') // 100,000 daoToken
          ]),
        }
      ],
      [ // investor Bob
        {
          target: await usdc.getAddress(),
          value: 0,
          data: usdc.interface.encodeFunctionData('transferFrom', [
            investorBob.address,
            mockDAOTreasury.address,
            ethers.parseEther('50') // 50 USDC
          ]),
        },
        {
          target: await daoToken.getAddress(),
          value: 0,
          data: daoToken.interface.encodeFunctionData('transferFrom', [
            mockDAOTreasury.address,
            investorAlice.address,
            ethers.parseEther('50000') // 50,000 daoToken
          ]),
        }
      ],
      [ // investor Carol
        {
          target: await usdc.getAddress(),
          value: 0,
          data: usdc.interface.encodeFunctionData('transferFrom', [
            investorCarol.address,
            mockDAOTreasury.address,
            ethers.parseEther('10') // 10 USDC
          ]),
        },
        {
          target: await daoToken.getAddress(),
          value: 0,
          data: daoToken.interface.encodeFunctionData('transferFrom', [
            mockDAOTreasury.address,
            investorCarol.address,
            ethers.parseEther('10000') // 10,000 daoToken
          ]),
        }
      ]
    ];

    // preExecution transaction transfer 100,000 DAO tokens from treasury to address zero
    const preExecutionTransactions = [
      {
        target: await daoToken.getAddress(),
        value: 0,
        data: daoToken.interface.encodeFunctionData('transferFrom', [mockDAOTreasury.address, ethers.ZeroAddress, ethers.parseEther('100000')])
      }
    ];

    countersign = await new CountersignV1__factory(founder).deploy(
      agreeumentUri,
      mockVerificationContract.address,
      ethers.parseEther('100'), // minWeight
      signerAddresses,
      signerRequired,
      signerWeights,
      signerTransactions,
      preExecutionTransactions,
    );

    // Alice approves countersign to spend her USDC
    await usdc.connect(investorAlice).approve(await countersign.getAddress(), ethers.parseEther('100'));

    // Bob approves countersign to spend his USDC
    await usdc.connect(investorBob).approve(await countersign.getAddress(), ethers.parseEther('50'));

    // Carol approves countersign to spend her USDC
    await usdc.connect(investorCarol).approve(await countersign.getAddress(), ethers.parseEther('10'));

    // DAO treasury approves countersign to spend its DAO tokens
    await daoToken.connect(mockDAOTreasury).approve(await countersign.getAddress(), ethers.parseEther('100000'));
  });

  describe('Deployment', () => {
    it('should return correct agreement URI', async () => {
      expect(await countersign.agreementUri()).to.equal(agreeumentUri);
    });

    it('should return correct verification contract', async () => {
      expect(await countersign.verificationContract()).to.equal(mockVerificationContract.address);
    });

    it('should return correct minWeight', async () => {
      expect(await countersign.minWeight()).to.equal(ethers.parseEther('100'));
    });

    it('should return correct signer addresses', async () => {
      expect(await countersign.signerAddresses()).to.deep.equal([founder.address, investorAlice.address, investorBob.address, investorCarol.address]);
    });

    it('should return correct signer data', async () => {
      // Founder data: isSigner=true, required=true, signed=false, weight=0, transactions=[]
      const founderData = await countersign.signerData(founder.address);
      void expect(founderData.isSigner).to.be.true;
      void expect(founderData.required).to.be.true;
      void expect(founderData.signed).to.be.false;
      void expect(founderData.weight).to.equal(0n);
      void expect(founderData.transactions).to.deep.equal([]);

      // Alice data: isSigner=true, required=true, signed=false, weight=100, transactions=[2 transactions]
      const aliceData = await countersign.signerData(investorAlice.address);
      void expect(aliceData.isSigner).to.be.true;
      void expect(aliceData.required).to.be.true;
      void expect(aliceData.signed).to.be.false;
      void expect(aliceData.weight).to.equal(ethers.parseEther('100'));
      void expect(aliceData.transactions).to.have.lengthOf(2);
      
      // Verify Alice's USDC transfer transaction
      void expect(aliceData.transactions[0].target).to.equal(await usdc.getAddress());
      void expect(aliceData.transactions[0].value).to.equal(0n);
      void expect(aliceData.transactions[0].data).to.equal(
        usdc.interface.encodeFunctionData('transferFrom', [
          investorAlice.address,
          mockDAOTreasury.address,
          ethers.parseEther('100') // 100 USDC
        ])
      );

      // Verify Alice's DAO token transfer transaction
      void expect(aliceData.transactions[1].target).to.equal(await daoToken.getAddress());
      void expect(aliceData.transactions[1].value).to.equal(0n);
      void expect(aliceData.transactions[1].data).to.equal(
        daoToken.interface.encodeFunctionData('transferFrom', [
          mockDAOTreasury.address,
          investorAlice.address,
          ethers.parseEther('100000') // 100,000 daoToken
        ])
      );

      // Bob data: isSigner=true, required=false, signed=false, weight=50, transactions=[2 transactions]
      const bobData = await countersign.signerData(investorBob.address);
      void expect(bobData.isSigner).to.be.true;
      void expect(bobData.required).to.be.false;
      void expect(bobData.signed).to.be.false;
      void expect(bobData.weight).to.equal(ethers.parseEther('50'));
      void expect(bobData.transactions).to.have.lengthOf(2);

      // Verify Bob's USDC transfer transaction
      void expect(bobData.transactions[0].target).to.equal(await usdc.getAddress());
      void expect(bobData.transactions[0].value).to.equal(0n);
      void expect(bobData.transactions[0].data).to.equal(
        usdc.interface.encodeFunctionData('transferFrom', [
          investorBob.address,
          mockDAOTreasury.address,
          ethers.parseEther('50') // 50 USDC
        ])
      );

      // Verify Bob's DAO token transfer transaction
      void expect(bobData.transactions[1].target).to.equal(await daoToken.getAddress());
      void expect(bobData.transactions[1].value).to.equal(0n);
      void expect(bobData.transactions[1].data).to.equal(
        daoToken.interface.encodeFunctionData('transferFrom', [
          mockDAOTreasury.address,
          investorAlice.address,
          ethers.parseEther('50000') // 50,000 daoToken
        ])
      );

      // Carol data: isSigner=true, required=false, signed=false, weight=20, transactions=[2 transactions]
      const carolData = await countersign.signerData(investorCarol.address);
      void expect(carolData.isSigner).to.be.true;
      void expect(carolData.required).to.be.false;
      void expect(carolData.signed).to.be.false;
      void expect(carolData.weight).to.equal(ethers.parseEther('20'));
      void expect(carolData.transactions).to.have.lengthOf(2);

      // Verify Carol's USDC transfer transaction
      void expect(carolData.transactions[0].target).to.equal(await usdc.getAddress());
      void expect(carolData.transactions[0].value).to.equal(0n);
      void expect(carolData.transactions[0].data).to.equal(
        usdc.interface.encodeFunctionData('transferFrom', [
          investorCarol.address,
          mockDAOTreasury.address,
          ethers.parseEther('10') // 10 USDC
        ])
      );

      // Verify Carol's DAO token transfer transaction
      void expect(carolData.transactions[1].target).to.equal(await daoToken.getAddress());
      void expect(carolData.transactions[1].value).to.equal(0n);
      void expect(carolData.transactions[1].data).to.equal(
        daoToken.interface.encodeFunctionData('transferFrom', [
          mockDAOTreasury.address,
          investorCarol.address,
          ethers.parseEther('10000') // 10,000 daoToken
        ])
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
