import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  ConcreteVoterResolverV1,
  ConcreteVoterResolverV1__factory,
  ERC1967Proxy__factory,
  MockLightAccount,
  MockLightAccount__factory,
  MockLightAccountFactory,
  MockLightAccountFactory__factory,
} from '../../../typechain-types';

async function deployConcreteVoterResolver(
  deployer: SignerWithAddress,
  implementation: ConcreteVoterResolverV1,
  lightAccountFactory: MockLightAccountFactory,
) {
  const initializeCalldata = ConcreteVoterResolverV1__factory.createInterface().encodeFunctionData(
    'initialize',
    [lightAccountFactory.target],
  );

  // Deploy the proxy with owner as the deployer so msg.sender becomes the owner
  const proxy = await new ERC1967Proxy__factory(deployer).deploy(
    await implementation.getAddress(),
    initializeCalldata,
  );

  return ConcreteVoterResolverV1__factory.connect(await proxy.getAddress(), deployer);
}

describe('VoterResolverV1', () => {
  // Signers
  let deployer: SignerWithAddress;
  let owner: SignerWithAddress;
  let user: SignerWithAddress;

  // Contracts
  let concreteVoterResolver: ConcreteVoterResolverV1;
  let mockLightAccount: MockLightAccount;
  let mockLightAccountFactory: MockLightAccountFactory;

  beforeEach(async () => {
    [deployer, owner, user] = await ethers.getSigners();

    // Deploy a mock ownership contract with the owner address
    mockLightAccount = await new MockLightAccount__factory(deployer).deploy(owner.address);

    // Deploy MockLightAccountFactory
    mockLightAccountFactory = await new MockLightAccountFactory__factory(deployer).deploy();

    // Deploy an implementation instance of the ConcreteVoterResolverV1
    const implementation = await new ConcreteVoterResolverV1__factory(deployer).deploy();

    // Deploy an instance of the VoterResolverV1 concrete implementation
    concreteVoterResolver = await deployConcreteVoterResolver(
      deployer,
      implementation,
      mockLightAccountFactory,
    );

    // Set up the mock light account factory to return our mock account
    await mockLightAccountFactory.setAccountAddress(
      await mockLightAccount.owner(),
      0n,
      await mockLightAccount.getAddress(),
    );
  });

  describe('voter', () => {
    describe('light accounts', function () {
      it('should return the owner of the light account', async () => {
        // Test with our mock ownership contract
        const voter = await concreteVoterResolver.voter(await mockLightAccount.getAddress());
        expect(voter).to.equal(owner.address);
      });
    });

    describe('non-light accounts', function () {
      describe('when the msgSender is an EOA', () => {
        it('should return the msgSender', async () => {
          // For EOAs, the voter function should just return the address itself
          const eoaAddress = user.address;
          const voter = await concreteVoterResolver.voter(eoaAddress);
          expect(voter).to.equal(eoaAddress);
        });
      });

      describe('when the msgSender is a contract that does not implement IOwnership', () => {
        it('should return the contract address', async () => {
          // Use the ConcreteRC4337VoterSupport contract itself as a contract that doesn't implement IOwnership
          const contractAddress = await concreteVoterResolver.getAddress();
          const voter = await concreteVoterResolver.voter(contractAddress);
          expect(voter).to.equal(contractAddress);
        });
      });
    });
  });
});
