import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { loadFixture } from '@nomicfoundation/hardhat-network-helpers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
  ERC1967Proxy__factory,
  ERC721VotingAdapterV1,
  ERC721VotingAdapterV1__factory,
  IBaseVotingAdapterV1__factory,
  IERC165__factory,
  IERC721VotingAdapterV1__factory,
  IVersion__factory,
  MockERC721,
  MockERC721__factory,
  MockVotingStrategy,
  MockVotingStrategy__factory,
} from '../../../../typechain-types';
import { calculateInterfaceId } from '../../../helpers/utils';

async function deployERC721AdapterProxy(
  proxyDeployer: SignerWithAddress,
  implementationAddress: string,
  tokenAddress: string,
  strategyAddress: string,
  weightPerNft: bigint,
): Promise<{ adapter: ERC721VotingAdapterV1 }> {
  const initData = ERC721VotingAdapterV1__factory.createInterface().encodeFunctionData(
    'initialize',
    [tokenAddress, strategyAddress, weightPerNft],
  );
  const proxyContractFactory = new ERC1967Proxy__factory(proxyDeployer);
  const proxy = await proxyContractFactory.deploy(implementationAddress, initData);
  await proxy.waitForDeployment();

  const adapterInstance = ERC721VotingAdapterV1__factory.connect(
    await proxy.getAddress(),
    proxyDeployer,
  );

  return { adapter: adapterInstance };
}

describe('ERC721VotingAdapterV1', () => {
  // Globally scoped (from first fixture load in `before`)
  let erc721AdapterImplementationAddressG: string;

  // Default Test Params
  const DEFAULT_WEIGHT_PER_NFT = 1n;

  async function deployGlobalERC721Fixture() {
    const [deployer] = await ethers.getSigners();
    const adapterImplFactory = new ERC721VotingAdapterV1__factory(deployer);
    const deployedAdapterImpl = await adapterImplFactory.deploy();
    await deployedAdapterImpl.waitForDeployment();
    erc721AdapterImplementationAddressG = await deployedAdapterImpl.getAddress();
    return { erc721AdapterImplementationAddress: erc721AdapterImplementationAddressG, deployer };
  }

  async function deployMocksAndSignersERC721Fixture() {
    const [deployer, user1, user2, strategySigner] = await ethers.getSigners();

    const mockNftFactory = new MockERC721__factory(deployer);
    const mockNft = await mockNftFactory.deploy();
    await mockNft.waitForDeployment();

    const user1TokenIds: bigint[] = [];
    let nextTokenId: bigint;

    // Mint first token for user1
    nextTokenId = await mockNft.getCurrentTokenId();
    user1TokenIds.push(nextTokenId);
    await mockNft.mint(user1.address);

    // Mint second token for user1
    nextTokenId = await mockNft.getCurrentTokenId();
    user1TokenIds.push(nextTokenId);
    await mockNft.mint(user1.address);

    // Mint third token for user1
    nextTokenId = await mockNft.getCurrentTokenId();
    user1TokenIds.push(nextTokenId);
    await mockNft.mint(user1.address);

    const user2TokenIds: bigint[] = [];
    // Mint first token for user2
    nextTokenId = await mockNft.getCurrentTokenId();
    user2TokenIds.push(nextTokenId);
    await mockNft.mint(user2.address);

    // Mint second token for user2
    nextTokenId = await mockNft.getCurrentTokenId();
    user2TokenIds.push(nextTokenId);
    await mockNft.mint(user2.address);

    return {
      deployer,
      user1Signer: user1,
      user2Signer: user2,
      mockNft,
      user1TokenIds,
      user2TokenIds,
      strategyAddress: strategySigner.address,
      strategySigner,
    };
  }

  before(async () => {
    await loadFixture(deployGlobalERC721Fixture);
  });

  describe('Initialization', () => {
    it('should initialize correctly', async () => {
      const {
        mockNft,
        deployer: fixtureDeployer,
        strategyAddress,
      } = await loadFixture(deployMocksAndSignersERC721Fixture);

      const { adapter: erc721Adapter } = await deployERC721AdapterProxy(
        fixtureDeployer,
        erc721AdapterImplementationAddressG,
        await mockNft.getAddress(),
        strategyAddress,
        DEFAULT_WEIGHT_PER_NFT,
      );

      expect(await erc721Adapter.token()).to.equal(await mockNft.getAddress());
      expect(await erc721Adapter.weightPerToken()).to.equal(DEFAULT_WEIGHT_PER_NFT);
    });

    it('should not allow reinitialization', async () => {
      const {
        mockNft,
        deployer: fixtureDeployer,
        strategyAddress,
      } = await loadFixture(deployMocksAndSignersERC721Fixture);
      const { adapter: erc721Adapter } = await deployERC721AdapterProxy(
        fixtureDeployer,
        erc721AdapterImplementationAddressG,
        await mockNft.getAddress(),
        strategyAddress,
        DEFAULT_WEIGHT_PER_NFT,
      );
      await expect(
        erc721Adapter.initialize(
          await mockNft.getAddress(),
          strategyAddress,
          DEFAULT_WEIGHT_PER_NFT,
        ),
      ).to.be.revertedWithCustomError(erc721Adapter, 'InvalidInitialization');
    });

    it('Should have initialization disabled in the implementation contract', async function () {
      const {
        mockNft,
        deployer: fixtureDeployer,
        strategyAddress,
      } = await loadFixture(deployMocksAndSignersERC721Fixture);
      const implementationContract = ERC721VotingAdapterV1__factory.connect(
        erc721AdapterImplementationAddressG,
        fixtureDeployer,
      );
      await expect(
        implementationContract.initialize(
          await mockNft.getAddress(),
          strategyAddress,
          DEFAULT_WEIGHT_PER_NFT,
        ),
      ).to.be.revertedWithCustomError(implementationContract, 'InvalidInitialization');
    });
  });

  describe('weightOf', () => {
    let adapter: ERC721VotingAdapterV1;
    let mockNft: MockERC721;
    let user1: SignerWithAddress;
    let user1TokenIds: bigint[];
    let user2TokenIds: bigint[];
    let deployer: SignerWithAddress;
    let strategySigner: SignerWithAddress;

    const proposalId = 1;

    beforeEach(async () => {
      const fixture = await loadFixture(deployMocksAndSignersERC721Fixture);
      mockNft = fixture.mockNft;
      user1 = fixture.user1Signer;
      user1TokenIds = fixture.user1TokenIds;
      user2TokenIds = fixture.user2TokenIds;
      deployer = fixture.deployer;
      strategySigner = fixture.strategySigner;

      const { adapter: deployedAdapter } = await deployERC721AdapterProxy(
        deployer,
        erc721AdapterImplementationAddressG,
        await mockNft.getAddress(),
        fixture.strategyAddress,
        DEFAULT_WEIGHT_PER_NFT,
      );
      adapter = deployedAdapter;
    });

    it('should return correct weight if voter owns all provided, unvoted token IDs', async () => {
      const tokenIdsToVoteWith = [user1TokenIds[0], user1TokenIds[1]]; // e.g. [0, 1]
      const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
        ['uint256[]'],
        [tokenIdsToVoteWith],
      );
      const weight = await adapter.weightOf(user1.address, proposalId, adapterVoteData);
      expect(weight).to.equal(BigInt(tokenIdsToVoteWith.length) * DEFAULT_WEIGHT_PER_NFT);
    });

    it('should return correct weight if voter owns some of the provided token IDs', async () => {
      const tokenIdsToVoteWith = [user1TokenIds[0], user2TokenIds[0]]; // User1 owns first, not second
      const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
        ['uint256[]'],
        [tokenIdsToVoteWith],
      );
      const weight = await adapter.weightOf(user1.address, proposalId, adapterVoteData);
      expect(weight).to.equal(1n * DEFAULT_WEIGHT_PER_NFT); // Only user1TokenIds[0] is valid for user1
    });

    it('should return 0 weight for token IDs already used in the proposal', async () => {
      const tokenToUse = user1TokenIds[0];
      const initialAdapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
        ['uint256[]'],
        [[tokenToUse]],
      );
      await adapter
        .connect(strategySigner)
        .recordVote(user1.address, proposalId, initialAdapterVoteData);

      // Then, try to get weightOf for the same token
      const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
        ['uint256[]'],
        [[tokenToUse]],
      );
      const weight = await adapter.weightOf(user1.address, proposalId, adapterVoteData);
      expect(weight).to.equal(0n);
    });

    it('should count duplicate token IDs in _adapterVoteData only once', async () => {
      const tokenIdsToVoteWith = [user1TokenIds[0], user1TokenIds[0], user1TokenIds[1]]; // Duplicate user1TokenIds[0]
      const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
        ['uint256[]'],
        [tokenIdsToVoteWith],
      );
      const weight = await adapter.weightOf(user1.address, proposalId, adapterVoteData);
      // Expected weight is for user1TokenIds[0] and user1TokenIds[1] (2 tokens)
      expect(weight).to.equal(2n * DEFAULT_WEIGHT_PER_NFT);
    });

    it('should return 0 if _adapterVoteData is empty or decodes to an empty array', async () => {
      let adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(['uint256[]'], [[]]);
      let weight = await adapter.weightOf(user1.address, proposalId, adapterVoteData);
      expect(weight).to.equal(0n);

      // Test with malformed/non-array data (should ideally be caught by abi.decode or revert)
      // However, the contract handles empty array gracefully. For other malformations, it might revert.
      // This specific test focuses on empty array logic.
    });

    it('should return 0 if voter owns none of the valid provided token IDs', async () => {
      const tokenIdsToVoteWith = [user2TokenIds[0], user2TokenIds[1]]; // Tokens owned by user2
      const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
        ['uint256[]'],
        [tokenIdsToVoteWith],
      );
      const weight = await adapter.weightOf(user1.address, proposalId, adapterVoteData); // User1 tries to vote
      expect(weight).to.equal(0n);
    });

    it('should correctly apply weightPerNft > 1', async () => {
      const customWeightPerNft = 3n;
      const { adapter: customAdapter } = await deployERC721AdapterProxy(
        deployer,
        erc721AdapterImplementationAddressG,
        await mockNft.getAddress(),
        deployer.address,
        customWeightPerNft,
      );

      const tokenIdsToVoteWith = [user1TokenIds[0], user1TokenIds[1]];
      const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
        ['uint256[]'],
        [tokenIdsToVoteWith],
      );
      const weight = await customAdapter.weightOf(user1.address, proposalId, adapterVoteData);
      expect(weight).to.equal(BigInt(tokenIdsToVoteWith.length) * customWeightPerNft);
    });
  });

  describe('weightOfWithUnusedTokenIds', () => {
    let adapter: ERC721VotingAdapterV1;
    let mockNft: MockERC721;
    let user1: SignerWithAddress;
    let user1TokenIds: bigint[];
    let user2TokenIds: bigint[];
    let deployer: SignerWithAddress;
    let strategySigner: SignerWithAddress;

    const proposalId = 1;
    const proposalId2 = 2; // For testing used tokens across different proposals

    beforeEach(async () => {
      const fixture = await loadFixture(deployMocksAndSignersERC721Fixture);
      mockNft = fixture.mockNft;
      user1 = fixture.user1Signer;
      user1TokenIds = fixture.user1TokenIds; // User1 owns [0, 1, 2]
      user2TokenIds = fixture.user2TokenIds; // User2 owns [3, 4]
      deployer = fixture.deployer;
      strategySigner = fixture.strategySigner;

      const { adapter: deployedAdapter } = await deployERC721AdapterProxy(
        deployer,
        erc721AdapterImplementationAddressG,
        await mockNft.getAddress(),
        fixture.strategyAddress,
        DEFAULT_WEIGHT_PER_NFT,
      );
      adapter = deployedAdapter;
    });

    it('should return correct weight and token IDs if voter owns all provided, unvoted token IDs', async () => {
      const tokenIdsToVoteWith = [user1TokenIds[0], user1TokenIds[1]]; // [0, 1]
      const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
        ['uint256[]'],
        [tokenIdsToVoteWith],
      );
      const { weight, unusedTokenIds } = await adapter.weightOfWithValidTokenIds(
        user1.address,
        proposalId,
        adapterVoteData,
      );

      expect(weight).to.equal(BigInt(tokenIdsToVoteWith.length) * DEFAULT_WEIGHT_PER_NFT);
      expect(unusedTokenIds).to.deep.equal(tokenIdsToVoteWith);
    });

    it('should return correct weight and token IDs, filtering out unowned tokens', async () => {
      const tokenIdsToVoteWith = [user1TokenIds[0], user2TokenIds[0], user1TokenIds[1]]; // User1 owns first and third, user2 owns second
      const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
        ['uint256[]'],
        [tokenIdsToVoteWith],
      );
      const { weight, unusedTokenIds } = await adapter.weightOfWithValidTokenIds(
        user1.address,
        proposalId,
        adapterVoteData,
      );
      expect(weight).to.equal(2n * DEFAULT_WEIGHT_PER_NFT);
      expect(unusedTokenIds).to.deep.equal([user1TokenIds[0], user1TokenIds[1]]);
    });

    it('should return correct weight and token IDs, filtering out tokens already used in the proposal', async () => {
      const tokenToUseInitially = user1TokenIds[0];
      const anotherValidToken = user1TokenIds[1];

      const initialAdapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
        ['uint256[]'],
        [[tokenToUseInitially]],
      );
      await adapter
        .connect(strategySigner)
        .recordVote(user1.address, proposalId, initialAdapterVoteData);

      // Now, try to get weight for [tokenToUseInitially, anotherValidToken]
      const tokenIdsForWeightCheck = [tokenToUseInitially, anotherValidToken];
      const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
        ['uint256[]'],
        [tokenIdsForWeightCheck],
      );
      const { weight, unusedTokenIds } = await adapter.weightOfWithValidTokenIds(
        user1.address,
        proposalId,
        adapterVoteData,
      );
      expect(weight).to.equal(1n * DEFAULT_WEIGHT_PER_NFT); // Only anotherValidToken should count
      expect(unusedTokenIds).to.deep.equal([anotherValidToken]);
    });

    it('should correctly handle tokens used in a different proposal', async () => {
      const tokenToUse = user1TokenIds[0];
      const initialAdapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
        ['uint256[]'],
        [[tokenToUse]],
      );
      await adapter
        .connect(strategySigner)
        .recordVote(user1.address, proposalId2, initialAdapterVoteData);

      // Get weight for the same token but for proposalId (different proposal)
      const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
        ['uint256[]'],
        [[tokenToUse]],
      );
      const { weight, unusedTokenIds } = await adapter.weightOfWithValidTokenIds(
        user1.address,
        proposalId,
        adapterVoteData,
      );
      expect(weight).to.equal(1n * DEFAULT_WEIGHT_PER_NFT); // Should be valid for this proposalId
      expect(unusedTokenIds).to.deep.equal([tokenToUse]);
    });

    it('should count duplicate token IDs in _adapterVoteData only once', async () => {
      const tokenIdsToVoteWith = [user1TokenIds[0], user1TokenIds[0], user1TokenIds[1]]; // Duplicate [0]
      const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
        ['uint256[]'],
        [tokenIdsToVoteWith],
      );
      const { weight, unusedTokenIds } = await adapter.weightOfWithValidTokenIds(
        user1.address,
        proposalId,
        adapterVoteData,
      );
      expect(weight).to.equal(2n * DEFAULT_WEIGHT_PER_NFT); // For [0] and [1]
      expect(unusedTokenIds).to.deep.equal([user1TokenIds[0], user1TokenIds[1]]);
    });

    it('should return 0 weight and empty array if _adapterVoteData is empty or decodes to an empty array', async () => {
      const emptyVoteData = ethers.AbiCoder.defaultAbiCoder().encode(['uint256[]'], [[]]);
      const { weight, unusedTokenIds } = await adapter.weightOfWithValidTokenIds(
        user1.address,
        proposalId,
        emptyVoteData,
      );
      expect(weight).to.equal(0n);
      void expect(unusedTokenIds).to.be.an('array').that.is.empty;
    });

    it('should return 0 weight and empty array if voter owns none of the valid provided token IDs', async () => {
      const tokenIdsToVoteWith = [user2TokenIds[0], user2TokenIds[1]]; // Owned by user2
      const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
        ['uint256[]'],
        [tokenIdsToVoteWith],
      );
      const { weight, unusedTokenIds } = await adapter.weightOfWithValidTokenIds(
        user1.address, // User1 tries to get weight
        proposalId,
        adapterVoteData,
      );
      expect(weight).to.equal(0n);
      void expect(unusedTokenIds).to.be.an('array').that.is.empty;
    });

    it('should correctly apply weightPerToken > 1', async () => {
      const customWeightPerToken = 3n;
      const { adapter: customAdapter } = await deployERC721AdapterProxy(
        deployer,
        erc721AdapterImplementationAddressG,
        await mockNft.getAddress(),
        deployer.address,
        customWeightPerToken,
      );

      const tokenIdsToVoteWith = [user1TokenIds[0], user1TokenIds[1]];
      const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
        ['uint256[]'],
        [tokenIdsToVoteWith],
      );
      const { weight, unusedTokenIds } = await customAdapter.weightOfWithValidTokenIds(
        user1.address,
        proposalId,
        adapterVoteData,
      );
      expect(weight).to.equal(BigInt(tokenIdsToVoteWith.length) * customWeightPerToken);
      expect(unusedTokenIds).to.deep.equal(tokenIdsToVoteWith);
    });

    it('should return 0 weight and empty array for a mix of invalid (unowned, used) and non-existent tokens', async () => {
      const usedToken = user1TokenIds[0];
      await adapter
        .connect(strategySigner)
        .recordVote(
          user1.address,
          proposalId,
          ethers.AbiCoder.defaultAbiCoder().encode(['uint256[]'], [[usedToken]]),
        );

      const tokenIdsForWeightCheck = [
        user2TokenIds[0], // Valid, existing token, but unowned by user1
        usedToken, // Valid, existing token, owned by user1, but used for this proposalId
      ];
      const refinedAdapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
        ['uint256[]'],
        [tokenIdsForWeightCheck],
      );

      const { weight, unusedTokenIds } = await adapter.weightOfWithValidTokenIds(
        user1.address,
        proposalId,
        refinedAdapterVoteData,
      );

      expect(weight).to.equal(0n);
      void expect(unusedTokenIds).to.be.an('array').that.is.empty;
    });
  });

  describe('recordVote', () => {
    let adapter: ERC721VotingAdapterV1;
    let mockNft: MockERC721;
    let user1: SignerWithAddress;
    let user1TokenIds: bigint[];
    let user2TokenIds: bigint[];
    let deployer: SignerWithAddress;
    let strategySigner: SignerWithAddress;

    const proposalId = 1;

    beforeEach(async () => {
      const fixture = await loadFixture(deployMocksAndSignersERC721Fixture);
      mockNft = fixture.mockNft;
      user1 = fixture.user1Signer;
      user1TokenIds = fixture.user1TokenIds;
      user2TokenIds = fixture.user2TokenIds;
      deployer = fixture.deployer;
      strategySigner = fixture.strategySigner;

      const { adapter: deployedAdapter } = await deployERC721AdapterProxy(
        deployer,
        erc721AdapterImplementationAddressG,
        await mockNft.getAddress(),
        fixture.strategyAddress,
        DEFAULT_WEIGHT_PER_NFT,
      );
      adapter = deployedAdapter;
    });

    it('should record vote, return casted weight, mark NFTs as used, and emit VoteRecorded event', async () => {
      const tokenIdsToVoteWith = [user1TokenIds[0], user1TokenIds[1]];
      const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
        ['uint256[]'],
        [tokenIdsToVoteWith],
      );
      const expectedWeight = BigInt(tokenIdsToVoteWith.length) * DEFAULT_WEIGHT_PER_NFT;

      await expect(
        adapter.connect(strategySigner).recordVote(user1.address, proposalId, adapterVoteData),
      )
        .to.emit(adapter, 'VoteRecorded')
        .withArgs(user1.address, proposalId, expectedWeight, adapterVoteData);

      void expect(await adapter.tokenIdUsedForVote(proposalId, user1TokenIds[0])).to.be.true;
      void expect(await adapter.tokenIdUsedForVote(proposalId, user1TokenIds[1])).to.be.true;
      if (user1TokenIds.length > 2) {
        void expect(await adapter.tokenIdUsedForVote(proposalId, user1TokenIds[2])).to.be.false;
      }
      const weightAfter = await adapter.weightOf(user1.address, proposalId, adapterVoteData);
      expect(weightAfter).to.equal(0n);
    });

    it('should not allow voting with duplicate token IDs', async () => {
      const tokenToUse = user1TokenIds[0];
      const voteDataSingle = ethers.AbiCoder.defaultAbiCoder().encode(
        ['uint256[]'],
        [[tokenToUse]],
      );
      // First vote
      await adapter.connect(strategySigner).recordVote(user1.address, proposalId, voteDataSingle);

      // Attempt second vote with same token - should revert
      await expect(
        adapter.connect(strategySigner).recordVote(user1.address, proposalId, voteDataSingle),
      )
        .to.be.revertedWithCustomError(adapter, 'TokenIdAlreadyUsedForVote')
        .withArgs(tokenToUse);
    });

    it('should not allow voting with no NFTs provided', async () => {
      const emptyVoteData = ethers.AbiCoder.defaultAbiCoder().encode(['uint256[]'], [[]]);
      await expect(
        adapter.connect(strategySigner).recordVote(user1.address, proposalId, emptyVoteData),
      ).to.be.revertedWithCustomError(adapter, 'NoTokenIdsPassed');
    });

    it('should not allow voting with NFTs not owned by the voter', async () => {
      const tokenIdsNotOwnedByUser1 = [user2TokenIds[0]]; // Owned by user2 (from fixture)
      const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
        ['uint256[]'],
        [tokenIdsNotOwnedByUser1],
      );

      await expect(
        adapter.connect(strategySigner).recordVote(
          user1.address, // Voter is user1
          proposalId,
          adapterVoteData,
        ),
      )
        .to.be.revertedWithCustomError(adapter, 'TokenIdNotOwnedByVoter')
        .withArgs(tokenIdsNotOwnedByUser1[0]);

      // Verify token was not marked as used
      void expect(await adapter.tokenIdUsedForVote(proposalId, user2TokenIds[0])).to.be.false;
    });

    it('should correctly apply custom weightPerNft on recordVote and emit event', async () => {
      const customWeightPerNft = 3n;

      const {
        mockNft: localMockNft,
        user1Signer: localUser1,
        deployer: localProxyDeployer,
      } = await loadFixture(deployMocksAndSignersERC721Fixture);

      // Mint specific tokens for localUser1 on localMockNft
      const localUser1TestTokenIds: bigint[] = [];
      let tokenId1 = await localMockNft.getCurrentTokenId();
      localUser1TestTokenIds.push(tokenId1);
      await localMockNft.mint(localUser1.address);
      let tokenId2 = await localMockNft.getCurrentTokenId();
      localUser1TestTokenIds.push(tokenId2);
      await localMockNft.mint(localUser1.address);

      const { adapter: customAdapter } = await deployERC721AdapterProxy(
        localProxyDeployer, // Proxy deployer
        erc721AdapterImplementationAddressG,
        await localMockNft.getAddress(),
        localProxyDeployer.address, // Initialize customAdapter with localProxyDeployer as strategy
        customWeightPerNft,
      );

      const tokenIdsToUseInVote = [localUser1TestTokenIds[0]];
      const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
        ['uint256[]'],
        [tokenIdsToUseInVote],
      );
      const expectedWeight = BigInt(tokenIdsToUseInVote.length) * customWeightPerNft;

      await expect(
        customAdapter.connect(localProxyDeployer).recordVote(
          localUser1.address, // Actual voter
          proposalId,
          adapterVoteData,
        ),
      )
        .to.emit(customAdapter, 'VoteRecorded')
        .withArgs(localUser1.address, proposalId, expectedWeight, adapterVoteData);

      void expect(await customAdapter.tokenIdUsedForVote(proposalId, tokenIdsToUseInVote[0])).to.be
        .true;
    });
  });

  describe('version()', () => {
    it('should return the correct version', async () => {
      const {
        mockNft,
        deployer: fixtureDeployer,
        strategyAddress,
      } = await loadFixture(deployMocksAndSignersERC721Fixture);
      const { adapter: erc721Adapter } = await deployERC721AdapterProxy(
        fixtureDeployer,
        erc721AdapterImplementationAddressG,
        await mockNft.getAddress(),
        strategyAddress,
        DEFAULT_WEIGHT_PER_NFT,
      );
      expect(await erc721Adapter.version()).to.equal(1);
    });
  });

  describe('State Getters', () => {
    let adapter: ERC721VotingAdapterV1;
    let mockNft: MockERC721;
    let voter1: SignerWithAddress;
    let voter1TokenIds: bigint[];
    let deployerSigner: SignerWithAddress;
    let mockStrategy: MockVotingStrategy;

    const proposalId = 1;
    const PROPOSAL_SNAPSHOT_AND_ID = Math.floor(Date.now() / 1000) - 200;

    beforeEach(async () => {
      const nftFixture = await loadFixture(deployMocksAndSignersERC721Fixture);
      deployerSigner = nftFixture.deployer;
      voter1 = nftFixture.user1Signer;
      voter1TokenIds = nftFixture.user1TokenIds;
      mockNft = nftFixture.mockNft;

      const mockStrategyFactory = new MockVotingStrategy__factory(deployerSigner);
      mockStrategy = await mockStrategyFactory.deploy(deployerSigner.address);
      await mockStrategy.waitForDeployment();

      const { adapter: deployedAdapter } = await deployERC721AdapterProxy(
        deployerSigner,
        erc721AdapterImplementationAddressG,
        await mockNft.getAddress(),
        await mockStrategy.getAddress(),
        DEFAULT_WEIGHT_PER_NFT,
      );
      adapter = deployedAdapter;
      await mockStrategy.setVotingAdapter(await adapter.getAddress(), true);
    });

    describe('tokenIdUsedForVote', () => {
      it('should return false initially', async () => {
        const isUsed = await adapter.tokenIdUsedForVote(proposalId, voter1TokenIds[0]);
        void expect(isUsed).to.be.false;
      });

      it('should return true after a token ID is used to vote', async () => {
        // Encode the vote data for adapter
        const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
          ['uint256[]'],
          [[voter1TokenIds[0]]],
        );

        // Vote through the strategy instead of directly calling the adapter
        // Using connect(voter1) because MockVotingStrategy passes msg.sender as the voter
        await mockStrategy.connect(voter1).vote(
          proposalId,
          0, // voteType
          [await adapter.getAddress()],
          [adapterVoteData],
        );

        // Check the state
        const isUsed = await adapter.tokenIdUsedForVote(proposalId, voter1TokenIds[0]);
        void expect(isUsed).to.be.true;
      });

      it('should only mark the specific proposalId/tokenId combination as used', async () => {
        const anotherProposalId = 2;

        // Encode the vote data
        const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
          ['uint256[]'],
          [[voter1TokenIds[0]]],
        );

        // Vote through the strategy instead of directly calling the adapter
        // Using connect(voter1) because MockVotingStrategy passes msg.sender as the voter
        await mockStrategy.connect(voter1).vote(
          proposalId,
          0, // voteType
          [await adapter.getAddress()],
          [adapterVoteData],
        );

        // Check the original proposal/token ID
        void expect(await adapter.tokenIdUsedForVote(proposalId, voter1TokenIds[0])).to.be.true;

        // Check different combinations
        void expect(await adapter.tokenIdUsedForVote(anotherProposalId, voter1TokenIds[0])).to.be
          .false;
        void expect(await adapter.tokenIdUsedForVote(proposalId, voter1TokenIds[1])).to.be.false;
      });
    });

    describe('tokenIdUsedPerFreezeVoteProposalPerFreezeVoteContract', () => {
      let freezeVoteContract: SignerWithAddress;
      let anotherFreezeVoteContract: SignerWithAddress;

      beforeEach(async () => {
        const signers = await ethers.getSigners();
        freezeVoteContract = signers[4];
        anotherFreezeVoteContract = signers[5];

        // Set up the authorization
        await mockStrategy.addAuthorizedFreezeVoter(freezeVoteContract.address);
      });

      it('should return false initially', async () => {
        const isUsed = await adapter.tokenIdUsedPerFreezeVoteProposalPerFreezeVoteContract(
          freezeVoteContract.address,
          PROPOSAL_SNAPSHOT_AND_ID,
          voter1TokenIds[0],
        );
        void expect(isUsed).to.be.false;
      });

      it('should return true after a token ID is used for a freeze vote', async () => {
        // Encode the vote data
        const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
          ['uint256[]'],
          [[voter1TokenIds[0]]],
        );

        // Record a freeze vote
        await adapter
          .connect(freezeVoteContract)
          .recordFreezeVote(voter1.address, PROPOSAL_SNAPSHOT_AND_ID, adapterVoteData);

        // Check the state
        const isUsed = await adapter.tokenIdUsedPerFreezeVoteProposalPerFreezeVoteContract(
          freezeVoteContract.address,
          PROPOSAL_SNAPSHOT_AND_ID,
          voter1TokenIds[0],
        );
        void expect(isUsed).to.be.true;
      });

      it('should only mark the specific contract/proposalId/tokenId combination as used', async () => {
        const anotherSnapshotId = PROPOSAL_SNAPSHOT_AND_ID + 1000;

        // Encode the vote data
        const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
          ['uint256[]'],
          [[voter1TokenIds[0]]],
        );

        await mockStrategy.addAuthorizedFreezeVoter(anotherFreezeVoteContract.address);

        // Record a freeze vote
        await adapter
          .connect(freezeVoteContract)
          .recordFreezeVote(voter1.address, PROPOSAL_SNAPSHOT_AND_ID, adapterVoteData);

        // Check the original contract/proposal/token ID
        void expect(
          await adapter.tokenIdUsedPerFreezeVoteProposalPerFreezeVoteContract(
            freezeVoteContract.address,
            PROPOSAL_SNAPSHOT_AND_ID,
            voter1TokenIds[0],
          ),
        ).to.be.true;

        // Check different combinations
        void expect(
          await adapter.tokenIdUsedPerFreezeVoteProposalPerFreezeVoteContract(
            anotherFreezeVoteContract.address,
            PROPOSAL_SNAPSHOT_AND_ID,
            voter1TokenIds[0],
          ),
        ).to.be.false;

        void expect(
          await adapter.tokenIdUsedPerFreezeVoteProposalPerFreezeVoteContract(
            freezeVoteContract.address,
            anotherSnapshotId,
            voter1TokenIds[0],
          ),
        ).to.be.false;

        void expect(
          await adapter.tokenIdUsedPerFreezeVoteProposalPerFreezeVoteContract(
            freezeVoteContract.address,
            PROPOSAL_SNAPSHOT_AND_ID,
            voter1TokenIds[1],
          ),
        ).to.be.false;
      });
    });
  });

  describe('ERC165 supportsInterface', () => {
    let erc721Adapter: ERC721VotingAdapterV1;

    beforeEach(async () => {
      const {
        mockNft,
        deployer: fixtureDeployer,
        strategyAddress,
      } = await loadFixture(deployMocksAndSignersERC721Fixture);
      const { adapter } = await deployERC721AdapterProxy(
        fixtureDeployer,
        erc721AdapterImplementationAddressG,
        await mockNft.getAddress(),
        strategyAddress,
        DEFAULT_WEIGHT_PER_NFT,
      );
      erc721Adapter = adapter;
    });

    it('should support IERC721VotingAdapterV1', async () => {
      void expect(
        await erc721Adapter.supportsInterface(
          calculateInterfaceId(IERC721VotingAdapterV1__factory.createInterface()),
        ),
      ).to.be.true;
    });

    it('should support IBaseVotingAdapterV1', async () => {
      void expect(
        await erc721Adapter.supportsInterface(
          calculateInterfaceId(IBaseVotingAdapterV1__factory.createInterface()),
        ),
      ).to.be.true;
    });

    it('should support IVersion', async () => {
      void expect(
        await erc721Adapter.supportsInterface(
          calculateInterfaceId(IVersion__factory.createInterface()),
        ),
      ).to.be.true;
    });

    it('should support IERC165', async () => {
      void expect(
        await erc721Adapter.supportsInterface(
          calculateInterfaceId(IERC165__factory.createInterface()),
        ),
      ).to.be.true;
    });

    it('should not support a random interfaceId', async () => {
      void expect(await erc721Adapter.supportsInterface('0x12345678')).to.be.false;
    });
  });

  // New Test Suite for Freeze Voting
  describe('Freeze Voting', () => {
    let adapter: ERC721VotingAdapterV1;
    let mockNft: MockERC721;
    let mockStrategy: MockVotingStrategy;
    let deployerSigner: SignerWithAddress;
    let voter1: SignerWithAddress;
    let voter2: SignerWithAddress;
    let authorizedCaller: SignerWithAddress;
    let unauthorizedCaller: SignerWithAddress;
    let user1InitialTokenIds: bigint[];

    const PROPOSAL_SNAPSHOT_AND_ID_1 = Math.floor(Date.now() / 1000) - 200;
    const PROPOSAL_SNAPSHOT_AND_ID_2 = PROPOSAL_SNAPSHOT_AND_ID_1 + 50000;
    const WEIGHT_PER_NFT_FOR_TESTS = 2n;

    beforeEach(async () => {
      const nftFixture = await loadFixture(deployMocksAndSignersERC721Fixture);
      deployerSigner = nftFixture.deployer;
      voter1 = nftFixture.user1Signer;
      voter2 = nftFixture.user2Signer;
      authorizedCaller = voter2;
      mockNft = nftFixture.mockNft;
      user1InitialTokenIds = nftFixture.user1TokenIds;

      const signers = await ethers.getSigners();
      unauthorizedCaller = signers[3];

      const mockStrategyFactory = new MockVotingStrategy__factory(deployerSigner);
      mockStrategy = await mockStrategyFactory.deploy(deployerSigner.address);
      await mockStrategy.waitForDeployment();

      const { adapter: deployedAdapter } = await deployERC721AdapterProxy(
        deployerSigner,
        erc721AdapterImplementationAddressG,
        await mockNft.getAddress(),
        await mockStrategy.getAddress(),
        WEIGHT_PER_NFT_FOR_TESTS,
      );
      adapter = deployedAdapter;
      await mockStrategy.setVotingAdapter(await adapter.getAddress(), true);
    });

    describe('getFreezeVoteWeight', () => {
      it('should return correct weight for owned, unused token IDs', async () => {
        const tokenIdsToUse = [user1InitialTokenIds[0], user1InitialTokenIds[1]];
        const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
          ['uint256[]'],
          [tokenIdsToUse],
        );

        const weight = await adapter
          .connect(authorizedCaller)
          .getFreezeVoteWeight(
            voter1.address,
            authorizedCaller.address,
            PROPOSAL_SNAPSHOT_AND_ID_1,
            adapterVoteData,
          );
        expect(weight).to.equal(BigInt(tokenIdsToUse.length) * WEIGHT_PER_NFT_FOR_TESTS);
      });

      it('should return 0 if adapterVoteData is empty', async () => {
        const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(['uint256[]'], [[]]);
        const weight = await adapter
          .connect(authorizedCaller)
          .getFreezeVoteWeight(
            voter1.address,
            authorizedCaller.address,
            PROPOSAL_SNAPSHOT_AND_ID_1,
            adapterVoteData,
          );
        expect(weight).to.equal(0n);
      });

      it('should filter out unowned token IDs', async () => {
        const unownedTokenId = 999999n; // A non-existent token ID
        const tokenIdsToUse = [user1InitialTokenIds[0], unownedTokenId];
        const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
          ['uint256[]'],
          [tokenIdsToUse],
        );
        // This test now expects a revert from the token contract when a non-existent token is encountered.
        await expect(
          adapter
            .connect(authorizedCaller)
            .getFreezeVoteWeight(
              voter1.address,
              authorizedCaller.address,
              PROPOSAL_SNAPSHOT_AND_ID_1,
              adapterVoteData,
            ),
        )
          .to.be.revertedWithCustomError(mockNft, 'ERC721NonexistentToken')
          .withArgs(unownedTokenId);
      });

      it('should count duplicate token IDs only once', async () => {
        const tokenIdsToUse = [
          user1InitialTokenIds[0],
          user1InitialTokenIds[0],
          user1InitialTokenIds[1],
        ];
        const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
          ['uint256[]'],
          [tokenIdsToUse],
        );
        const weight = await adapter
          .connect(authorizedCaller)
          .getFreezeVoteWeight(
            voter1.address,
            authorizedCaller.address,
            PROPOSAL_SNAPSHOT_AND_ID_1,
            adapterVoteData,
          );
        expect(weight).to.equal(2n * WEIGHT_PER_NFT_FOR_TESTS); // Counts for tokenIds[0] and tokenIds[1]
      });

      it('should not alter freeze voting state (tokens can still be used for recordFreezeVote)', async () => {
        const tokenIdsToUse = [user1InitialTokenIds[0]];
        const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
          ['uint256[]'],
          [tokenIdsToUse],
        );

        await adapter
          .connect(authorizedCaller)
          .getFreezeVoteWeight(
            voter1.address,
            authorizedCaller.address,
            PROPOSAL_SNAPSHOT_AND_ID_1,
            adapterVoteData,
          );

        // Authorize and attempt to record vote with the same token
        await mockStrategy.addAuthorizedFreezeVoter(authorizedCaller.address);
        await expect(
          adapter
            .connect(authorizedCaller)
            .recordFreezeVote(voter1.address, PROPOSAL_SNAPSHOT_AND_ID_1, adapterVoteData),
        )
          .to.emit(adapter, 'FreezeVoteRecorded')
          .withArgs(
            voter1.address,
            PROPOSAL_SNAPSHOT_AND_ID_1,
            1n * WEIGHT_PER_NFT_FOR_TESTS,
            adapterVoteData,
          );
      });

      it('should return 0 if all provided token IDs are already used for this snapshotAndId by this caller', async () => {
        const tokenIdsToUse = [user1InitialTokenIds[0]];
        const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
          ['uint256[]'],
          [tokenIdsToUse],
        );

        await mockStrategy.addAuthorizedFreezeVoter(authorizedCaller.address);
        await adapter
          .connect(authorizedCaller)
          .recordFreezeVote(voter1.address, PROPOSAL_SNAPSHOT_AND_ID_1, adapterVoteData);

        const weight = await adapter
          .connect(authorizedCaller)
          .getFreezeVoteWeight(
            voter1.address,
            authorizedCaller.address,
            PROPOSAL_SNAPSHOT_AND_ID_1,
            adapterVoteData,
          );
        expect(weight).to.equal(0n);
      });

      it('should still return weight if tokens were used for a different snapshotAndId', async () => {
        const tokenIdsToUse = [user1InitialTokenIds[0]];
        const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
          ['uint256[]'],
          [tokenIdsToUse],
        );

        await mockStrategy.addAuthorizedFreezeVoter(authorizedCaller.address);
        // Record vote for PROPOSAL_SNAPSHOT_AND_ID_1
        await adapter
          .connect(authorizedCaller)
          .recordFreezeVote(voter1.address, PROPOSAL_SNAPSHOT_AND_ID_1, adapterVoteData);

        // Get weight for PROPOSAL_SNAPSHOT_AND_ID_2
        const weight = await adapter
          .connect(authorizedCaller)
          .getFreezeVoteWeight(
            voter1.address,
            authorizedCaller.address,
            PROPOSAL_SNAPSHOT_AND_ID_2,
            adapterVoteData,
          );
        expect(weight).to.equal(BigInt(tokenIdsToUse.length) * WEIGHT_PER_NFT_FOR_TESTS);
      });

      it('should still return weight if tokens were used by a different authorized caller for the same snapshotAndId', async () => {
        const tokenIdsToUse = [user1InitialTokenIds[0]];
        const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
          ['uint256[]'],
          [tokenIdsToUse],
        );

        await mockStrategy.addAuthorizedFreezeVoter(unauthorizedCaller.address); // Using unauthorizedCaller as a 'different' authorized caller
        await adapter
          .connect(unauthorizedCaller)
          .recordFreezeVote(voter1.address, PROPOSAL_SNAPSHOT_AND_ID_1, adapterVoteData);

        // authorizedCaller (original one) tries to get weight
        const weight = await adapter
          .connect(authorizedCaller)
          .getFreezeVoteWeight(
            voter1.address,
            authorizedCaller.address,
            PROPOSAL_SNAPSHOT_AND_ID_1,
            adapterVoteData,
          );
        expect(weight).to.equal(BigInt(tokenIdsToUse.length) * WEIGHT_PER_NFT_FOR_TESTS);
      });
    });

    describe('recordFreezeVote', () => {
      const ZERO_EXTRA_DATA_BYTES = ethers.AbiCoder.defaultAbiCoder().encode(['uint256[]'], [[]]);

      it('should revert with UnauthorizedFreezeVoter if caller is not authorized', async () => {
        const tokenIdsToUse = [user1InitialTokenIds[0]];
        const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
          ['uint256[]'],
          [tokenIdsToUse],
        );
        await expect(
          adapter
            .connect(unauthorizedCaller)
            .recordFreezeVote(voter1.address, PROPOSAL_SNAPSHOT_AND_ID_1, adapterVoteData),
        )
          .to.be.revertedWithCustomError(adapter, 'UnauthorizedFreezeVoter')
          .withArgs(unauthorizedCaller.address);
      });

      it('should record vote, mark tokens as used, and emit FreezeVoteRecorded on success', async () => {
        await mockStrategy.addAuthorizedFreezeVoter(authorizedCaller.address);
        const tokenIdsToUse = [user1InitialTokenIds[0], user1InitialTokenIds[1]];
        const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
          ['uint256[]'],
          [tokenIdsToUse],
        );
        const expectedWeightCasted = BigInt(tokenIdsToUse.length) * WEIGHT_PER_NFT_FOR_TESTS;

        await expect(
          adapter
            .connect(authorizedCaller)
            .recordFreezeVote(voter1.address, PROPOSAL_SNAPSHOT_AND_ID_1, adapterVoteData),
        )
          .to.emit(adapter, 'FreezeVoteRecorded')
          .withArgs(
            voter1.address,
            PROPOSAL_SNAPSHOT_AND_ID_1,
            expectedWeightCasted,
            adapterVoteData,
          );

        // Verify tokens are marked as used for this specific freeze proposal context
        // Need a way to check _freezeVoteTokenIdUsedPerChildPerProposal or infer from getFreezeVoteWeight
        const weightAfter = await adapter
          .connect(authorizedCaller)
          .getFreezeVoteWeight(
            voter1.address,
            authorizedCaller.address,
            PROPOSAL_SNAPSHOT_AND_ID_1,
            adapterVoteData,
          );
        expect(weightAfter).to.equal(0n);
      });

      it('should revert with NoTokenIdsPassed if adapterVoteData is empty', async () => {
        await mockStrategy.addAuthorizedFreezeVoter(authorizedCaller.address);
        await expect(
          adapter
            .connect(authorizedCaller)
            .recordFreezeVote(voter1.address, PROPOSAL_SNAPSHOT_AND_ID_1, ZERO_EXTRA_DATA_BYTES),
        ).to.be.revertedWithCustomError(adapter, 'NoTokenIdsPassed');
      });

      it('should revert with NoFreezeVotingWeight if _weightPerToken is 0', async () => {
        const { adapter: zeroWeightAdapter } = await deployERC721AdapterProxy(
          deployerSigner,
          erc721AdapterImplementationAddressG,
          await mockNft.getAddress(),
          await mockStrategy.getAddress(),
          0n, // Zero weight per NFT
        );
        await mockStrategy.setVotingAdapter(await zeroWeightAdapter.getAddress(), true);
        await mockStrategy.addAuthorizedFreezeVoter(authorizedCaller.address);
        const tokenIdsToUse = [user1InitialTokenIds[0]];
        const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
          ['uint256[]'],
          [tokenIdsToUse],
        );

        await expect(
          zeroWeightAdapter
            .connect(authorizedCaller)
            .recordFreezeVote(voter1.address, PROPOSAL_SNAPSHOT_AND_ID_1, adapterVoteData),
        ).to.be.revertedWithCustomError(zeroWeightAdapter, 'NoFreezeVotingWeight');
      });

      it('should revert if a token ID is non-existent (during recordFreezeVote)', async () => {
        await mockStrategy.addAuthorizedFreezeVoter(authorizedCaller.address);
        const nonExistentTokenId = (await mockNft.getCurrentTokenId()) + 1n;
        const tokenIdsToUse = [user1InitialTokenIds[0], nonExistentTokenId];
        const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
          ['uint256[]'],
          [tokenIdsToUse],
        );

        await expect(
          adapter
            .connect(authorizedCaller)
            .recordFreezeVote(voter1.address, PROPOSAL_SNAPSHOT_AND_ID_1, adapterVoteData),
        )
          // Expecting the revert from the ERC721 token itself for a non-existent token
          .to.be.revertedWithCustomError(mockNft, 'ERC721NonexistentToken')
          .withArgs(nonExistentTokenId);
      });

      it('should revert with TokenIdNotOwnedByVoter if voter does not own an existing token ID', async () => {
        await mockStrategy.addAuthorizedFreezeVoter(authorizedCaller.address);
        // Mint a token specifically for another user (voter2)
        const voter2TokenId = await mockNft.getCurrentTokenId();
        await mockNft.mint(voter2.address); // voter2 now owns voter2TokenId

        const tokenIdsToUse = [voter2TokenId]; // voter1 attempts to use voter2's token
        const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
          ['uint256[]'],
          [tokenIdsToUse],
        );

        await expect(
          adapter
            .connect(authorizedCaller) // Call is authorized
            .recordFreezeVote(voter1.address, PROPOSAL_SNAPSHOT_AND_ID_1, adapterVoteData),
        ) // voter1 attempts to vote with voter2's token
          .to.be.revertedWithCustomError(adapter, 'TokenIdNotOwnedByVoter')
          .withArgs(voter2TokenId);
      });

      describe('Duplicate Vote Prevention for recordFreezeVote', () => {
        beforeEach(async () => {
          await mockStrategy.addAuthorizedFreezeVoter(authorizedCaller.address);
          // user1InitialTokenIds[0] and user1InitialTokenIds[1] are available for voter1
        });

        it('should revert with TokenIdAlreadyUsedForVote if a token ID is used twice for same caller & snapshotId', async () => {
          const tokenIdToUse = user1InitialTokenIds[0];
          const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
            ['uint256[]'],
            [[tokenIdToUse]],
          );
          await adapter
            .connect(authorizedCaller)
            .recordFreezeVote(voter1.address, PROPOSAL_SNAPSHOT_AND_ID_1, adapterVoteData);

          await expect(
            adapter
              .connect(authorizedCaller)
              .recordFreezeVote(voter1.address, PROPOSAL_SNAPSHOT_AND_ID_1, adapterVoteData),
          )
            .to.be.revertedWithCustomError(adapter, 'TokenIdAlreadyUsedForVote')
            .withArgs(tokenIdToUse);
        });

        it('should allow same token ID if snapshotAndId is different', async () => {
          const tokenIdToUse = user1InitialTokenIds[0];
          const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
            ['uint256[]'],
            [[tokenIdToUse]],
          );
          await adapter
            .connect(authorizedCaller)
            .recordFreezeVote(voter1.address, PROPOSAL_SNAPSHOT_AND_ID_1, adapterVoteData);

          await expect(
            adapter
              .connect(authorizedCaller)
              .recordFreezeVote(voter1.address, PROPOSAL_SNAPSHOT_AND_ID_2, adapterVoteData),
          ).to.emit(adapter, 'FreezeVoteRecorded');
        });

        it('should allow same token ID and snapshotAndId if caller is different', async () => {
          const tokenIdToUse = user1InitialTokenIds[0];
          const adapterVoteData = ethers.AbiCoder.defaultAbiCoder().encode(
            ['uint256[]'],
            [[tokenIdToUse]],
          );
          await mockStrategy.addAuthorizedFreezeVoter(unauthorizedCaller.address); // unauthorizedCaller acts as another authorized caller

          await adapter
            .connect(authorizedCaller)
            .recordFreezeVote(voter1.address, PROPOSAL_SNAPSHOT_AND_ID_1, adapterVoteData);

          await expect(
            adapter
              .connect(unauthorizedCaller)
              .recordFreezeVote(voter1.address, PROPOSAL_SNAPSHOT_AND_ID_1, adapterVoteData),
          ).to.emit(adapter, 'FreezeVoteRecorded');
        });

        it('should allow different token IDs from the same voter for the same proposal context', async () => {
          const tokenId1 = user1InitialTokenIds[0];
          const tokenId2 = user1InitialTokenIds[1];
          const adapterVoteData1 = ethers.AbiCoder.defaultAbiCoder().encode(
            ['uint256[]'],
            [[tokenId1]],
          );
          const adapterVoteData2 = ethers.AbiCoder.defaultAbiCoder().encode(
            ['uint256[]'],
            [[tokenId2]],
          );

          await adapter
            .connect(authorizedCaller)
            .recordFreezeVote(voter1.address, PROPOSAL_SNAPSHOT_AND_ID_1, adapterVoteData1);
          await expect(
            adapter
              .connect(authorizedCaller)
              .recordFreezeVote(voter1.address, PROPOSAL_SNAPSHOT_AND_ID_1, adapterVoteData2),
          ).to.emit(adapter, 'FreezeVoteRecorded');
        });
      });
    });
  });
});
