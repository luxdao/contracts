import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { loadFixture } from '@nomicfoundation/hardhat-toolbox/network-helpers';
import { expect } from 'chai';
import type { AddressLike, BigNumberish, ContractTransactionReceipt } from 'ethers';
import { ethers } from 'hardhat';
import {
  FreezeGuardAzoriusV1__factory,
  FreezeGuardMultisigV1__factory,
  FreezeVotingAzoriusV1__factory,
  FreezeVotingMultisigV1__factory,
  ISystemDeployer,
  ModuleAzoriusV1,
  ModuleAzoriusV1__factory,
  ModuleFractalV1__factory,
  ProposerAdapterERC20V1,
  ProposerAdapterERC20V1__factory,
  ProposerAdapterERC721V1,
  ProposerAdapterERC721V1__factory,
  ProposerAdapterHatsV1,
  ProposerAdapterHatsV1__factory,
  Safe,
  Safe__factory,
  SafeProxyFactory,
  SafeProxyFactory__factory,
  StrategyV1,
  StrategyV1__factory,
  SystemDeployer,
  SystemDeployer__factory,
  VotesERC20LockableV1,
  VotesERC20LockableV1__factory,
  VotesERC20V1,
  VotesERC20V1__factory,
  VotingAdapterERC20V1,
  VotingAdapterERC20V1__factory,
  VotingAdapterERC721V1,
  VotingAdapterERC721V1__factory,
} from '../../typechain-types';

// Helper function to create default setupSafe parameters with optional overrides
function createSetupSafeParams(overrides?: {
  votesERC20Params?: Partial<ISystemDeployer.VotesERC20ParamsStruct>;
  azoriusGovernanceParams?: Partial<ISystemDeployer.AzoriusGovernanceParamsStruct>;
  moduleFractalParams?: Partial<ISystemDeployer.ModuleFractalV1ParamsStruct>;
  freezeGuardMultisigParams?: Partial<ISystemDeployer.FreezeGuardMultisigV1ParamsStruct>;
  freezeGuardAzoriusParams?: Partial<ISystemDeployer.FreezeGuardAzoriusV1ParamsStruct>;
  freezeVotingMultisigParams?: Partial<ISystemDeployer.FreezeVotingMultisigV1ParamsStruct>;
  freezeVotingAzoriusParams?: Partial<ISystemDeployer.FreezeVotingAzoriusV1ParamsStruct>;
}) {
  // Default Votes ERC20 params (all empty/zero)
  const votesERC20Params: ISystemDeployer.VotesERC20ParamsStruct = {
    votesERC20V1Params: [],
    votesERC20LockableV1Params: [],
    ...overrides?.votesERC20Params,
  };

  // Default Azorius governance params (all empty/zero)
  const azoriusGovernanceParams: ISystemDeployer.AzoriusGovernanceParamsStruct = {
    proposerAdapterParams: {
      proposerAdapterERC20V1Params: [],
      proposerAdapterERC721V1Params: [],
      proposerAdapterHatsV1Params: [],
    },
    strategyV1Params: {
      implementation: ethers.ZeroAddress,
      votingPeriod: 0,
      quorumThreshold: 0,
      basisNumerator: 0,
      lightAccountFactory: ethers.ZeroAddress,
    },
    votingAdapterParams: {
      votingAdapterERC20V1Params: [],
      votingAdapterERC721V1Params: [],
    },
    moduleAzoriusV1Params: {
      implementation: ethers.ZeroAddress,
      timelockPeriod: 0,
      executionPeriod: 0,
    },
    ...overrides?.azoriusGovernanceParams,
  };

  // Default ModuleFractal params (all empty/zero)
  const moduleFractalV1Params: ISystemDeployer.ModuleFractalV1ParamsStruct = {
    implementation: ethers.ZeroAddress,
    owner: ethers.ZeroAddress,
    ...overrides?.moduleFractalParams,
  };

  // Default Freeze params (all empty/zero)
  const freezeParams: ISystemDeployer.FreezeParamsStruct = {
    freezeGuardParams: {
      freezeGuardMultisigV1Params: {
        implementation: ethers.ZeroAddress,
        owner: ethers.ZeroAddress,
        timelockPeriod: 0,
        executionPeriod: 0,
        ...overrides?.freezeGuardMultisigParams,
      },
      freezeGuardAzoriusV1Params: {
        implementation: ethers.ZeroAddress,
        owner: ethers.ZeroAddress,
        ...overrides?.freezeGuardAzoriusParams,
      },
    },
    freezeVotingParams: {
      freezeVotingMultisigV1Params: {
        implementation: ethers.ZeroAddress,
        owner: ethers.ZeroAddress,
        freezeVotesThreshold: 0,
        freezeProposalPeriod: 0,
        freezePeriod: 0,
        parentSafe: ethers.ZeroAddress,
        lightAccountFactory: ethers.ZeroAddress,
        ...overrides?.freezeVotingMultisigParams,
      },
      freezeVotingAzoriusV1Params: {
        implementation: ethers.ZeroAddress,
        owner: ethers.ZeroAddress,
        freezeVotesThreshold: 0,
        freezeProposalPeriod: 0,
        freezePeriod: 0,
        parentAzorius: ethers.ZeroAddress,
        lightAccountFactory: ethers.ZeroAddress,
        ...overrides?.freezeVotingAzoriusParams,
      },
    },
  };

  return {
    votesERC20Params,
    azoriusGovernanceParams,
    moduleFractalV1Params,
    freezeParams,
  };
}

// Helper function to deploy a Safe proxy with setupSafe initialization
async function deploySafeWithSetup(params: {
  fixtureData: {
    systemDeployer: SystemDeployer;
    safe: Safe;
    safeProxyFactory: SafeProxyFactory;
    deployer: SignerWithAddress;
  };
  owners: string[];
  threshold: number;
  setupSafeParams: {
    votesERC20Params: ISystemDeployer.VotesERC20ParamsStruct;
    azoriusGovernanceParams: ISystemDeployer.AzoriusGovernanceParamsStruct;
    moduleFractalV1Params: ISystemDeployer.ModuleFractalV1ParamsStruct;
    freezeParams: ISystemDeployer.FreezeParamsStruct;
  };
}) {
  const { fixtureData, owners, threshold, setupSafeParams } = params;

  // Create a salt that will be used for both Safe proxy creation and setupSafe
  const saltNonce = ethers.toBigInt(ethers.randomBytes(32));
  const salt = ethers.solidityPackedKeccak256(['uint256'], [saltNonce]);

  // Encode setupSafe function call
  const setupSafeData = fixtureData.systemDeployer.interface.encodeFunctionData('setupSafe', [
    salt,
    setupSafeParams.votesERC20Params,
    setupSafeParams.azoriusGovernanceParams,
    setupSafeParams.moduleFractalV1Params,
    setupSafeParams.freezeParams,
  ]);

  // Create Safe setup parameters
  const to = await fixtureData.systemDeployer.getAddress();
  const data = setupSafeData;
  const fallbackHandler = ethers.ZeroAddress;
  const paymentToken = ethers.ZeroAddress;
  const payment = 0;
  const paymentReceiver = ethers.ZeroAddress;

  // Encode Safe setup function call
  const safeSetupData = fixtureData.safe.interface.encodeFunctionData('setup', [
    owners,
    threshold,
    to,
    data,
    fallbackHandler,
    paymentToken,
    payment,
    paymentReceiver,
  ]);

  // Predict the Safe Address using CREATE2
  const safeAddress = ethers.getCreate2Address(
    await fixtureData.safeProxyFactory.getAddress(),
    ethers.keccak256(
      ethers.solidityPacked(
        ['bytes', 'uint256'],
        [ethers.keccak256(ethers.solidityPacked(['bytes'], [safeSetupData])), saltNonce],
      ),
    ),
    ethers.keccak256(
      ethers.solidityPacked(
        ['bytes', 'uint256'],
        [
          await fixtureData.safeProxyFactory.proxyCreationCode(),
          await fixtureData.safe.getAddress(),
        ],
      ),
    ),
  );

  // Create Safe proxy with the same salt nonce
  const tx = await fixtureData.safeProxyFactory.createProxyWithNonce(
    await fixtureData.safe.getAddress(),
    safeSetupData,
    saltNonce,
  );

  const receipt = await tx.wait();

  if (!receipt) {
    throw new Error('No receipt found');
  }

  return { safeAddress, receipt };
}

// Helper function to verify the Safe configuration
async function verifySafeConfiguration(params: {
  fixtureData: {
    systemDeployer: SystemDeployer;
    safeProxyFactory: SafeProxyFactory;
    safe: Safe;
    deployer: SignerWithAddress;
  };
  receipt: ContractTransactionReceipt;
  safeAddress: string;
  owners: string[];
  threshold: number;
}) {
  const { fixtureData, receipt, safeAddress, owners, threshold } = params;

  // Find ProxyCreation event
  const proxyCreationEvent = receipt.logs.find(log => {
    try {
      const parsedLog = fixtureData.safeProxyFactory.interface.parseLog({
        topics: log.topics,
        data: log.data,
      });
      return parsedLog?.name === 'ProxyCreation';
    } catch {
      return false;
    }
  });

  void expect(proxyCreationEvent).to.not.be.undefined;

  if (!proxyCreationEvent) {
    throw new Error('Proxy creation event not found');
  }

  const parsedProxyEvent = fixtureData.safeProxyFactory.interface.parseLog({
    topics: proxyCreationEvent.topics,
    data: proxyCreationEvent.data,
  });

  if (!parsedProxyEvent) {
    throw new Error('Proxy creation event not found');
  }

  expect(parsedProxyEvent.args[0]).to.equal(safeAddress);
  expect(parsedProxyEvent.args[1]).to.equal(await fixtureData.safe.getAddress());

  // Connect to the Safe proxy
  const safeProxy = Safe__factory.connect(safeAddress, fixtureData.deployer);

  // Verify threshold
  expect(await safeProxy.getThreshold()).to.equal(threshold);

  // Verify owners
  const safeOwners = await safeProxy.getOwners();
  expect(safeOwners).to.have.lengthOf(owners.length);

  // Check each expected owner is included
  for (const expectedOwner of owners) {
    expect(safeOwners).to.include(expectedOwner);
  }
}

// Helper function to find all proxies deployed in a transaction receipt
async function findProxiesDeployed(params: {
  fixtureData: {
    systemDeployer: SystemDeployer;
  };
  receipt: ContractTransactionReceipt;
  implementation: AddressLike;
}) {
  const { fixtureData, receipt, implementation } = params;

  const proxyDeployedEvents = receipt?.logs.filter(log => {
    try {
      const parsedLog = fixtureData.systemDeployer.interface.parseLog({
        topics: log.topics,
        data: log.data,
      });
      return parsedLog?.name === 'ProxyDeployed';
    } catch {
      return false;
    }
  });

  // Find the proxy (matching the implementation address)
  let proxyAddresses: string[] = [];
  for (const event of proxyDeployedEvents || []) {
    const parsedProxyEvent = fixtureData.systemDeployer.interface.parseLog({
      topics: event.topics,
      data: event.data,
    });
    if (parsedProxyEvent?.args[1] === implementation) {
      proxyAddresses.push(parsedProxyEvent.args[0]);
    }
  }

  if (proxyAddresses.length === 0) {
    throw new Error(
      `Proxies not found for implementation ${implementation} in transaction receipt`,
    );
  }

  return proxyAddresses;
}

// Helper function to find and verify a single proxy deployment
async function findProxyDeployed(params: {
  fixtureData: {
    systemDeployer: SystemDeployer;
  };
  receipt: ContractTransactionReceipt;
  implementation: AddressLike;
}) {
  const proxyAddresses = await findProxiesDeployed(params);

  if (proxyAddresses.length > 1) {
    throw new Error(
      `Multiple proxies found for implementation ${params.implementation} in transaction receipt`,
    );
  }

  return proxyAddresses[0];
}

// Helper function to find and verify VotesERC20V1 deployment and configuration
async function findAndVerifyVotesERC20V1s(params: {
  fixtureData: {
    systemDeployer: SystemDeployer;
    deployer: SignerWithAddress;
  };
  receipt: ContractTransactionReceipt;
  implementation: string;
  safeAddress: string;
  votesERC20V1Datas: {
    metadata: {
      name: string;
      symbol: string;
    };
    allocations: {
      to: AddressLike;
      amount: BigNumberish;
    }[];
    safeSupply: BigNumberish;
  }[];
}) {
  const { fixtureData, receipt, implementation, safeAddress, votesERC20V1Datas } = params;

  const votesERC20Addresses = await findProxiesDeployed({
    fixtureData,
    receipt,
    implementation,
  });

  if (votesERC20Addresses.length !== votesERC20V1Datas.length) {
    throw new Error(`Number of votes ERC20s does not match number of votes ERC20 datas`);
  }

  for (let i = 0; i < votesERC20Addresses.length; i++) {
    const votesERC20V1Address = votesERC20Addresses[i];
    const votesERC20V1Data = votesERC20V1Datas[i];

    const votesERC20V1Proxy = VotesERC20V1__factory.connect(
      votesERC20V1Address,
      fixtureData.deployer,
    );

    expect(await votesERC20V1Proxy.name()).to.equal(votesERC20V1Data.metadata.name);
    expect(await votesERC20V1Proxy.symbol()).to.equal(votesERC20V1Data.metadata.symbol);
    expect(await votesERC20V1Proxy.owner()).to.equal(safeAddress);
    for (const allocation of votesERC20V1Data.allocations) {
      expect(await votesERC20V1Proxy.balanceOf(allocation.to)).to.equal(allocation.amount);
    }
    expect(await votesERC20V1Proxy.balanceOf(safeAddress)).to.equal(votesERC20V1Data.safeSupply);
  }

  return votesERC20Addresses.map(address =>
    VotesERC20V1__factory.connect(address, fixtureData.deployer),
  );
}

// Helper function to find and verify VotesERC20V1 deployment and configuration
async function findAndVerifyVotesERC20LockableV1s(params: {
  fixtureData: {
    systemDeployer: SystemDeployer;
    deployer: SignerWithAddress;
  };
  receipt: ContractTransactionReceipt;
  implementation: string;
  safeAddress: string;
  votesERC20LockableV1Datas: {
    metadata: {
      name: string;
      symbol: string;
    };
    allocations: {
      to: AddressLike;
      amount: BigNumberish;
    }[];
    locked: boolean;
    maxTotalSupply: BigNumberish;
    safeSupply: BigNumberish;
  }[];
}) {
  const { fixtureData, receipt, implementation, safeAddress, votesERC20LockableV1Datas } = params;

  const votesERC20LockableAddresses = await findProxiesDeployed({
    fixtureData,
    receipt,
    implementation,
  });

  if (votesERC20LockableAddresses.length !== votesERC20LockableV1Datas.length) {
    throw new Error(
      `Number of votes ERC20 lockables does not match number of votes ERC20 lockable datas`,
    );
  }

  for (let i = 0; i < votesERC20LockableAddresses.length; i++) {
    const votesERC20V1LockableAddress = votesERC20LockableAddresses[i];
    const votesERC20V1LockableData = votesERC20LockableV1Datas[i];

    const votesERC20LockableV1Proxy = VotesERC20LockableV1__factory.connect(
      votesERC20V1LockableAddress,
      fixtureData.deployer,
    );

    expect(await votesERC20LockableV1Proxy.name()).to.equal(votesERC20V1LockableData.metadata.name);
    expect(await votesERC20LockableV1Proxy.symbol()).to.equal(
      votesERC20V1LockableData.metadata.symbol,
    );
    expect(await votesERC20LockableV1Proxy.owner()).to.equal(safeAddress);
    for (const allocation of votesERC20V1LockableData.allocations) {
      expect(await votesERC20LockableV1Proxy.balanceOf(allocation.to)).to.equal(allocation.amount);
    }
    expect(await votesERC20LockableV1Proxy.balanceOf(safeAddress)).to.equal(
      votesERC20V1LockableData.safeSupply,
    );
  }

  return votesERC20LockableAddresses.map(address =>
    VotesERC20LockableV1__factory.connect(address, fixtureData.deployer),
  );
}

// Helper function to find and verify ModuleFractal deployment and configuration
async function findAndVerifyModuleFractalV1(params: {
  fixtureData: {
    systemDeployer: SystemDeployer;
    deployer: SignerWithAddress;
  };
  receipt: ContractTransactionReceipt;
  implementation: AddressLike;
  safeAddress: string;
  owner: AddressLike;
}) {
  const { fixtureData, receipt, implementation, safeAddress, owner } = params;

  const moduleFractalAddress = await findProxyDeployed({ fixtureData, receipt, implementation });

  // Verify the module is enabled on the Safe
  const safeProxy = Safe__factory.connect(safeAddress, fixtureData.deployer);
  const isModuleEnabled = await safeProxy.isModuleEnabled(moduleFractalAddress);
  void expect(isModuleEnabled).to.be.true;

  // Connect to the deployed ModuleFractal proxy
  const moduleFractalProxy = ModuleFractalV1__factory.connect(
    moduleFractalAddress,
    fixtureData.deployer,
  );

  // Verify ModuleFractal was initialized correctly
  expect(await moduleFractalProxy.owner()).to.equal(owner);
  expect(await moduleFractalProxy.avatar()).to.equal(safeAddress);
  expect(await moduleFractalProxy.getFunction('target')()).to.equal(safeAddress);

  return moduleFractalProxy;
}

// Helper function to find and verify ModuleAzoriusV1 deployment and configuration
async function findAndVerifyModuleAzoriusV1(params: {
  fixtureData: {
    systemDeployer: SystemDeployer;
    deployer: SignerWithAddress;
  };
  receipt: ContractTransactionReceipt;
  implementation: AddressLike;
  safeAddress: string;
  owner: string;
  strategy: string;
  timelockPeriod: BigNumberish;
  executionPeriod: BigNumberish;
}) {
  const {
    fixtureData,
    receipt,
    implementation,
    safeAddress,
    owner,
    strategy,
    timelockPeriod,
    executionPeriod,
  } = params;

  const azoriusAddress = await findProxyDeployed({
    fixtureData,
    receipt,
    implementation,
  });

  // Verify the module is enabled on the Safe
  const safeProxy = Safe__factory.connect(safeAddress, fixtureData.deployer);
  const isModuleEnabled = await safeProxy.isModuleEnabled(azoriusAddress);
  void expect(isModuleEnabled).to.be.true;

  const azoriusProxy = ModuleAzoriusV1__factory.connect(azoriusAddress, fixtureData.deployer);

  expect(await azoriusProxy.owner()).to.equal(owner);
  expect(await azoriusProxy.avatar()).to.equal(safeAddress);
  expect(await azoriusProxy.getFunction('target')()).to.equal(safeAddress);
  expect(await azoriusProxy.strategy()).to.equal(strategy);
  expect(await azoriusProxy.timelockPeriod()).to.equal(timelockPeriod);
  expect(await azoriusProxy.executionPeriod()).to.equal(executionPeriod);

  return azoriusProxy;
}

// Helper function to find and verify StrategyV1 deployment and configuration
async function findAndVerifyStrategyV1(params: {
  fixtureData: {
    systemDeployer: SystemDeployer;
    deployer: SignerWithAddress;
  };
  receipt: ContractTransactionReceipt;
  implementation: AddressLike;
  votingPeriod: BigNumberish;
  quorumThreshold: BigNumberish;
  basisNumerator: BigNumberish;
  strategyAdmin: string;
  proposerAdapters: string[];
  votingAdapters: string[];
}) {
  const {
    fixtureData,
    receipt,
    implementation,
    votingPeriod,
    quorumThreshold,
    basisNumerator,
    strategyAdmin,
    proposerAdapters,
    votingAdapters,
  } = params;

  const strategyAddress = await findProxyDeployed({
    fixtureData,
    receipt,
    implementation,
  });

  const strategyProxy = StrategyV1__factory.connect(strategyAddress, fixtureData.deployer);

  expect(await strategyProxy.votingPeriod()).to.equal(votingPeriod);
  expect(await strategyProxy.quorumThreshold()).to.equal(quorumThreshold);
  expect(await strategyProxy.basisNumerator()).to.equal(basisNumerator);
  expect(await strategyProxy.strategyAdmin()).to.equal(strategyAdmin);

  // Verify proposer adapters
  const actualProposerAdapters = await strategyProxy.proposerAdapters();
  expect(actualProposerAdapters).to.have.lengthOf(proposerAdapters.length);
  for (let i = 0; i < proposerAdapters.length; i++) {
    expect(actualProposerAdapters[i]).to.equal(proposerAdapters[i]);
  }

  // Verify voting adapters
  const actualVotingAdapters = await strategyProxy.votingAdapters();
  expect(actualVotingAdapters).to.have.lengthOf(votingAdapters.length);
  for (let i = 0; i < votingAdapters.length; i++) {
    expect(actualVotingAdapters[i]).to.equal(votingAdapters[i]);
  }

  return strategyProxy;
}

// Helper function to find and verify ProposerAdapterERC20V1 deployment and configuration
async function findAndVerifyProposerAdapterERC20V1s(params: {
  fixtureData: {
    systemDeployer: SystemDeployer;
    deployer: SignerWithAddress;
  };
  receipt: ContractTransactionReceipt;
  implementation: string;
  adapterDatas: {
    params: {
      proposerThreshold: BigNumberish;
    };
    token: string;
  }[];
}) {
  const { fixtureData, receipt, implementation, adapterDatas } = params;

  const proposerAdapterAddresses = await findProxiesDeployed({
    fixtureData,
    receipt,
    implementation,
  });

  if (proposerAdapterAddresses.length !== adapterDatas.length) {
    throw new Error(
      `Number of proposer adapters does not match number of adapter datas in transaction receipt`,
    );
  }

  for (let i = 0; i < proposerAdapterAddresses.length; i++) {
    const proposerAdapterAddress = proposerAdapterAddresses[i];
    const adapterData = adapterDatas[i];

    const proposerAdapterProxy = ProposerAdapterERC20V1__factory.connect(
      proposerAdapterAddress,
      fixtureData.deployer,
    );

    expect(await proposerAdapterProxy.token()).to.equal(adapterData.token);
    expect(await proposerAdapterProxy.proposerThreshold()).to.equal(
      adapterData.params.proposerThreshold,
    );
  }

  return proposerAdapterAddresses.map(adapter =>
    ProposerAdapterERC20V1__factory.connect(adapter, fixtureData.deployer),
  );
}

// Helper function to find and verify ProposerAdapterERC721V1 deployment and configuration
async function findAndVerifyProposerAdapterERC721V1s(params: {
  fixtureData: {
    systemDeployer: SystemDeployer;
    deployer: SignerWithAddress;
  };
  receipt: ContractTransactionReceipt;
  implementation: string;
  proposerAdapterDatas: {
    params: {
      token: AddressLike;
      proposerThreshold: BigNumberish;
    };
  }[];
}) {
  const { fixtureData, receipt, implementation, proposerAdapterDatas } = params;

  const proposerAdapterAddresess = await findProxiesDeployed({
    fixtureData,
    receipt,
    implementation,
  });

  if (proposerAdapterAddresess.length !== proposerAdapterDatas.length) {
    throw new Error(`Number of proposer adapters does not match number of adapter datas`);
  }

  for (let i = 0; i < proposerAdapterAddresess.length; i++) {
    const proposerAdapterAddress = proposerAdapterAddresess[i];
    const proposerAdapterData = proposerAdapterDatas[i];

    const proposerAdapterProxy = ProposerAdapterERC721V1__factory.connect(
      proposerAdapterAddress,
      fixtureData.deployer,
    );

    expect(await proposerAdapterProxy.token()).to.equal(proposerAdapterData.params.token);
    expect(await proposerAdapterProxy.proposerThreshold()).to.equal(
      proposerAdapterData.params.proposerThreshold,
    );
  }

  return proposerAdapterAddresess.map(adapter =>
    ProposerAdapterERC721V1__factory.connect(adapter, fixtureData.deployer),
  );
}

// Helper function to find and verify ProposerAdapterHatsV1 deployment and configuration
async function findAndVerifyProposerAdapterHatsV1s(params: {
  fixtureData: {
    systemDeployer: SystemDeployer;
    deployer: SignerWithAddress;
  };
  receipt: ContractTransactionReceipt;
  implementation: string;
  proposerAdapterDatas: {
    params: {
      hatsContract: AddressLike;
      whitelistedHatIds: BigNumberish[];
    };
  }[];
}) {
  const { fixtureData, receipt, implementation, proposerAdapterDatas } = params;

  const proposerAdapterAddresess = await findProxiesDeployed({
    fixtureData,
    receipt,
    implementation,
  });

  if (proposerAdapterAddresess.length !== proposerAdapterDatas.length) {
    throw new Error(`Number of proposer adapters does not match number of adapter datas`);
  }

  for (let i = 0; i < proposerAdapterAddresess.length; i++) {
    const proposerAdapterAddress = proposerAdapterAddresess[i];
    const proposerAdapterData = proposerAdapterDatas[i];

    const proposerAdapterProxy = ProposerAdapterHatsV1__factory.connect(
      proposerAdapterAddress,
      fixtureData.deployer,
    );

    expect(await proposerAdapterProxy.hatsContract()).to.equal(
      proposerAdapterData.params.hatsContract,
    );

    const whitelistedHatIds = await proposerAdapterProxy.whitelistedHatIds();
    expect(whitelistedHatIds).to.deep.equal(proposerAdapterData.params.whitelistedHatIds);
  }

  return proposerAdapterAddresess.map(adapter =>
    ProposerAdapterHatsV1__factory.connect(adapter, fixtureData.deployer),
  );
}

// Helper function to find and verify VotingAdapterERC20V1 deployment and configuration
async function findAndVerifyVotingAdapterERC20V1s(params: {
  fixtureData: {
    systemDeployer: SystemDeployer;
    deployer: SignerWithAddress;
  };
  receipt: ContractTransactionReceipt;
  implementation: string;
  votingAdapterDatas: {
    params: {
      strategy: string;
      weightPerToken: BigNumberish;
    };
    token: string;
  }[];
}) {
  const { fixtureData, receipt, implementation, votingAdapterDatas } = params;

  const votingAdapterAddresess = await findProxiesDeployed({
    fixtureData,
    receipt,
    implementation,
  });

  if (votingAdapterAddresess.length !== votingAdapterDatas.length) {
    throw new Error(`Number of voting adapters does not match number of adapter datas`);
  }

  for (let i = 0; i < votingAdapterAddresess.length; i++) {
    const votingAdapterAddress = votingAdapterAddresess[i];
    const votingAdapterData = votingAdapterDatas[i];

    const votingAdapterProxy = VotingAdapterERC20V1__factory.connect(
      votingAdapterAddress,
      fixtureData.deployer,
    );

    expect(await votingAdapterProxy.token()).to.equal(votingAdapterData.token);
    expect(await votingAdapterProxy.strategy()).to.equal(votingAdapterData.params.strategy);
    expect(await votingAdapterProxy.weightPerToken()).to.equal(
      votingAdapterData.params.weightPerToken,
    );
  }

  return votingAdapterAddresess.map(adapter =>
    VotingAdapterERC20V1__factory.connect(adapter, fixtureData.deployer),
  );
}

// Helper function to find and verify VotingAdapterERC721V1 deployment and configuration
async function findAndVerifyVotingAdapterERC721V1s(params: {
  fixtureData: {
    systemDeployer: SystemDeployer;
    deployer: SignerWithAddress;
  };
  receipt: ContractTransactionReceipt;
  implementation: string;
  votingAdapterDatas: {
    params: {
      strategy: string;
      weightPerToken: BigNumberish;
      token: AddressLike;
    };
  }[];
}) {
  const { fixtureData, receipt, implementation, votingAdapterDatas } = params;

  const votingAdapterAddresess = await findProxiesDeployed({
    fixtureData,
    receipt,
    implementation,
  });

  if (votingAdapterAddresess.length !== votingAdapterDatas.length) {
    throw new Error(`Number of voting adapters does not match number of adapter datas`);
  }

  for (let i = 0; i < votingAdapterAddresess.length; i++) {
    const votingAdapterAddress = votingAdapterAddresess[i];
    const votingAdapterData = votingAdapterDatas[i];

    const votingAdapterProxy = VotingAdapterERC721V1__factory.connect(
      votingAdapterAddress,
      fixtureData.deployer,
    );

    expect(await votingAdapterProxy.token()).to.equal(votingAdapterData.params.token);
    expect(await votingAdapterProxy.strategy()).to.equal(votingAdapterData.params.strategy);
    expect(await votingAdapterProxy.weightPerToken()).to.equal(
      votingAdapterData.params.weightPerToken,
    );
  }

  return votingAdapterAddresess.map(adapter =>
    VotingAdapterERC721V1__factory.connect(adapter, fixtureData.deployer),
  );
}

// Helper function to find and verify FreezeGuardMultisig deployment and configuration
async function findAndVerifyFreezeGuardMultisigV1(params: {
  fixtureData: {
    systemDeployer: SystemDeployer;
    deployer: SignerWithAddress;
  };
  receipt: ContractTransactionReceipt;
  implementation: AddressLike;
  safeAddress: string;
  owner: AddressLike;
  timelockPeriod: BigNumberish;
  executionPeriod: BigNumberish;
  freezeVoting: string;
}) {
  const {
    fixtureData,
    receipt,
    implementation,
    safeAddress,
    owner,
    timelockPeriod,
    executionPeriod,
    freezeVoting,
  } = params;
  const freezeGuardMultisigAddress = await findProxyDeployed({
    fixtureData,
    receipt,
    implementation,
  });

  // Verify the module is enabled on the Safe
  const guardAddress = ethers.AbiCoder.defaultAbiCoder().decode(
    ['address'],
    await ethers.provider.getStorage(
      safeAddress,
      ethers.keccak256(ethers.toUtf8Bytes('guard_manager.guard.address')),
    ),
  )[0];
  void expect(guardAddress).to.equal(freezeGuardMultisigAddress);

  // Connect to the deployed FreezeGuardMultisig proxy
  const freezeGuardMultisigProxy = FreezeGuardMultisigV1__factory.connect(
    freezeGuardMultisigAddress,
    fixtureData.deployer,
  );

  expect(await freezeGuardMultisigProxy.owner()).to.equal(owner);
  expect(await freezeGuardMultisigProxy.timelockPeriod()).to.equal(timelockPeriod);
  expect(await freezeGuardMultisigProxy.executionPeriod()).to.equal(executionPeriod);
  expect(await freezeGuardMultisigProxy.freezeVoting()).to.equal(freezeVoting);

  return freezeGuardMultisigProxy;
}

// Helper function to find and verify FreezeGuardAzorius deployment and configuration
async function findAndVerifyFreezeGuardAzoriusV1(params: {
  fixtureData: {
    systemDeployer: SystemDeployer;
    deployer: SignerWithAddress;
  };
  receipt: ContractTransactionReceipt;
  implementation: AddressLike;
  azoriusModuleAddress: string;
  owner: AddressLike;
  freezeVoting: string;
}) {
  const { fixtureData, receipt, implementation, azoriusModuleAddress, owner, freezeVoting } =
    params;

  const freezeGuardAzoriusAddress = await findProxyDeployed({
    fixtureData,
    receipt,
    implementation,
  });

  // Verify the guard is set on the Azorius module
  const azoriusModule = ModuleAzoriusV1__factory.connect(
    azoriusModuleAddress,
    fixtureData.deployer,
  );
  const guard = await azoriusModule.getGuard();
  void expect(guard).to.equal(freezeGuardAzoriusAddress);

  // Connect to the deployed FreezeGuardAzorius proxy
  const freezeGuardAzoriusProxy = FreezeGuardAzoriusV1__factory.connect(
    freezeGuardAzoriusAddress,
    fixtureData.deployer,
  );

  expect(await freezeGuardAzoriusProxy.owner()).to.equal(owner);
  expect(await freezeGuardAzoriusProxy.freezeVoting()).to.equal(freezeVoting);

  return freezeGuardAzoriusProxy;
}

// Helper function to find and verify FreezeVotingMultisig deployment and configuration
async function findAndVerifyFreezeVotingMultisigV1(params: {
  fixtureData: {
    systemDeployer: SystemDeployer;
    deployer: SignerWithAddress;
  };
  receipt: ContractTransactionReceipt;
  implementation: AddressLike;
  owner: AddressLike;
  freezeVotesThreshold: BigNumberish;
  freezeProposalPeriod: BigNumberish;
  freezePeriod: BigNumberish;
  lightAccountFactory: AddressLike;
}) {
  const {
    fixtureData,
    receipt,
    implementation,
    owner,
    freezeVotesThreshold,
    freezeProposalPeriod,
    freezePeriod,
    lightAccountFactory,
  } = params;

  const freezeVotingMultisigAddress = await findProxyDeployed({
    fixtureData,
    receipt,
    implementation,
  });

  // Connect to the deployed FreezeVotingMultisig proxy
  const freezeVotingMultisigProxy = FreezeVotingMultisigV1__factory.connect(
    freezeVotingMultisigAddress,
    fixtureData.deployer,
  );

  expect(await freezeVotingMultisigProxy.owner()).to.equal(owner);
  expect(await freezeVotingMultisigProxy.freezeVotesThreshold()).to.equal(freezeVotesThreshold);
  expect(await freezeVotingMultisigProxy.freezeProposalPeriod()).to.equal(freezeProposalPeriod);
  expect(await freezeVotingMultisigProxy.freezePeriod()).to.equal(freezePeriod);
  expect(await freezeVotingMultisigProxy.lightAccountFactory()).to.equal(lightAccountFactory);

  return freezeVotingMultisigProxy;
}

// Helper function to find and verify FreezeVotingAzorius deployment and configuration
async function findAndVerifyFreezeVotingAzoriusV1(params: {
  fixtureData: {
    systemDeployer: SystemDeployer;
    deployer: SignerWithAddress;
  };
  receipt: ContractTransactionReceipt;
  implementation: AddressLike;
  owner: AddressLike;
  freezeVotesThreshold: BigNumberish;
  freezeProposalPeriod: BigNumberish;
  freezePeriod: BigNumberish;
  parentAzorius: AddressLike;
  lightAccountFactory: AddressLike;
}) {
  const {
    fixtureData,
    receipt,
    implementation,
    owner,
    freezeVotesThreshold,
    freezeProposalPeriod,
    freezePeriod,
    parentAzorius,
    lightAccountFactory,
  } = params;

  const freezeVotingAzoriusAddress = await findProxyDeployed({
    fixtureData,
    receipt,
    implementation,
  });

  // Connect to the deployed FreezeVotingAzorius proxy
  const freezeVotingAzoriusProxy = FreezeVotingAzoriusV1__factory.connect(
    freezeVotingAzoriusAddress,
    fixtureData.deployer,
  );

  expect(await freezeVotingAzoriusProxy.owner()).to.equal(owner);
  expect(await freezeVotingAzoriusProxy.freezeProposalPeriod()).to.equal(freezeProposalPeriod);
  expect(await freezeVotingAzoriusProxy.freezePeriod()).to.equal(freezePeriod);
  expect(await freezeVotingAzoriusProxy.freezeVotesThreshold()).to.equal(freezeVotesThreshold);
  expect(await freezeVotingAzoriusProxy.parentAzorius()).to.equal(parentAzorius);
  expect(await freezeVotingAzoriusProxy.lightAccountFactory()).to.equal(lightAccountFactory);

  return freezeVotingAzoriusProxy;
}

// Helper function to verify the number of new contracts deployed
function verifyNumberOfNewContractsDeployed(params: {
  fixtureData: {
    systemDeployer: SystemDeployer;
  };
  receipt: ContractTransactionReceipt;
  safeAddress: string;
  numberOfNewContracts: number;
}) {
  const { fixtureData, receipt, safeAddress, numberOfNewContracts } = params;

  const proxyDeployedTopicHash =
    fixtureData.systemDeployer.interface.getEvent('ProxyDeployed').topicHash;

  const events = receipt.logs.filter(
    log => log.address === safeAddress && log.topics[0] === proxyDeployedTopicHash,
  );

  expect(events).to.have.lengthOf(numberOfNewContracts);
}

// Helper function to find and verify the base Azorius Governance setup
async function findAndVerifySafe(params: {
  fixtureData: {
    safeProxyFactory: SafeProxyFactory;
    safe: Safe;
    systemDeployer: SystemDeployer;
    deployer: SignerWithAddress;
    proposerAdapterERC20V1: ProposerAdapterERC20V1;
    proposerAdapterERC721V1: ProposerAdapterERC721V1;
    proposerAdapterHatsV1: ProposerAdapterHatsV1;
    strategyV1: StrategyV1;
    moduleAzoriusV1: ModuleAzoriusV1;
    votingAdapterERC20V1: VotingAdapterERC20V1;
    votingAdapterERC721V1: VotingAdapterERC721V1;
    votesERC20V1: VotesERC20V1;
    votesERC20LockableV1: VotesERC20LockableV1;
  };
  receipt: ContractTransactionReceipt;
  safeAddress: string;
  owners: string[];
  threshold: number;
  moduleFractalV1Params?: ISystemDeployer.ModuleFractalV1ParamsStruct;
  votesERC20Datas?: [
    ISystemDeployer.VotesERC20V1ParamsStruct[],
    ISystemDeployer.VotesERC20LockableV1ParamsStruct[],
  ];
  proposerAdapterERC20V1Datas?: {
    params: ISystemDeployer.ProposerAdapterERC20V1ParamsStruct;
    token?: string;
  }[];
  proposerAdapterERC721V1Datas?: {
    params: ISystemDeployer.ProposerAdapterERC721V1ParamsStruct;
  }[];
  proposerAdapterHatsV1Datas?: {
    params: ISystemDeployer.ProposerAdapterHatsV1ParamsStruct;
  }[];
  strategyV1Params?: ISystemDeployer.StrategyV1ParamsStruct;
  moduleAzoriusV1Params?: ISystemDeployer.ModuleAzoriusV1ParamsStruct;
  votingAdapterERC20V1Datas?: {
    params: ISystemDeployer.VotingAdapterERC20V1ParamsStruct;
    token?: string;
  }[];
  votingAdapterERC721V1Datas?: {
    params: ISystemDeployer.VotingAdapterERC721V1ParamsStruct;
  }[];
  freezeGuardMultisigV1Data?: {
    guardParams: ISystemDeployer.FreezeGuardMultisigV1ParamsStruct;
    votingMultisigParams?: ISystemDeployer.FreezeVotingMultisigV1ParamsStruct;
    votingAzoriusParams?: ISystemDeployer.FreezeVotingAzoriusV1ParamsStruct;
  };
  freezeGuardAzoriusV1Data?: {
    guardParams: ISystemDeployer.FreezeGuardAzoriusV1ParamsStruct;
    votingMultisigParams?: ISystemDeployer.FreezeVotingMultisigV1ParamsStruct;
    votingAzoriusParams?: ISystemDeployer.FreezeVotingAzoriusV1ParamsStruct;
  };
  numberOfNewContracts: number;
}) {
  const {
    fixtureData,
    receipt,
    safeAddress,
    owners,
    threshold,
    moduleFractalV1Params,
    votesERC20Datas,
    proposerAdapterERC20V1Datas,
    proposerAdapterERC721V1Datas,
    proposerAdapterHatsV1Datas,
    strategyV1Params,
    moduleAzoriusV1Params,
    votingAdapterERC20V1Datas,
    votingAdapterERC721V1Datas,
    freezeGuardMultisigV1Data,
    freezeGuardAzoriusV1Data,
    numberOfNewContracts,
  } = params;

  await verifySafeConfiguration({
    fixtureData,
    receipt,
    safeAddress,
    owners,
    threshold,
  });

  if (moduleFractalV1Params) {
    await findAndVerifyModuleFractalV1({
      fixtureData,
      receipt,
      safeAddress,
      ...moduleFractalV1Params,
    });
  }

  let votesERC20Tokens: [VotesERC20V1[], VotesERC20LockableV1[]];
  if (votesERC20Datas) {
    let votesERC20V1s: VotesERC20V1[] = [];
    let votesERC20LockableV1s: VotesERC20LockableV1[] = [];

    if (votesERC20Datas[0].length > 0) {
      votesERC20V1s = await findAndVerifyVotesERC20V1s({
        fixtureData,
        receipt,
        implementation: await fixtureData.votesERC20V1.getAddress(),
        votesERC20V1Datas: votesERC20Datas[0],
        safeAddress,
      });
    }

    if (votesERC20Datas[1].length > 0) {
      votesERC20LockableV1s = await findAndVerifyVotesERC20LockableV1s({
        fixtureData,
        receipt,
        implementation: await fixtureData.votesERC20LockableV1.getAddress(),
        votesERC20LockableV1Datas: votesERC20Datas[1],
        safeAddress,
      });
    }

    votesERC20Tokens = [votesERC20V1s, votesERC20LockableV1s];
  }

  let proposerAdapterERC20s: ProposerAdapterERC20V1[] = [];
  if (proposerAdapterERC20V1Datas) {
    proposerAdapterERC20s = await findAndVerifyProposerAdapterERC20V1s({
      fixtureData,
      receipt,
      implementation: await fixtureData.proposerAdapterERC20V1.getAddress(),
      adapterDatas: await Promise.all(
        proposerAdapterERC20V1Datas.map(async data => ({
          ...data,
          token:
            data.token ??
            (await votesERC20Tokens[Number(data.params.index.typeI)][
              Number(data.params.index.tokenI)
            ].getAddress()),
        })),
      ),
    });
  }

  let proposerAdapterERC721s: ProposerAdapterERC721V1[] = [];
  if (proposerAdapterERC721V1Datas) {
    proposerAdapterERC721s = await findAndVerifyProposerAdapterERC721V1s({
      fixtureData,
      receipt,
      implementation: await fixtureData.proposerAdapterERC721V1.getAddress(),
      proposerAdapterDatas: proposerAdapterERC721V1Datas,
    });
  }

  let proposerAdapterHatsV1s: ProposerAdapterHatsV1[] = [];
  if (proposerAdapterHatsV1Datas) {
    proposerAdapterHatsV1s = await findAndVerifyProposerAdapterHatsV1s({
      fixtureData,
      receipt,
      implementation: await fixtureData.proposerAdapterHatsV1.getAddress(),
      proposerAdapterDatas: proposerAdapterHatsV1Datas,
    });
  }

  let strategyAddress: string | undefined;
  if (strategyV1Params) {
    strategyAddress = await findProxyDeployed({
      fixtureData,
      receipt,
      implementation: await fixtureData.strategyV1.getAddress(),
    });
  }

  let azoriusModule: ModuleAzoriusV1 | undefined;
  if (moduleAzoriusV1Params) {
    if (!strategyAddress) {
      throw new Error('Strategy is required to verify Azorius module');
    }

    azoriusModule = await findAndVerifyModuleAzoriusV1({
      fixtureData,
      receipt,
      safeAddress,
      owner: safeAddress,
      strategy: strategyAddress,
      ...moduleAzoriusV1Params,
    });
  }

  let votingAdapterERC20s: VotingAdapterERC20V1[] = [];
  if (votingAdapterERC20V1Datas) {
    if (!strategyAddress) {
      throw new Error('Strategy is required to verify voting adapter ERC20');
    }

    votingAdapterERC20s = await findAndVerifyVotingAdapterERC20V1s({
      fixtureData,
      receipt,
      implementation: await fixtureData.votingAdapterERC20V1.getAddress(),
      votingAdapterDatas: await Promise.all(
        votingAdapterERC20V1Datas.map(async data => ({
          ...data,
          params: {
            ...data.params,
            strategy: strategyAddress,
          },
          token:
            data.token ??
            (await votesERC20Tokens[Number(data.params.index.typeI)][
              Number(data.params.index.tokenI)
            ].getAddress()),
        })),
      ),
    });
  }

  let votingAdapterERC721s: VotingAdapterERC721V1[] = [];
  if (votingAdapterERC721V1Datas) {
    if (!strategyAddress) {
      throw new Error('Strategy is required to verify voting adapter ERC721');
    }

    votingAdapterERC721s = await findAndVerifyVotingAdapterERC721V1s({
      fixtureData,
      receipt,
      implementation: await fixtureData.votingAdapterERC721V1.getAddress(),
      votingAdapterDatas: await Promise.all(
        votingAdapterERC721V1Datas.map(async data => ({
          ...data,
          params: { ...data.params, strategy: strategyAddress },
        })),
      ),
    });
  }

  if (strategyV1Params) {
    if (!azoriusModule) {
      throw new Error('Azorius module is required to verify a strategy');
    }

    await findAndVerifyStrategyV1({
      fixtureData,
      receipt,
      ...strategyV1Params,
      strategyAdmin: await azoriusModule.getAddress(),
      proposerAdapters: [
        ...(await Promise.all(proposerAdapterERC20s.map(adapter => adapter.getAddress()))),
        ...(await Promise.all(proposerAdapterERC721s.map(adapter => adapter.getAddress()))),
        ...(await Promise.all(proposerAdapterHatsV1s.map(adapter => adapter.getAddress()))),
      ],
      votingAdapters: [
        ...(await Promise.all(votingAdapterERC20s.map(adapter => adapter.getAddress()))),
        ...(await Promise.all(votingAdapterERC721s.map(adapter => adapter.getAddress()))),
      ],
    });
  }

  if (freezeGuardMultisigV1Data) {
    if (
      freezeGuardMultisigV1Data.votingAzoriusParams &&
      freezeGuardMultisigV1Data.votingMultisigParams
    ) {
      throw new Error('Cannot have both votingAzoriusParams and votingMultisigParams');
    }

    let freezeVotingAddress: string | undefined;

    if (freezeGuardMultisigV1Data.votingMultisigParams) {
      freezeVotingAddress = await (
        await findAndVerifyFreezeVotingMultisigV1({
          fixtureData,
          receipt,
          ...freezeGuardMultisigV1Data.votingMultisigParams,
        })
      ).getAddress();
    }

    if (freezeGuardMultisigV1Data.votingAzoriusParams) {
      freezeVotingAddress = await (
        await findAndVerifyFreezeVotingAzoriusV1({
          fixtureData,
          receipt,
          ...freezeGuardMultisigV1Data.votingAzoriusParams,
        })
      ).getAddress();
    }

    if (!freezeVotingAddress) {
      throw new Error('No freeze voting address found');
    }

    await findAndVerifyFreezeGuardMultisigV1({
      fixtureData,
      receipt,
      safeAddress,
      ...freezeGuardMultisigV1Data.guardParams,
      freezeVoting: freezeVotingAddress,
    });
  }

  if (freezeGuardAzoriusV1Data) {
    if (!azoriusModule) {
      throw new Error('Azorius module is required to verify freeze guard Azorius');
    }

    if (
      freezeGuardAzoriusV1Data.votingAzoriusParams &&
      freezeGuardAzoriusV1Data.votingMultisigParams
    ) {
      throw new Error('Cannot have both votingAzoriusParams and votingMultisigParams');
    }

    let freezeVotingAddress: string | undefined;

    if (freezeGuardAzoriusV1Data.votingMultisigParams) {
      freezeVotingAddress = await (
        await findAndVerifyFreezeVotingMultisigV1({
          fixtureData,
          receipt,
          ...freezeGuardAzoriusV1Data.votingMultisigParams,
        })
      ).getAddress();
    }

    if (freezeGuardAzoriusV1Data.votingAzoriusParams) {
      freezeVotingAddress = await (
        await findAndVerifyFreezeVotingAzoriusV1({
          fixtureData,
          receipt,
          ...freezeGuardAzoriusV1Data.votingAzoriusParams,
        })
      ).getAddress();
    }

    if (!freezeVotingAddress) {
      throw new Error('No freeze voting address found');
    }

    await findAndVerifyFreezeGuardAzoriusV1({
      fixtureData,
      receipt,
      azoriusModuleAddress: await azoriusModule.getAddress(),
      ...freezeGuardAzoriusV1Data.guardParams,
      freezeVoting: freezeVotingAddress,
    });
  }

  verifyNumberOfNewContractsDeployed({
    fixtureData,
    receipt,
    safeAddress,
    numberOfNewContracts,
  });
}

async function setupState() {
  const [deployer, user1, user2] = await ethers.getSigners();
  const safe = await new Safe__factory(deployer).deploy();
  const safeProxyFactory = await new SafeProxyFactory__factory(deployer).deploy();
  const systemDeployer = await new SystemDeployer__factory(deployer).deploy();
  const moduleFractalV1 = await new ModuleFractalV1__factory(deployer).deploy();
  const freezeGuardMultisigV1 = await new FreezeGuardMultisigV1__factory(deployer).deploy();
  const freezeGuardAzoriusV1 = await new FreezeGuardAzoriusV1__factory(deployer).deploy();
  const freezeVotingMultisigV1 = await new FreezeVotingMultisigV1__factory(deployer).deploy();
  const freezeVotingAzoriusV1 = await new FreezeVotingAzoriusV1__factory(deployer).deploy();
  const moduleAzoriusV1 = await new ModuleAzoriusV1__factory(deployer).deploy();
  const strategyV1 = await new StrategyV1__factory(deployer).deploy();
  const votesERC20V1 = await new VotesERC20V1__factory(deployer).deploy();
  const votesERC20LockableV1 = await new VotesERC20LockableV1__factory(deployer).deploy();
  const proposerAdapterERC20V1 = await new ProposerAdapterERC20V1__factory(deployer).deploy();
  const proposerAdapterERC721V1 = await new ProposerAdapterERC721V1__factory(deployer).deploy();
  const proposerAdapterHatsV1 = await new ProposerAdapterHatsV1__factory(deployer).deploy();
  const votingAdapterERC20V1 = await new VotingAdapterERC20V1__factory(deployer).deploy();
  const votingAdapterERC721V1 = await new VotingAdapterERC721V1__factory(deployer).deploy();

  return {
    deployer,
    user1,
    user2,
    safe,
    safeProxyFactory,
    systemDeployer,
    moduleFractalV1,
    freezeGuardMultisigV1,
    freezeGuardAzoriusV1,
    freezeVotingMultisigV1,
    freezeVotingAzoriusV1,
    moduleAzoriusV1,
    strategyV1,
    votesERC20V1,
    votesERC20LockableV1,
    proposerAdapterERC20V1,
    proposerAdapterERC721V1,
    proposerAdapterHatsV1,
    votingAdapterERC20V1,
    votingAdapterERC721V1,
  };
}

describe('SystemDeployer', () => {
  let fixtureData: Awaited<ReturnType<typeof setupState>>;

  let votesERC20V1Params1: ISystemDeployer.VotesERC20V1ParamsStruct;
  let votesERC20LockableV1Params1: ISystemDeployer.VotesERC20LockableV1ParamsStruct;
  let votesERC20V1Params2: ISystemDeployer.VotesERC20V1ParamsStruct;
  let votesERC20LockableV1Params2: ISystemDeployer.VotesERC20LockableV1ParamsStruct;

  let moduleFractalV1Params: ISystemDeployer.ModuleFractalV1ParamsStruct;

  let freezeGuardMultisigParams: ISystemDeployer.FreezeGuardMultisigV1ParamsStruct;
  let freezeGuardAzoriusParams: ISystemDeployer.FreezeGuardAzoriusV1ParamsStruct;
  let freezeVotingMultisigParams: ISystemDeployer.FreezeVotingMultisigV1ParamsStruct;
  let freezeVotingAzoriusParams: ISystemDeployer.FreezeVotingAzoriusV1ParamsStruct;

  beforeEach(async () => {
    fixtureData = await loadFixture(setupState);

    votesERC20V1Params1 = {
      implementation: await fixtureData.votesERC20V1.getAddress(),
      metadata: {
        name: 'Test Token',
        symbol: 'TEST',
      },
      allocations: [
        {
          to: fixtureData.user1.address,
          amount: ethers.parseEther('100'),
        },
      ],
      safeSupply: ethers.parseEther('100'),
    };

    votesERC20LockableV1Params1 = {
      implementation: await fixtureData.votesERC20LockableV1.getAddress(),
      metadata: {
        name: 'Locked Token',
        symbol: 'LOCK',
      },
      allocations: [
        {
          to: fixtureData.user1.address,
          amount: ethers.parseEther('500'),
        },
      ],
      locked: true,
      maxTotalSupply: ethers.parseEther('10000'),
      safeSupply: ethers.parseEther('1000'),
    };

    votesERC20V1Params2 = {
      implementation: await fixtureData.votesERC20V1.getAddress(),
      metadata: {
        name: 'Test Token 2',
        symbol: 'TEST2',
      },
      allocations: [
        {
          to: fixtureData.user2.address,
          amount: ethers.parseEther('50'),
        },
      ],
      safeSupply: ethers.parseEther('150'),
    };

    votesERC20LockableV1Params2 = {
      implementation: await fixtureData.votesERC20LockableV1.getAddress(),
      metadata: {
        name: 'Locked Token 2',
        symbol: 'LOCK2',
      },
      allocations: [
        {
          to: fixtureData.user2.address,
          amount: ethers.parseEther('50'),
        },
      ],
      locked: true,
      maxTotalSupply: ethers.parseEther('10000'),
      safeSupply: ethers.parseEther('1000'),
    };

    moduleFractalV1Params = {
      implementation: await fixtureData.moduleFractalV1.getAddress(),
      owner: fixtureData.user1.address,
    };

    freezeGuardMultisigParams = {
      implementation: await fixtureData.freezeGuardMultisigV1.getAddress(),
      owner: fixtureData.user1.address,
      timelockPeriod: 60,
      executionPeriod: 120,
    };

    freezeGuardAzoriusParams = {
      implementation: await fixtureData.freezeGuardAzoriusV1.getAddress(),
      owner: fixtureData.user1.address,
    };

    freezeVotingMultisigParams = {
      implementation: await fixtureData.freezeVotingMultisigV1.getAddress(),
      owner: fixtureData.user1.address,
      freezeVotesThreshold: 26,
      freezeProposalPeriod: 65,
      freezePeriod: 129,
      parentSafe: ethers.ZeroAddress,
      lightAccountFactory: ethers.ZeroAddress,
    };

    freezeVotingAzoriusParams = {
      implementation: await fixtureData.freezeVotingAzoriusV1.getAddress(),
      owner: fixtureData.user1.address,
      freezeVotesThreshold: 12,
      freezeProposalPeriod: 60,
      freezePeriod: 120,
      parentAzorius: ethers.ZeroAddress,
      lightAccountFactory: ethers.ZeroAddress,
    };
  });

  describe('Deploy Multisig DAO', () => {
    let owners: string[];
    let threshold: number;

    beforeEach(async () => {
      const randomOwner = ethers.Wallet.createRandom().address;
      owners = [fixtureData.user1.address, fixtureData.user2.address, randomOwner];
      threshold = 2;
    });

    it('has correct signers and threshold', async () => {
      const setupSafeParams = createSetupSafeParams();

      const { safeAddress, receipt } = await deploySafeWithSetup({
        fixtureData,
        owners,
        threshold,
        setupSafeParams,
      });

      await findAndVerifySafe({
        fixtureData,
        safeAddress,
        receipt,
        owners,
        threshold,
        numberOfNewContracts: 0,
      });
    });

    describe('with a Fractal Module', () => {
      it('deploys successfully with a Fractal Module', async () => {
        const setupSafeParams = createSetupSafeParams({
          moduleFractalParams: moduleFractalV1Params,
        });

        const { safeAddress, receipt } = await deploySafeWithSetup({
          fixtureData,
          owners,
          threshold,
          setupSafeParams,
        });

        await findAndVerifySafe({
          fixtureData,
          safeAddress,
          receipt,
          owners,
          threshold,
          moduleFractalV1Params,
          numberOfNewContracts: 1,
        });
      });
    });

    describe('with Freeze Guards', () => {
      it('reverts with FreezeGuardAzorius', async () => {
        const setupSafeParams = createSetupSafeParams();

        const data = {
          fixtureData,
          owners,
          threshold,
          setupSafeParams,
        };

        // confirm that the safe is deployed with basic params
        await deploySafeWithSetup(data);

        // now update setupSafeParams to include a freezeGuardAzoriusParams
        data.setupSafeParams.freezeParams.freezeGuardParams.freezeGuardAzoriusV1Params =
          freezeGuardAzoriusParams;

        // now deploying should fail
        await expect(deploySafeWithSetup(data)).to.be.reverted;
      });

      it('reverts with FreezeGuardMultisig but no FreezeVoting contract', async () => {
        const setupSafeParams = createSetupSafeParams();

        const data = {
          fixtureData,
          owners,
          threshold,
          setupSafeParams,
        };

        // confirm that the safe is deployed with basic params
        await deploySafeWithSetup(data);

        // now update setupSafeParams to include a freezeGuardMultisigParams
        data.setupSafeParams.freezeParams.freezeGuardParams.freezeGuardMultisigV1Params =
          freezeGuardMultisigParams;

        // now deploying should fail
        await expect(deploySafeWithSetup(data)).to.be.reverted;
      });

      it('succeeds with FreezeGuardMultisig and FreezeVotingMultisig contracts', async () => {
        const setupSafeParams = createSetupSafeParams({
          freezeVotingMultisigParams,
          freezeGuardMultisigParams,
        });

        const { safeAddress, receipt } = await deploySafeWithSetup({
          fixtureData,
          owners,
          threshold,
          setupSafeParams,
        });

        await findAndVerifySafe({
          fixtureData,
          safeAddress,
          receipt,
          owners,
          threshold,
          freezeGuardMultisigV1Data: {
            guardParams: freezeGuardMultisigParams,
            votingMultisigParams: freezeVotingMultisigParams,
          },
          numberOfNewContracts: 2,
        });
      });

      it('succeeds with FreezeGuardMultisig and FreezeVotingAzorius contracts', async () => {
        const setupSafeParams = createSetupSafeParams({
          freezeVotingAzoriusParams,
          freezeGuardMultisigParams,
        });

        const { safeAddress, receipt } = await deploySafeWithSetup({
          fixtureData,
          owners,
          threshold,
          setupSafeParams,
        });

        await findAndVerifySafe({
          fixtureData,
          safeAddress,
          receipt,
          owners,
          threshold,
          freezeGuardMultisigV1Data: {
            guardParams: freezeGuardMultisigParams,
            votingAzoriusParams: freezeVotingAzoriusParams,
          },
          numberOfNewContracts: 2,
        });
      });
    });

    describe('with a Fractal Module and Freeze Guard Multisig', () => {
      it('deploys successfully', async () => {
        const setupSafeParams = createSetupSafeParams({
          moduleFractalParams: moduleFractalV1Params,
          freezeGuardMultisigParams,
          freezeVotingMultisigParams,
        });

        const { safeAddress, receipt } = await deploySafeWithSetup({
          fixtureData,
          owners,
          threshold,
          setupSafeParams,
        });

        await findAndVerifySafe({
          fixtureData,
          safeAddress,
          receipt,
          owners,
          threshold,
          moduleFractalV1Params,
          freezeGuardMultisigV1Data: {
            guardParams: freezeGuardMultisigParams,
            votingMultisigParams: freezeVotingMultisigParams,
          },
          numberOfNewContracts: 3,
        });
      });
    });

    describe('with VotesERC20V1 and VotesERC20LockableV1 tokens', () => {
      it('deploys successfully with one VotesERC20V1 token', async () => {
        const setupSafeParams = createSetupSafeParams({
          votesERC20Params: {
            votesERC20V1Params: [votesERC20V1Params1],
            votesERC20LockableV1Params: [],
          },
        });

        const { safeAddress, receipt } = await deploySafeWithSetup({
          fixtureData,
          owners,
          threshold,
          setupSafeParams,
        });

        await findAndVerifySafe({
          fixtureData,
          safeAddress,
          receipt,
          owners,
          threshold,
          votesERC20Datas: [[votesERC20V1Params1], []],
          numberOfNewContracts: 1,
        });
      });

      it('deploys successfully with multiple VotesERC20V1 tokens', async () => {
        const setupSafeParams = createSetupSafeParams({
          votesERC20Params: {
            votesERC20V1Params: [votesERC20V1Params1, votesERC20V1Params2],
            votesERC20LockableV1Params: [],
          },
        });

        const { safeAddress, receipt } = await deploySafeWithSetup({
          fixtureData,
          owners,
          threshold,
          setupSafeParams,
        });

        await findAndVerifySafe({
          fixtureData,
          safeAddress,
          receipt,
          owners,
          threshold,
          votesERC20Datas: [[votesERC20V1Params1, votesERC20V1Params2], []],
          numberOfNewContracts: 2,
        });
      });

      it('deploys successfully with one VotesERC20LockableV1 token', async () => {
        const setupSafeParams = createSetupSafeParams({
          votesERC20Params: {
            votesERC20V1Params: [],
            votesERC20LockableV1Params: [votesERC20LockableV1Params1],
          },
        });

        const { safeAddress, receipt } = await deploySafeWithSetup({
          fixtureData,
          owners,
          threshold,
          setupSafeParams,
        });

        await findAndVerifySafe({
          fixtureData,
          safeAddress,
          receipt,
          owners,
          threshold,
          votesERC20Datas: [[], [votesERC20LockableV1Params1]],
          numberOfNewContracts: 1,
        });
      });

      it('deploys successfully with multiple VotesERC20LockableV1 tokens', async () => {
        const setupSafeParams = createSetupSafeParams({
          votesERC20Params: {
            votesERC20V1Params: [],
            votesERC20LockableV1Params: [votesERC20LockableV1Params1, votesERC20LockableV1Params2],
          },
        });

        const { safeAddress, receipt } = await deploySafeWithSetup({
          fixtureData,
          owners,
          threshold,
          setupSafeParams,
        });

        await findAndVerifySafe({
          fixtureData,
          safeAddress,
          receipt,
          owners,
          threshold,
          votesERC20Datas: [[], [votesERC20LockableV1Params1, votesERC20LockableV1Params2]],
          numberOfNewContracts: 2,
        });
      });

      it('deploys successfully with one VotesERC20V1 and one VotesERC20LockableV1 token', async () => {
        const setupSafeParams = createSetupSafeParams({
          votesERC20Params: {
            votesERC20V1Params: [votesERC20V1Params1],
            votesERC20LockableV1Params: [votesERC20LockableV1Params1],
          },
        });

        const { safeAddress, receipt } = await deploySafeWithSetup({
          fixtureData,
          owners,
          threshold,
          setupSafeParams,
        });

        await findAndVerifySafe({
          fixtureData,
          safeAddress,
          receipt,
          owners,
          threshold,
          votesERC20Datas: [[votesERC20V1Params1], [votesERC20LockableV1Params1]],
          numberOfNewContracts: 2,
        });
      });

      it('deploys successfully with multiple VotesERC20V1 and VotesERC20LockableV1 tokens', async () => {
        const setupSafeParams = createSetupSafeParams({
          votesERC20Params: {
            votesERC20V1Params: [votesERC20V1Params1, votesERC20V1Params2],
            votesERC20LockableV1Params: [votesERC20LockableV1Params1, votesERC20LockableV1Params2],
          },
        });

        const { safeAddress, receipt } = await deploySafeWithSetup({
          fixtureData,
          owners,
          threshold,
          setupSafeParams,
        });

        await findAndVerifySafe({
          fixtureData,
          safeAddress,
          receipt,
          owners,
          threshold,
          votesERC20Datas: [
            [votesERC20V1Params1, votesERC20V1Params2],
            [votesERC20LockableV1Params1, votesERC20LockableV1Params2],
          ],
          numberOfNewContracts: 4,
        });
      });
    });
  });

  describe('Deploy Azorius Governance', () => {
    let randomVotesERC20Contract: string;
    let randomVotesERC721Contract: string;
    let hatsContract: string;
    let moduleAzoriusV1Params: ISystemDeployer.ModuleAzoriusV1ParamsStruct;
    let proposerAdapterERC20V1Params1: ISystemDeployer.ProposerAdapterERC20V1ParamsStruct;
    let proposerAdapterERC20V1Params2: ISystemDeployer.ProposerAdapterERC20V1ParamsStruct;
    let proposerAdapterERC721V1Params1: ISystemDeployer.ProposerAdapterERC721V1ParamsStruct;
    let proposerAdapterERC721V1Params2: ISystemDeployer.ProposerAdapterERC721V1ParamsStruct;
    let proposerAdapterHatsV1Params1: ISystemDeployer.ProposerAdapterHatsV1ParamsStruct;
    let proposerAdapterHatsV1Params2: ISystemDeployer.ProposerAdapterHatsV1ParamsStruct;
    let votingAdapterERC20V1Params1: ISystemDeployer.VotingAdapterERC20V1ParamsStruct;
    let votingAdapterERC20V1Params2: ISystemDeployer.VotingAdapterERC20V1ParamsStruct;
    let votingAdapterERC721V1Params1: ISystemDeployer.VotingAdapterERC721V1ParamsStruct;
    let votingAdapterERC721V1Params2: ISystemDeployer.VotingAdapterERC721V1ParamsStruct;
    let strategyV1Params: ISystemDeployer.StrategyV1ParamsStruct;

    beforeEach(async () => {
      randomVotesERC20Contract = await fixtureData.votesERC20V1.getAddress();
      randomVotesERC721Contract = ethers.Wallet.createRandom().address;
      hatsContract = ethers.Wallet.createRandom().address;

      moduleAzoriusV1Params = {
        implementation: await fixtureData.moduleAzoriusV1.getAddress(),
        timelockPeriod: 3600,
        executionPeriod: 86400,
      };

      proposerAdapterERC20V1Params1 = {
        implementation: await fixtureData.proposerAdapterERC20V1.getAddress(),
        token: randomVotesERC20Contract,
        proposerThreshold: 100000,
        index: { typeI: 0, tokenI: 0 },
      };

      proposerAdapterERC20V1Params2 = {
        implementation: await fixtureData.proposerAdapterERC20V1.getAddress(),
        token: randomVotesERC20Contract,
        proposerThreshold: 874512,
        index: { typeI: 0, tokenI: 0 },
      };

      proposerAdapterERC721V1Params1 = {
        implementation: await fixtureData.proposerAdapterERC721V1.getAddress(),
        token: randomVotesERC721Contract,
        proposerThreshold: 100000,
      };

      proposerAdapterERC721V1Params2 = {
        implementation: await fixtureData.proposerAdapterERC721V1.getAddress(),
        token: randomVotesERC721Contract,
        proposerThreshold: 8745,
      };

      proposerAdapterHatsV1Params1 = {
        implementation: await fixtureData.proposerAdapterHatsV1.getAddress(),
        hatsContract: hatsContract,
        whitelistedHatIds: [1, 2, 3],
      };

      proposerAdapterHatsV1Params2 = {
        implementation: await fixtureData.proposerAdapterHatsV1.getAddress(),
        hatsContract: hatsContract,
        whitelistedHatIds: [4, 5, 6],
      };

      votingAdapterERC20V1Params1 = {
        implementation: await fixtureData.votingAdapterERC20V1.getAddress(),
        token: randomVotesERC20Contract,
        weightPerToken: 14,
        index: { typeI: 0, tokenI: 0 },
      };

      votingAdapterERC20V1Params2 = {
        implementation: await fixtureData.votingAdapterERC20V1.getAddress(),
        token: randomVotesERC20Contract,
        weightPerToken: 343,
        index: { typeI: 0, tokenI: 0 },
      };

      votingAdapterERC721V1Params1 = {
        implementation: await fixtureData.votingAdapterERC721V1.getAddress(),
        token: randomVotesERC721Contract,
        weightPerToken: 14,
      };

      votingAdapterERC721V1Params2 = {
        implementation: await fixtureData.votingAdapterERC721V1.getAddress(),
        token: randomVotesERC721Contract,
        weightPerToken: 343,
      };

      strategyV1Params = {
        implementation: await fixtureData.strategyV1.getAddress(),
        votingPeriod: 86400,
        quorumThreshold: 1000,
        basisNumerator: 500000,
        lightAccountFactory: ethers.ZeroAddress,
      };
    });

    describe('With Multisig', () => {
      it('deploys with a single non-signer', async () => {
        const owners = ['0x0000000000000000000000000000000000000002'];
        const threshold = 1;

        const setupSafeParams = createSetupSafeParams({
          azoriusGovernanceParams: {
            proposerAdapterParams: {
              proposerAdapterERC20V1Params: [proposerAdapterERC20V1Params1],
              proposerAdapterERC721V1Params: [],
              proposerAdapterHatsV1Params: [],
            },
            strategyV1Params,
            votingAdapterParams: {
              votingAdapterERC20V1Params: [votingAdapterERC20V1Params1],
              votingAdapterERC721V1Params: [],
            },
            moduleAzoriusV1Params,
          },
        });

        const { safeAddress, receipt } = await deploySafeWithSetup({
          fixtureData,
          owners,
          threshold,
          setupSafeParams,
        });

        await findAndVerifySafe({
          fixtureData,
          receipt,
          safeAddress,
          owners,
          threshold,
          proposerAdapterERC20V1Datas: [
            {
              params: proposerAdapterERC20V1Params1,
              token: randomVotesERC20Contract,
            },
          ],
          strategyV1Params,
          moduleAzoriusV1Params,
          votingAdapterERC20V1Datas: [
            {
              params: votingAdapterERC20V1Params1,
              token: randomVotesERC20Contract,
            },
          ],
          numberOfNewContracts: 4,
        });
      });

      it('deploys with multiple signers', async () => {
        const owners = [fixtureData.user1.address, fixtureData.user2.address];
        const threshold = 2;

        const setupSafeParams = createSetupSafeParams({
          azoriusGovernanceParams: {
            proposerAdapterParams: {
              proposerAdapterERC20V1Params: [proposerAdapterERC20V1Params1],
              proposerAdapterERC721V1Params: [],
              proposerAdapterHatsV1Params: [],
            },
            strategyV1Params,
            votingAdapterParams: {
              votingAdapterERC20V1Params: [votingAdapterERC20V1Params1],
              votingAdapterERC721V1Params: [],
            },
            moduleAzoriusV1Params,
          },
        });

        const { safeAddress, receipt } = await deploySafeWithSetup({
          fixtureData,
          owners,
          threshold,
          setupSafeParams,
        });

        await findAndVerifySafe({
          fixtureData,
          receipt,
          safeAddress,
          owners,
          threshold,
          proposerAdapterERC20V1Datas: [
            {
              params: proposerAdapterERC20V1Params1,
              token: randomVotesERC20Contract,
            },
          ],
          strategyV1Params,
          moduleAzoriusV1Params,
          votingAdapterERC20V1Datas: [
            {
              params: votingAdapterERC20V1Params1,
              token: randomVotesERC20Contract,
            },
          ],
          numberOfNewContracts: 4,
        });
      });
    });

    describe('Without Multisig', () => {
      let owners: string[];
      let threshold: number;

      beforeEach(async () => {
        owners = ['0x0000000000000000000000000000000000000002'];
        threshold = 1;
      });

      describe('With VotesERC20 & VotesERC20Lockable tokens', () => {
        describe('With VotesERC20V1 tokens', () => {
          it('deploys with a single VotesERC20V1 token', async () => {
            const setupSafeParams = createSetupSafeParams({
              votesERC20Params: {
                votesERC20V1Params: [votesERC20V1Params1],
                votesERC20LockableV1Params: [],
              },
              azoriusGovernanceParams: {
                proposerAdapterParams: {
                  proposerAdapterERC20V1Params: [proposerAdapterERC20V1Params1],
                  proposerAdapterERC721V1Params: [],
                  proposerAdapterHatsV1Params: [],
                },
                strategyV1Params,
                votingAdapterParams: {
                  votingAdapterERC20V1Params: [votingAdapterERC20V1Params1],
                  votingAdapterERC721V1Params: [],
                },
                moduleAzoriusV1Params,
              },
            });

            const { safeAddress, receipt } = await deploySafeWithSetup({
              fixtureData,
              owners,
              threshold,
              setupSafeParams,
            });

            await findAndVerifySafe({
              fixtureData,
              receipt,
              safeAddress,
              owners,
              threshold,
              votesERC20Datas: [[votesERC20V1Params1], []],
              proposerAdapterERC20V1Datas: [
                {
                  params: proposerAdapterERC20V1Params1,
                  token: randomVotesERC20Contract,
                },
              ],
              strategyV1Params,
              moduleAzoriusV1Params,
              votingAdapterERC20V1Datas: [
                {
                  params: votingAdapterERC20V1Params1,
                  token: randomVotesERC20Contract,
                },
              ],
              numberOfNewContracts: 5,
            });
          });

          it('deploys with multiple VotesERC20V1 tokens', async () => {
            const setupSafeParams = createSetupSafeParams({
              votesERC20Params: {
                votesERC20V1Params: [votesERC20V1Params1, votesERC20V1Params2],
                votesERC20LockableV1Params: [],
              },
              azoriusGovernanceParams: {
                proposerAdapterParams: {
                  proposerAdapterERC20V1Params: [proposerAdapterERC20V1Params1],
                  proposerAdapterERC721V1Params: [],
                  proposerAdapterHatsV1Params: [],
                },
                strategyV1Params,
                votingAdapterParams: {
                  votingAdapterERC20V1Params: [votingAdapterERC20V1Params1],
                  votingAdapterERC721V1Params: [],
                },
                moduleAzoriusV1Params,
              },
            });

            const { safeAddress, receipt } = await deploySafeWithSetup({
              fixtureData,
              owners,
              threshold,
              setupSafeParams,
            });

            await findAndVerifySafe({
              fixtureData,
              receipt,
              safeAddress,
              owners,
              threshold,
              votesERC20Datas: [[votesERC20V1Params1, votesERC20V1Params2], []],
              proposerAdapterERC20V1Datas: [
                {
                  params: proposerAdapterERC20V1Params1,
                  token: randomVotesERC20Contract,
                },
              ],
              strategyV1Params,
              moduleAzoriusV1Params,
              votingAdapterERC20V1Datas: [
                {
                  params: votingAdapterERC20V1Params1,
                  token: randomVotesERC20Contract,
                },
              ],
              numberOfNewContracts: 6,
            });
          });
        });

        describe('With VotesERC20LockableV1 tokens', () => {
          it('deploys with a single VotesERC20LockableV1 token', async () => {
            const setupSafeParams = createSetupSafeParams({
              votesERC20Params: {
                votesERC20V1Params: [],
                votesERC20LockableV1Params: [votesERC20LockableV1Params1],
              },
              azoriusGovernanceParams: {
                proposerAdapterParams: {
                  proposerAdapterERC20V1Params: [proposerAdapterERC20V1Params1],
                  proposerAdapterERC721V1Params: [],
                  proposerAdapterHatsV1Params: [],
                },
                strategyV1Params,
                votingAdapterParams: {
                  votingAdapterERC20V1Params: [votingAdapterERC20V1Params1],
                  votingAdapterERC721V1Params: [],
                },
                moduleAzoriusV1Params,
              },
            });

            const { safeAddress, receipt } = await deploySafeWithSetup({
              fixtureData,
              owners,
              threshold,
              setupSafeParams,
            });

            await findAndVerifySafe({
              fixtureData,
              receipt,
              safeAddress,
              owners,
              threshold,
              votesERC20Datas: [[], [votesERC20LockableV1Params1]],
              proposerAdapterERC20V1Datas: [
                {
                  params: proposerAdapterERC20V1Params1,
                  token: randomVotesERC20Contract,
                },
              ],
              strategyV1Params,
              moduleAzoriusV1Params,
              votingAdapterERC20V1Datas: [
                {
                  params: votingAdapterERC20V1Params1,
                  token: randomVotesERC20Contract,
                },
              ],
              numberOfNewContracts: 5,
            });
          });

          it('deploys with multiple VotesERC20LockableV1 tokens', async () => {
            const setupSafeParams = createSetupSafeParams({
              votesERC20Params: {
                votesERC20V1Params: [],
                votesERC20LockableV1Params: [
                  votesERC20LockableV1Params1,
                  votesERC20LockableV1Params2,
                ],
              },
              azoriusGovernanceParams: {
                proposerAdapterParams: {
                  proposerAdapterERC20V1Params: [proposerAdapterERC20V1Params1],
                  proposerAdapterERC721V1Params: [],
                  proposerAdapterHatsV1Params: [],
                },
                strategyV1Params,
                votingAdapterParams: {
                  votingAdapterERC20V1Params: [votingAdapterERC20V1Params1],
                  votingAdapterERC721V1Params: [],
                },
                moduleAzoriusV1Params,
              },
            });

            const { safeAddress, receipt } = await deploySafeWithSetup({
              fixtureData,
              owners,
              threshold,
              setupSafeParams,
            });

            await findAndVerifySafe({
              fixtureData,
              receipt,
              safeAddress,
              owners,
              threshold,
              votesERC20Datas: [[], [votesERC20LockableV1Params1, votesERC20LockableV1Params2]],
              proposerAdapterERC20V1Datas: [
                {
                  params: proposerAdapterERC20V1Params1,
                  token: randomVotesERC20Contract,
                },
              ],
              strategyV1Params,
              moduleAzoriusV1Params,
              votingAdapterERC20V1Datas: [
                {
                  params: votingAdapterERC20V1Params1,
                  token: randomVotesERC20Contract,
                },
              ],
              numberOfNewContracts: 6,
            });
          });
        });

        describe('With VotesERC20V1 and VotesERC20LockableV1 tokens', () => {
          it('deploys with a mix of VotesERC20V1 and VotesERC20LockableV1 tokens', async () => {
            const setupSafeParams = createSetupSafeParams({
              votesERC20Params: {
                votesERC20V1Params: [votesERC20V1Params1],
                votesERC20LockableV1Params: [votesERC20LockableV1Params1],
              },
              azoriusGovernanceParams: {
                proposerAdapterParams: {
                  proposerAdapterERC20V1Params: [proposerAdapterERC20V1Params1],
                  proposerAdapterERC721V1Params: [],
                  proposerAdapterHatsV1Params: [],
                },
                strategyV1Params,
                votingAdapterParams: {
                  votingAdapterERC20V1Params: [votingAdapterERC20V1Params1],
                  votingAdapterERC721V1Params: [],
                },
                moduleAzoriusV1Params,
              },
            });

            const { safeAddress, receipt } = await deploySafeWithSetup({
              fixtureData,
              owners,
              threshold,
              setupSafeParams,
            });

            await findAndVerifySafe({
              fixtureData,
              receipt,
              safeAddress,
              owners,
              threshold,
              votesERC20Datas: [[votesERC20V1Params1], [votesERC20LockableV1Params1]],
              proposerAdapterERC20V1Datas: [
                {
                  params: proposerAdapterERC20V1Params1,
                  token: randomVotesERC20Contract,
                },
              ],
              strategyV1Params,
              moduleAzoriusV1Params,
              votingAdapterERC20V1Datas: [
                {
                  params: votingAdapterERC20V1Params1,
                  token: randomVotesERC20Contract,
                },
              ],
              numberOfNewContracts: 6,
            });
          });
        });
      });

      describe('With Voting Adapters', () => {
        describe('ERC20 voting adapters', () => {
          describe('No new tokens', () => {
            it('deploys with a VotingAdapterERC20V1 pointing to an existing token', async () => {
              const setupSafeParams = createSetupSafeParams({
                azoriusGovernanceParams: {
                  votingAdapterParams: {
                    votingAdapterERC20V1Params: [votingAdapterERC20V1Params1],
                    votingAdapterERC721V1Params: [],
                  },
                  proposerAdapterParams: {
                    proposerAdapterERC20V1Params: [proposerAdapterERC20V1Params1],
                    proposerAdapterERC721V1Params: [],
                    proposerAdapterHatsV1Params: [],
                  },
                  strategyV1Params,
                  moduleAzoriusV1Params,
                },
              });

              const { safeAddress, receipt } = await deploySafeWithSetup({
                fixtureData,
                owners,
                threshold,
                setupSafeParams,
              });

              await findAndVerifySafe({
                fixtureData,
                receipt,
                safeAddress,
                owners,
                threshold,
                proposerAdapterERC20V1Datas: [
                  {
                    params: proposerAdapterERC20V1Params1,
                    token: randomVotesERC20Contract,
                  },
                ],
                strategyV1Params,
                moduleAzoriusV1Params,
                votingAdapterERC20V1Datas: [
                  {
                    params: votingAdapterERC20V1Params1,
                    token: randomVotesERC20Contract,
                  },
                ],
                numberOfNewContracts: 4,
              });
            });

            it('deploys multiple VotingAdapterERC20V1s pointing to existing tokens', async () => {
              const setupSafeParams = createSetupSafeParams({
                azoriusGovernanceParams: {
                  votingAdapterParams: {
                    votingAdapterERC20V1Params: [
                      votingAdapterERC20V1Params1,
                      votingAdapterERC20V1Params2,
                    ],
                    votingAdapterERC721V1Params: [],
                  },
                  proposerAdapterParams: {
                    proposerAdapterERC20V1Params: [proposerAdapterERC20V1Params1],
                    proposerAdapterERC721V1Params: [],
                    proposerAdapterHatsV1Params: [],
                  },
                  strategyV1Params,
                  moduleAzoriusV1Params,
                },
              });

              const { safeAddress, receipt } = await deploySafeWithSetup({
                fixtureData,
                owners,
                threshold,
                setupSafeParams,
              });

              await findAndVerifySafe({
                fixtureData,
                receipt,
                safeAddress,
                owners,
                threshold,
                proposerAdapterERC20V1Datas: [
                  {
                    params: proposerAdapterERC20V1Params1,
                    token: randomVotesERC20Contract,
                  },
                ],
                strategyV1Params,
                moduleAzoriusV1Params,
                votingAdapterERC20V1Datas: [
                  {
                    params: votingAdapterERC20V1Params1,
                    token: randomVotesERC20Contract,
                  },
                  {
                    params: votingAdapterERC20V1Params2,
                    token: randomVotesERC20Contract,
                  },
                ],
                numberOfNewContracts: 5,
              });
            });
          });

          describe('One new VotesERC20 token', () => {
            it('deploys a VotingAdapterERC20V1 pointing to the new token', async () => {
              votingAdapterERC20V1Params1 = {
                ...votingAdapterERC20V1Params1,
                token: ethers.ZeroAddress,
                index: { typeI: 0, tokenI: 0 },
              };

              const setupSafeParams = createSetupSafeParams({
                votesERC20Params: {
                  votesERC20V1Params: [votesERC20V1Params1],
                  votesERC20LockableV1Params: [],
                },
                azoriusGovernanceParams: {
                  votingAdapterParams: {
                    votingAdapterERC20V1Params: [votingAdapterERC20V1Params1],
                    votingAdapterERC721V1Params: [],
                  },
                  proposerAdapterParams: {
                    proposerAdapterERC20V1Params: [proposerAdapterERC20V1Params1],
                    proposerAdapterERC721V1Params: [],
                    proposerAdapterHatsV1Params: [],
                  },
                  strategyV1Params,
                  moduleAzoriusV1Params,
                },
              });

              const { safeAddress, receipt } = await deploySafeWithSetup({
                fixtureData,
                owners,
                threshold,
                setupSafeParams,
              });

              await findAndVerifySafe({
                fixtureData,
                receipt,
                safeAddress,
                owners,
                threshold,
                votesERC20Datas: [[votesERC20V1Params1], []],
                proposerAdapterERC20V1Datas: [
                  {
                    params: proposerAdapterERC20V1Params1,
                    token: randomVotesERC20Contract,
                  },
                ],
                strategyV1Params,
                moduleAzoriusV1Params,
                votingAdapterERC20V1Datas: [{ params: votingAdapterERC20V1Params1 }],
                numberOfNewContracts: 5,
              });
            });

            it('deploys multiple VotingAdapterERC20V1s pointing to the same new token', async () => {
              votingAdapterERC20V1Params1 = {
                ...votingAdapterERC20V1Params1,
                token: ethers.ZeroAddress,
                index: { typeI: 0, tokenI: 0 },
              };

              votingAdapterERC20V1Params2 = {
                ...votingAdapterERC20V1Params2,
                token: ethers.ZeroAddress,
                index: { typeI: 0, tokenI: 0 },
              };

              const setupSafeParams = createSetupSafeParams({
                votesERC20Params: {
                  votesERC20V1Params: [votesERC20V1Params1],
                  votesERC20LockableV1Params: [],
                },
                azoriusGovernanceParams: {
                  votingAdapterParams: {
                    votingAdapterERC20V1Params: [
                      votingAdapterERC20V1Params1,
                      votingAdapterERC20V1Params2,
                    ],
                    votingAdapterERC721V1Params: [],
                  },
                  proposerAdapterParams: {
                    proposerAdapterERC20V1Params: [proposerAdapterERC20V1Params1],
                    proposerAdapterERC721V1Params: [],
                    proposerAdapterHatsV1Params: [],
                  },
                  strategyV1Params,
                  moduleAzoriusV1Params,
                },
              });

              const { safeAddress, receipt } = await deploySafeWithSetup({
                fixtureData,
                owners,
                threshold,
                setupSafeParams,
              });

              await findAndVerifySafe({
                fixtureData,
                receipt,
                safeAddress,
                owners,
                threshold,
                votesERC20Datas: [[votesERC20V1Params1], []],
                proposerAdapterERC20V1Datas: [
                  {
                    params: proposerAdapterERC20V1Params1,
                    token: randomVotesERC20Contract,
                  },
                ],
                strategyV1Params,
                moduleAzoriusV1Params,
                votingAdapterERC20V1Datas: [
                  { params: votingAdapterERC20V1Params1 },
                  { params: votingAdapterERC20V1Params2 },
                ],
                numberOfNewContracts: 6,
              });
            });

            it('reverts if the VotingAdapterERC20 points to an invalid new token index', async () => {
              const setupSafeParams = createSetupSafeParams({
                votesERC20Params: {
                  votesERC20V1Params: [votesERC20V1Params1],
                  votesERC20LockableV1Params: [],
                },
                azoriusGovernanceParams: {
                  votingAdapterParams: {
                    votingAdapterERC20V1Params: [votingAdapterERC20V1Params1],
                    votingAdapterERC721V1Params: [],
                  },
                  proposerAdapterParams: {
                    proposerAdapterERC20V1Params: [proposerAdapterERC20V1Params1],
                    proposerAdapterERC721V1Params: [],
                    proposerAdapterHatsV1Params: [],
                  },
                  strategyV1Params,
                  moduleAzoriusV1Params,
                },
              });

              const data = {
                fixtureData,
                owners,
                threshold,
                setupSafeParams,
              };

              // initial deployment should succeed
              await deploySafeWithSetup(data);

              // now updating the setupSafeParams to include an invalid index should fail
              // also the default votingAdapterERC20V1Params1 token is an external token, so set it to zero address so index is used
              data.setupSafeParams.azoriusGovernanceParams.votingAdapterParams.votingAdapterERC20V1Params[0].index =
                { typeI: 0, tokenI: 1 };
              data.setupSafeParams.azoriusGovernanceParams.votingAdapterParams.votingAdapterERC20V1Params[0].token =
                ethers.ZeroAddress;

              await expect(deploySafeWithSetup(data)).to.be.reverted;
            });
          });

          describe('Multiple new VotesERC20 tokens', () => {
            it('deploys a VotingAdapterERC20V1 pointing to one of the new tokens', async () => {
              votingAdapterERC20V1Params1 = {
                ...votingAdapterERC20V1Params1,
                token: ethers.ZeroAddress,
                index: { typeI: 0, tokenI: 1 },
              };

              const setupSafeParams = createSetupSafeParams({
                votesERC20Params: {
                  votesERC20V1Params: [votesERC20V1Params1, votesERC20V1Params2],
                  votesERC20LockableV1Params: [],
                },
                azoriusGovernanceParams: {
                  votingAdapterParams: {
                    votingAdapterERC20V1Params: [votingAdapterERC20V1Params1],
                    votingAdapterERC721V1Params: [],
                  },
                  proposerAdapterParams: {
                    proposerAdapterERC20V1Params: [proposerAdapterERC20V1Params1],
                    proposerAdapterERC721V1Params: [],
                    proposerAdapterHatsV1Params: [],
                  },
                  strategyV1Params,
                  moduleAzoriusV1Params,
                },
              });

              const { safeAddress, receipt } = await deploySafeWithSetup({
                fixtureData,
                owners,
                threshold,
                setupSafeParams,
              });

              await findAndVerifySafe({
                fixtureData,
                receipt,
                safeAddress,
                owners,
                threshold,
                votesERC20Datas: [[votesERC20V1Params1, votesERC20V1Params2], []],
                proposerAdapterERC20V1Datas: [
                  {
                    params: proposerAdapterERC20V1Params1,
                    token: randomVotesERC20Contract,
                  },
                ],
                strategyV1Params,
                moduleAzoriusV1Params,
                votingAdapterERC20V1Datas: [{ params: votingAdapterERC20V1Params1 }],
                numberOfNewContracts: 6,
              });
            });

            it('deploys multiple VotingAdapterERC20V1s, each pointing to one of the new tokens', async () => {
              votingAdapterERC20V1Params1 = {
                ...votingAdapterERC20V1Params1,
                token: ethers.ZeroAddress,
                index: { typeI: 0, tokenI: 1 },
              };

              votingAdapterERC20V1Params2 = {
                ...votingAdapterERC20V1Params2,
                token: ethers.ZeroAddress,
                index: { typeI: 0, tokenI: 0 },
              };

              const setupSafeParams = createSetupSafeParams({
                votesERC20Params: {
                  votesERC20V1Params: [votesERC20V1Params1, votesERC20V1Params2],
                  votesERC20LockableV1Params: [],
                },
                azoriusGovernanceParams: {
                  votingAdapterParams: {
                    votingAdapterERC20V1Params: [
                      votingAdapterERC20V1Params1,
                      votingAdapterERC20V1Params2,
                    ],
                    votingAdapterERC721V1Params: [],
                  },
                  proposerAdapterParams: {
                    proposerAdapterERC20V1Params: [proposerAdapterERC20V1Params1],
                    proposerAdapterERC721V1Params: [],
                    proposerAdapterHatsV1Params: [],
                  },
                  strategyV1Params,
                  moduleAzoriusV1Params,
                },
              });

              const { safeAddress, receipt } = await deploySafeWithSetup({
                fixtureData,
                owners,
                threshold,
                setupSafeParams,
              });

              await findAndVerifySafe({
                fixtureData,
                receipt,
                safeAddress,
                owners,
                threshold,
                votesERC20Datas: [[votesERC20V1Params1, votesERC20V1Params2], []],
                proposerAdapterERC20V1Datas: [
                  {
                    params: proposerAdapterERC20V1Params1,
                    token: randomVotesERC20Contract,
                  },
                ],
                strategyV1Params,
                moduleAzoriusV1Params,
                votingAdapterERC20V1Datas: [
                  { params: votingAdapterERC20V1Params1 },
                  { params: votingAdapterERC20V1Params2 },
                ],
                numberOfNewContracts: 7,
              });
            });
          });

          describe('One new VotesERC20Lockable token', () => {
            it('deploys a VotingAdapterERC20V1 pointing to the new token', async () => {
              votingAdapterERC20V1Params1 = {
                ...votingAdapterERC20V1Params1,
                token: ethers.ZeroAddress,
                index: { typeI: 1, tokenI: 0 },
              };

              const setupSafeParams = createSetupSafeParams({
                votesERC20Params: {
                  votesERC20V1Params: [],
                  votesERC20LockableV1Params: [votesERC20LockableV1Params1],
                },
                azoriusGovernanceParams: {
                  votingAdapterParams: {
                    votingAdapterERC20V1Params: [votingAdapterERC20V1Params1],
                    votingAdapterERC721V1Params: [],
                  },
                  proposerAdapterParams: {
                    proposerAdapterERC20V1Params: [proposerAdapterERC20V1Params1],
                    proposerAdapterERC721V1Params: [],
                    proposerAdapterHatsV1Params: [],
                  },
                  strategyV1Params,
                  moduleAzoriusV1Params,
                },
              });

              const { safeAddress, receipt } = await deploySafeWithSetup({
                fixtureData,
                owners,
                threshold,
                setupSafeParams,
              });

              await findAndVerifySafe({
                fixtureData,
                receipt,
                safeAddress,
                owners,
                threshold,
                votesERC20Datas: [[], [votesERC20LockableV1Params1]],
                proposerAdapterERC20V1Datas: [
                  {
                    params: proposerAdapterERC20V1Params1,
                    token: randomVotesERC20Contract,
                  },
                ],
                strategyV1Params,
                moduleAzoriusV1Params,
                votingAdapterERC20V1Datas: [{ params: votingAdapterERC20V1Params1 }],
                numberOfNewContracts: 5,
              });
            });

            it('deploys multiple VotingAdapterERC20V1s pointing to the same new token', async () => {
              votingAdapterERC20V1Params1 = {
                ...votingAdapterERC20V1Params1,
                token: ethers.ZeroAddress,
                index: { typeI: 1, tokenI: 0 },
              };

              votingAdapterERC20V1Params2 = {
                ...votingAdapterERC20V1Params2,
                token: ethers.ZeroAddress,
                index: { typeI: 1, tokenI: 0 },
              };

              const setupSafeParams = createSetupSafeParams({
                votesERC20Params: {
                  votesERC20V1Params: [],
                  votesERC20LockableV1Params: [votesERC20LockableV1Params1],
                },
                azoriusGovernanceParams: {
                  votingAdapterParams: {
                    votingAdapterERC20V1Params: [
                      votingAdapterERC20V1Params1,
                      votingAdapterERC20V1Params2,
                    ],
                    votingAdapterERC721V1Params: [],
                  },
                  proposerAdapterParams: {
                    proposerAdapterERC20V1Params: [proposerAdapterERC20V1Params1],
                    proposerAdapterERC721V1Params: [],
                    proposerAdapterHatsV1Params: [],
                  },
                  strategyV1Params,
                  moduleAzoriusV1Params,
                },
              });

              const { safeAddress, receipt } = await deploySafeWithSetup({
                fixtureData,
                owners,
                threshold,
                setupSafeParams,
              });

              await findAndVerifySafe({
                fixtureData,
                receipt,
                safeAddress,
                owners,
                threshold,
                votesERC20Datas: [[], [votesERC20LockableV1Params1]],
                proposerAdapterERC20V1Datas: [
                  {
                    params: proposerAdapterERC20V1Params1,
                    token: randomVotesERC20Contract,
                  },
                ],
                strategyV1Params,
                moduleAzoriusV1Params,
                votingAdapterERC20V1Datas: [
                  { params: votingAdapterERC20V1Params1 },
                  { params: votingAdapterERC20V1Params2 },
                ],
                numberOfNewContracts: 6,
              });
            });

            it('reverts if the VotingAdapterERC20 points to an invalid new token index', async () => {
              const setupSafeParams = createSetupSafeParams({
                votesERC20Params: {
                  votesERC20V1Params: [],
                  votesERC20LockableV1Params: [votesERC20LockableV1Params1],
                },
                azoriusGovernanceParams: {
                  votingAdapterParams: {
                    votingAdapterERC20V1Params: [votingAdapterERC20V1Params1],
                    votingAdapterERC721V1Params: [],
                  },
                  proposerAdapterParams: {
                    proposerAdapterERC20V1Params: [proposerAdapterERC20V1Params1],
                    proposerAdapterERC721V1Params: [],
                    proposerAdapterHatsV1Params: [],
                  },
                  strategyV1Params,
                  moduleAzoriusV1Params,
                },
              });

              const data = {
                fixtureData,
                owners,
                threshold,
                setupSafeParams,
              };

              // initial deployment should succeed
              await deploySafeWithSetup(data);

              // now updating the setupSafeParams to include an invalid index should fail
              // also the default votingAdapterERC20V1Params1 token is an external token, so set it to zero address so index is used
              data.setupSafeParams.azoriusGovernanceParams.votingAdapterParams.votingAdapterERC20V1Params[0].index =
                { typeI: 1, tokenI: 1 };
              data.setupSafeParams.azoriusGovernanceParams.votingAdapterParams.votingAdapterERC20V1Params[0].token =
                ethers.ZeroAddress;

              await expect(deploySafeWithSetup(data)).to.be.reverted;
            });
          });

          describe('Multiple new VotesERC20Lockable tokens', () => {
            it('deploys a VotingAdapterERC20V1 pointing to one of the new tokens', async () => {
              votingAdapterERC20V1Params1 = {
                ...votingAdapterERC20V1Params1,
                token: ethers.ZeroAddress,
                index: { typeI: 1, tokenI: 1 },
              };

              const setupSafeParams = createSetupSafeParams({
                votesERC20Params: {
                  votesERC20V1Params: [],
                  votesERC20LockableV1Params: [
                    votesERC20LockableV1Params1,
                    votesERC20LockableV1Params2,
                  ],
                },
                azoriusGovernanceParams: {
                  votingAdapterParams: {
                    votingAdapterERC20V1Params: [votingAdapterERC20V1Params1],
                    votingAdapterERC721V1Params: [],
                  },
                  proposerAdapterParams: {
                    proposerAdapterERC20V1Params: [proposerAdapterERC20V1Params1],
                    proposerAdapterERC721V1Params: [],
                    proposerAdapterHatsV1Params: [],
                  },
                  strategyV1Params,
                  moduleAzoriusV1Params,
                },
              });

              const { safeAddress, receipt } = await deploySafeWithSetup({
                fixtureData,
                owners,
                threshold,
                setupSafeParams,
              });

              await findAndVerifySafe({
                fixtureData,
                receipt,
                safeAddress,
                owners,
                threshold,
                votesERC20Datas: [[], [votesERC20LockableV1Params1, votesERC20LockableV1Params2]],
                proposerAdapterERC20V1Datas: [
                  {
                    params: proposerAdapterERC20V1Params1,
                    token: randomVotesERC20Contract,
                  },
                ],
                strategyV1Params,
                moduleAzoriusV1Params,
                votingAdapterERC20V1Datas: [{ params: votingAdapterERC20V1Params1 }],
                numberOfNewContracts: 6,
              });
            });

            it('deploys multiple VotingAdapterERC20V1s, each pointing to one of the new tokens', async () => {
              votingAdapterERC20V1Params1 = {
                ...votingAdapterERC20V1Params1,
                token: ethers.ZeroAddress,
                index: { typeI: 1, tokenI: 1 },
              };

              votingAdapterERC20V1Params2 = {
                ...votingAdapterERC20V1Params2,
                token: ethers.ZeroAddress,
                index: { typeI: 1, tokenI: 0 },
              };

              const setupSafeParams = createSetupSafeParams({
                votesERC20Params: {
                  votesERC20V1Params: [],
                  votesERC20LockableV1Params: [
                    votesERC20LockableV1Params1,
                    votesERC20LockableV1Params2,
                  ],
                },
                azoriusGovernanceParams: {
                  votingAdapterParams: {
                    votingAdapterERC20V1Params: [
                      votingAdapterERC20V1Params1,
                      votingAdapterERC20V1Params2,
                    ],
                    votingAdapterERC721V1Params: [],
                  },
                  proposerAdapterParams: {
                    proposerAdapterERC20V1Params: [proposerAdapterERC20V1Params1],
                    proposerAdapterERC721V1Params: [],
                    proposerAdapterHatsV1Params: [],
                  },
                  strategyV1Params,
                  moduleAzoriusV1Params,
                },
              });

              const { safeAddress, receipt } = await deploySafeWithSetup({
                fixtureData,
                owners,
                threshold,
                setupSafeParams,
              });

              await findAndVerifySafe({
                fixtureData,
                receipt,
                safeAddress,
                owners,
                threshold,
                votesERC20Datas: [[], [votesERC20LockableV1Params1, votesERC20LockableV1Params2]],
                proposerAdapterERC20V1Datas: [
                  {
                    params: proposerAdapterERC20V1Params1,
                    token: randomVotesERC20Contract,
                  },
                ],
                strategyV1Params,
                moduleAzoriusV1Params,
                votingAdapterERC20V1Datas: [
                  { params: votingAdapterERC20V1Params1 },
                  { params: votingAdapterERC20V1Params2 },
                ],
                numberOfNewContracts: 7,
              });
            });
          });

          describe('New VotesERC20 and VotesERC20Lockable tokens', () => {
            it('deploys a VotingAdapterERC20V1 pointing to one of the new tokens', async () => {
              votingAdapterERC20V1Params1 = {
                ...votingAdapterERC20V1Params1,
                token: ethers.ZeroAddress,
                index: { typeI: 1, tokenI: 1 },
              };

              const setupSafeParams = createSetupSafeParams({
                votesERC20Params: {
                  votesERC20V1Params: [votesERC20V1Params1, votesERC20V1Params2],
                  votesERC20LockableV1Params: [
                    votesERC20LockableV1Params1,
                    votesERC20LockableV1Params2,
                  ],
                },
                azoriusGovernanceParams: {
                  votingAdapterParams: {
                    votingAdapterERC20V1Params: [votingAdapterERC20V1Params1],
                    votingAdapterERC721V1Params: [],
                  },
                  proposerAdapterParams: {
                    proposerAdapterERC20V1Params: [proposerAdapterERC20V1Params1],
                    proposerAdapterERC721V1Params: [],
                    proposerAdapterHatsV1Params: [],
                  },
                  strategyV1Params,
                  moduleAzoriusV1Params,
                },
              });

              const { safeAddress, receipt } = await deploySafeWithSetup({
                fixtureData,
                owners,
                threshold,
                setupSafeParams,
              });

              await findAndVerifySafe({
                fixtureData,
                receipt,
                safeAddress,
                owners,
                threshold,
                votesERC20Datas: [
                  [votesERC20V1Params1, votesERC20V1Params2],
                  [votesERC20LockableV1Params1, votesERC20LockableV1Params2],
                ],
                proposerAdapterERC20V1Datas: [
                  {
                    params: proposerAdapterERC20V1Params1,
                    token: randomVotesERC20Contract,
                  },
                ],
                strategyV1Params,
                moduleAzoriusV1Params,
                votingAdapterERC20V1Datas: [{ params: votingAdapterERC20V1Params1 }],
                numberOfNewContracts: 8,
              });
            });

            it('deploys multiple VotingAdapterERC20V1s, each pointing to one of the new tokens', async () => {
              votingAdapterERC20V1Params1 = {
                ...votingAdapterERC20V1Params1,
                token: ethers.ZeroAddress,
                index: { typeI: 1, tokenI: 1 },
              };

              votingAdapterERC20V1Params2 = {
                ...votingAdapterERC20V1Params2,
                token: ethers.ZeroAddress,
                index: { typeI: 0, tokenI: 0 },
              };

              const setupSafeParams = createSetupSafeParams({
                votesERC20Params: {
                  votesERC20V1Params: [votesERC20V1Params1, votesERC20V1Params2],
                  votesERC20LockableV1Params: [
                    votesERC20LockableV1Params1,
                    votesERC20LockableV1Params2,
                  ],
                },
                azoriusGovernanceParams: {
                  votingAdapterParams: {
                    votingAdapterERC20V1Params: [
                      votingAdapterERC20V1Params1,
                      votingAdapterERC20V1Params2,
                    ],
                    votingAdapterERC721V1Params: [],
                  },
                  proposerAdapterParams: {
                    proposerAdapterERC20V1Params: [proposerAdapterERC20V1Params1],
                    proposerAdapterERC721V1Params: [],
                    proposerAdapterHatsV1Params: [],
                  },
                  strategyV1Params,
                  moduleAzoriusV1Params,
                },
              });

              const { safeAddress, receipt } = await deploySafeWithSetup({
                fixtureData,
                owners,
                threshold,
                setupSafeParams,
              });

              await findAndVerifySafe({
                fixtureData,
                receipt,
                safeAddress,
                owners,
                threshold,
                votesERC20Datas: [
                  [votesERC20V1Params1, votesERC20V1Params2],
                  [votesERC20LockableV1Params1, votesERC20LockableV1Params2],
                ],
                proposerAdapterERC20V1Datas: [
                  {
                    params: proposerAdapterERC20V1Params1,
                    token: randomVotesERC20Contract,
                  },
                ],
                strategyV1Params,
                moduleAzoriusV1Params,
                votingAdapterERC20V1Datas: [
                  { params: votingAdapterERC20V1Params1 },
                  { params: votingAdapterERC20V1Params2 },
                ],
                numberOfNewContracts: 9,
              });
            });
          });
        });

        describe('ERC721 voting adapters', () => {
          it('deploys successfully with one VotingAdapterERC721', async () => {
            const setupSafeParams = createSetupSafeParams({
              azoriusGovernanceParams: {
                votingAdapterParams: {
                  votingAdapterERC20V1Params: [],
                  votingAdapterERC721V1Params: [votingAdapterERC721V1Params1],
                },
                proposerAdapterParams: {
                  proposerAdapterERC20V1Params: [proposerAdapterERC20V1Params1],
                  proposerAdapterERC721V1Params: [],
                  proposerAdapterHatsV1Params: [],
                },
                strategyV1Params,
                moduleAzoriusV1Params,
              },
            });

            const { safeAddress, receipt } = await deploySafeWithSetup({
              fixtureData,
              owners,
              threshold,
              setupSafeParams,
            });

            await findAndVerifySafe({
              fixtureData,
              receipt,
              safeAddress,
              owners,
              threshold,
              proposerAdapterERC20V1Datas: [
                {
                  params: proposerAdapterERC20V1Params1,
                  token: randomVotesERC20Contract,
                },
              ],
              strategyV1Params,
              moduleAzoriusV1Params,
              votingAdapterERC721V1Datas: [{ params: votingAdapterERC721V1Params1 }],
              numberOfNewContracts: 4,
            });
          });

          it('deploys successfully with multiple VotingAdapterERC721s', async () => {
            const setupSafeParams = createSetupSafeParams({
              azoriusGovernanceParams: {
                votingAdapterParams: {
                  votingAdapterERC20V1Params: [],
                  votingAdapterERC721V1Params: [
                    votingAdapterERC721V1Params1,
                    votingAdapterERC721V1Params2,
                  ],
                },
                proposerAdapterParams: {
                  proposerAdapterERC20V1Params: [proposerAdapterERC20V1Params1],
                  proposerAdapterERC721V1Params: [],
                  proposerAdapterHatsV1Params: [],
                },
                strategyV1Params,
                moduleAzoriusV1Params,
              },
            });

            const { safeAddress, receipt } = await deploySafeWithSetup({
              fixtureData,
              owners,
              threshold,
              setupSafeParams,
            });

            await findAndVerifySafe({
              fixtureData,
              receipt,
              safeAddress,
              owners,
              threshold,
              proposerAdapterERC20V1Datas: [
                {
                  params: proposerAdapterERC20V1Params1,
                  token: randomVotesERC20Contract,
                },
              ],
              strategyV1Params,
              moduleAzoriusV1Params,
              votingAdapterERC721V1Datas: [
                { params: votingAdapterERC721V1Params1 },
                { params: votingAdapterERC721V1Params2 },
              ],
              numberOfNewContracts: 5,
            });
          });
        });

        describe('Mixed voting adapters', () => {
          it('deploys successfully with multiple voting adapters', async () => {
            const setupSafeParams = createSetupSafeParams({
              azoriusGovernanceParams: {
                votingAdapterParams: {
                  votingAdapterERC20V1Params: [votingAdapterERC20V1Params1],
                  votingAdapterERC721V1Params: [votingAdapterERC721V1Params1],
                },
                proposerAdapterParams: {
                  proposerAdapterERC20V1Params: [proposerAdapterERC20V1Params1],
                  proposerAdapterERC721V1Params: [],
                  proposerAdapterHatsV1Params: [],
                },
                strategyV1Params,
                moduleAzoriusV1Params,
              },
            });

            const { safeAddress, receipt } = await deploySafeWithSetup({
              fixtureData,
              owners,
              threshold,
              setupSafeParams,
            });

            await findAndVerifySafe({
              fixtureData,
              receipt,
              safeAddress,
              owners,
              threshold,
              proposerAdapterERC20V1Datas: [
                {
                  params: proposerAdapterERC20V1Params1,
                  token: randomVotesERC20Contract,
                },
              ],
              strategyV1Params,
              moduleAzoriusV1Params,
              votingAdapterERC20V1Datas: [
                { params: votingAdapterERC20V1Params1, token: randomVotesERC20Contract },
              ],
              votingAdapterERC721V1Datas: [{ params: votingAdapterERC721V1Params1 }],
              numberOfNewContracts: 5,
            });
          });
        });
      });

      describe('With Proposer Adapters', () => {
        describe('ERC20 proposer adapters', () => {
          describe('No new tokens', () => {
            it('deploys with a ProposerAdapterERC20V1 pointing to an existing token', async () => {
              // Note: this is same test as "deploys with a VotingAdapterERC20V1 pointing to an existing token"
              const setupSafeParams = createSetupSafeParams({
                azoriusGovernanceParams: {
                  votingAdapterParams: {
                    votingAdapterERC20V1Params: [votingAdapterERC20V1Params1],
                    votingAdapterERC721V1Params: [],
                  },
                  proposerAdapterParams: {
                    proposerAdapterERC20V1Params: [proposerAdapterERC20V1Params1],
                    proposerAdapterERC721V1Params: [],
                    proposerAdapterHatsV1Params: [],
                  },
                  strategyV1Params,
                  moduleAzoriusV1Params,
                },
              });

              const { safeAddress, receipt } = await deploySafeWithSetup({
                fixtureData,
                owners,
                threshold,
                setupSafeParams,
              });

              await findAndVerifySafe({
                fixtureData,
                receipt,
                safeAddress,
                owners,
                threshold,
                proposerAdapterERC20V1Datas: [
                  {
                    params: proposerAdapterERC20V1Params1,
                    token: randomVotesERC20Contract,
                  },
                ],
                strategyV1Params,
                moduleAzoriusV1Params,
                votingAdapterERC20V1Datas: [
                  {
                    params: votingAdapterERC20V1Params1,
                    token: randomVotesERC20Contract,
                  },
                ],
                numberOfNewContracts: 4,
              });
            });

            it('deploys multiple ProposerAdapterERC20V1s pointing to existing tokens', async () => {
              const setupSafeParams = createSetupSafeParams({
                azoriusGovernanceParams: {
                  votingAdapterParams: {
                    votingAdapterERC20V1Params: [votingAdapterERC20V1Params1],
                    votingAdapterERC721V1Params: [],
                  },
                  proposerAdapterParams: {
                    proposerAdapterERC20V1Params: [
                      proposerAdapterERC20V1Params1,
                      proposerAdapterERC20V1Params2,
                    ],
                    proposerAdapterERC721V1Params: [],
                    proposerAdapterHatsV1Params: [],
                  },
                  strategyV1Params,
                  moduleAzoriusV1Params,
                },
              });

              const { safeAddress, receipt } = await deploySafeWithSetup({
                fixtureData,
                owners,
                threshold,
                setupSafeParams,
              });

              await findAndVerifySafe({
                fixtureData,
                receipt,
                safeAddress,
                owners,
                threshold,
                proposerAdapterERC20V1Datas: [
                  {
                    params: proposerAdapterERC20V1Params1,
                    token: randomVotesERC20Contract,
                  },
                  {
                    params: proposerAdapterERC20V1Params2,
                    token: randomVotesERC20Contract,
                  },
                ],
                strategyV1Params,
                moduleAzoriusV1Params,
                votingAdapterERC20V1Datas: [
                  {
                    params: votingAdapterERC20V1Params1,
                    token: randomVotesERC20Contract,
                  },
                ],
                numberOfNewContracts: 5,
              });
            });
          });

          describe('One new VotesERC20 token', () => {
            it('deploys a ProposerAdapterERC20V1 pointing to the new token', async () => {
              proposerAdapterERC20V1Params1 = {
                ...proposerAdapterERC20V1Params1,
                token: ethers.ZeroAddress,
                index: { typeI: 0, tokenI: 0 },
              };

              const setupSafeParams = createSetupSafeParams({
                votesERC20Params: {
                  votesERC20V1Params: [votesERC20V1Params1],
                  votesERC20LockableV1Params: [],
                },
                azoriusGovernanceParams: {
                  votingAdapterParams: {
                    votingAdapterERC20V1Params: [votingAdapterERC20V1Params1],
                    votingAdapterERC721V1Params: [],
                  },
                  proposerAdapterParams: {
                    proposerAdapterERC20V1Params: [proposerAdapterERC20V1Params1],
                    proposerAdapterERC721V1Params: [],
                    proposerAdapterHatsV1Params: [],
                  },
                  strategyV1Params,
                  moduleAzoriusV1Params,
                },
              });

              const { safeAddress, receipt } = await deploySafeWithSetup({
                fixtureData,
                owners,
                threshold,
                setupSafeParams,
              });

              await findAndVerifySafe({
                fixtureData,
                receipt,
                safeAddress,
                owners,
                threshold,
                votesERC20Datas: [[votesERC20V1Params1], []],
                proposerAdapterERC20V1Datas: [{ params: proposerAdapterERC20V1Params1 }],
                strategyV1Params,
                moduleAzoriusV1Params,
                votingAdapterERC20V1Datas: [
                  { params: votingAdapterERC20V1Params1, token: randomVotesERC20Contract },
                ],
                numberOfNewContracts: 5,
              });
            });

            it('deploys multiple ProposerAdapterERC20V1s pointing to the same new token', async () => {
              proposerAdapterERC20V1Params1 = {
                ...proposerAdapterERC20V1Params1,
                token: ethers.ZeroAddress,
                index: { typeI: 0, tokenI: 0 },
              };

              proposerAdapterERC20V1Params2 = {
                ...proposerAdapterERC20V1Params2,
                token: ethers.ZeroAddress,
                index: { typeI: 0, tokenI: 0 },
              };

              const setupSafeParams = createSetupSafeParams({
                votesERC20Params: {
                  votesERC20V1Params: [votesERC20V1Params1],
                  votesERC20LockableV1Params: [],
                },
                azoriusGovernanceParams: {
                  votingAdapterParams: {
                    votingAdapterERC20V1Params: [votingAdapterERC20V1Params1],
                    votingAdapterERC721V1Params: [],
                  },
                  proposerAdapterParams: {
                    proposerAdapterERC20V1Params: [
                      proposerAdapterERC20V1Params1,
                      proposerAdapterERC20V1Params2,
                    ],
                    proposerAdapterERC721V1Params: [],
                    proposerAdapterHatsV1Params: [],
                  },
                  strategyV1Params,
                  moduleAzoriusV1Params,
                },
              });

              const { safeAddress, receipt } = await deploySafeWithSetup({
                fixtureData,
                owners,
                threshold,
                setupSafeParams,
              });

              await findAndVerifySafe({
                fixtureData,
                receipt,
                safeAddress,
                owners,
                threshold,
                votesERC20Datas: [[votesERC20V1Params1], []],
                proposerAdapterERC20V1Datas: [
                  { params: proposerAdapterERC20V1Params1 },
                  { params: proposerAdapterERC20V1Params2 },
                ],
                strategyV1Params,
                moduleAzoriusV1Params,
                votingAdapterERC20V1Datas: [
                  { params: votingAdapterERC20V1Params1, token: randomVotesERC20Contract },
                ],
                numberOfNewContracts: 6,
              });
            });

            it('reverts if the ProposerAdapterERC20 points to an invalid new token index', async () => {
              const setupSafeParams = createSetupSafeParams({
                votesERC20Params: {
                  votesERC20V1Params: [votesERC20V1Params1],
                  votesERC20LockableV1Params: [],
                },
                azoriusGovernanceParams: {
                  votingAdapterParams: {
                    votingAdapterERC20V1Params: [votingAdapterERC20V1Params1],
                    votingAdapterERC721V1Params: [],
                  },
                  proposerAdapterParams: {
                    proposerAdapterERC20V1Params: [proposerAdapterERC20V1Params1],
                    proposerAdapterERC721V1Params: [],
                    proposerAdapterHatsV1Params: [],
                  },
                  strategyV1Params,
                  moduleAzoriusV1Params,
                },
              });

              const data = {
                fixtureData,
                owners,
                threshold,
                setupSafeParams,
              };

              // initial deployment should succeed
              await deploySafeWithSetup(data);

              // now updating the setupSafeParams to include an invalid index should fail
              // also the default proposerAdapterERC20V1Params1 token is an external token, so set it to zero address so index is used
              data.setupSafeParams.azoriusGovernanceParams.proposerAdapterParams.proposerAdapterERC20V1Params[0].index =
                { typeI: 0, tokenI: 1 };
              data.setupSafeParams.azoriusGovernanceParams.proposerAdapterParams.proposerAdapterERC20V1Params[0].token =
                ethers.ZeroAddress;

              await expect(deploySafeWithSetup(data)).to.be.reverted;
            });
          });

          describe('Multiple new VotesERC20 tokens', () => {
            it('deploys a ProposerAdapterERC20V1 pointing to one of the new tokens', async () => {
              proposerAdapterERC20V1Params1 = {
                ...proposerAdapterERC20V1Params1,
                token: ethers.ZeroAddress,
                index: { typeI: 0, tokenI: 1 },
              };

              const setupSafeParams = createSetupSafeParams({
                votesERC20Params: {
                  votesERC20V1Params: [votesERC20V1Params1, votesERC20V1Params2],
                  votesERC20LockableV1Params: [],
                },
                azoriusGovernanceParams: {
                  votingAdapterParams: {
                    votingAdapterERC20V1Params: [votingAdapterERC20V1Params1],
                    votingAdapterERC721V1Params: [],
                  },
                  proposerAdapterParams: {
                    proposerAdapterERC20V1Params: [proposerAdapterERC20V1Params1],
                    proposerAdapterERC721V1Params: [],
                    proposerAdapterHatsV1Params: [],
                  },
                  strategyV1Params,
                  moduleAzoriusV1Params,
                },
              });

              const { safeAddress, receipt } = await deploySafeWithSetup({
                fixtureData,
                owners,
                threshold,
                setupSafeParams,
              });

              await findAndVerifySafe({
                fixtureData,
                receipt,
                safeAddress,
                owners,
                threshold,
                votesERC20Datas: [[votesERC20V1Params1, votesERC20V1Params2], []],
                proposerAdapterERC20V1Datas: [{ params: proposerAdapterERC20V1Params1 }],
                strategyV1Params,
                moduleAzoriusV1Params,
                votingAdapterERC20V1Datas: [
                  { params: votingAdapterERC20V1Params1, token: randomVotesERC20Contract },
                ],
                numberOfNewContracts: 6,
              });
            });

            it('deploys multiple ProposerAdapterERC20V1s, each pointing to one of the new tokens', async () => {
              proposerAdapterERC20V1Params1 = {
                ...proposerAdapterERC20V1Params1,
                token: ethers.ZeroAddress,
                index: { typeI: 0, tokenI: 1 },
              };

              proposerAdapterERC20V1Params2 = {
                ...proposerAdapterERC20V1Params2,
                token: ethers.ZeroAddress,
                index: { typeI: 0, tokenI: 0 },
              };

              const setupSafeParams = createSetupSafeParams({
                votesERC20Params: {
                  votesERC20V1Params: [votesERC20V1Params1, votesERC20V1Params2],
                  votesERC20LockableV1Params: [],
                },
                azoriusGovernanceParams: {
                  votingAdapterParams: {
                    votingAdapterERC20V1Params: [votingAdapterERC20V1Params1],
                    votingAdapterERC721V1Params: [],
                  },
                  proposerAdapterParams: {
                    proposerAdapterERC20V1Params: [
                      proposerAdapterERC20V1Params1,
                      proposerAdapterERC20V1Params2,
                    ],
                    proposerAdapterERC721V1Params: [],
                    proposerAdapterHatsV1Params: [],
                  },
                  strategyV1Params,
                  moduleAzoriusV1Params,
                },
              });

              const { safeAddress, receipt } = await deploySafeWithSetup({
                fixtureData,
                owners,
                threshold,
                setupSafeParams,
              });

              await findAndVerifySafe({
                fixtureData,
                receipt,
                safeAddress,
                owners,
                threshold,
                votesERC20Datas: [[votesERC20V1Params1, votesERC20V1Params2], []],
                proposerAdapterERC20V1Datas: [
                  { params: proposerAdapterERC20V1Params1 },
                  { params: proposerAdapterERC20V1Params2 },
                ],
                strategyV1Params,
                moduleAzoriusV1Params,
                votingAdapterERC20V1Datas: [
                  { params: votingAdapterERC20V1Params1, token: randomVotesERC20Contract },
                ],
                numberOfNewContracts: 7,
              });
            });
          });

          describe('One new VotesERC20Lockable token', () => {
            it('deploys a ProposerAdapterERC20V1 pointing to the new token', async () => {
              proposerAdapterERC20V1Params1 = {
                ...proposerAdapterERC20V1Params1,
                token: ethers.ZeroAddress,
                index: { typeI: 1, tokenI: 0 },
              };

              const setupSafeParams = createSetupSafeParams({
                votesERC20Params: {
                  votesERC20V1Params: [],
                  votesERC20LockableV1Params: [votesERC20LockableV1Params1],
                },
                azoriusGovernanceParams: {
                  votingAdapterParams: {
                    votingAdapterERC20V1Params: [votingAdapterERC20V1Params1],
                    votingAdapterERC721V1Params: [],
                  },
                  proposerAdapterParams: {
                    proposerAdapterERC20V1Params: [proposerAdapterERC20V1Params1],
                    proposerAdapterERC721V1Params: [],
                    proposerAdapterHatsV1Params: [],
                  },
                  strategyV1Params,
                  moduleAzoriusV1Params,
                },
              });

              const { safeAddress, receipt } = await deploySafeWithSetup({
                fixtureData,
                owners,
                threshold,
                setupSafeParams,
              });

              await findAndVerifySafe({
                fixtureData,
                receipt,
                safeAddress,
                owners,
                threshold,
                votesERC20Datas: [[], [votesERC20LockableV1Params1]],
                proposerAdapterERC20V1Datas: [{ params: proposerAdapterERC20V1Params1 }],
                strategyV1Params,
                moduleAzoriusV1Params,
                votingAdapterERC20V1Datas: [
                  { params: votingAdapterERC20V1Params1, token: randomVotesERC20Contract },
                ],
                numberOfNewContracts: 5,
              });
            });

            it('deploys multiple ProposerAdapterERC20V1s pointing to the same new token', async () => {
              proposerAdapterERC20V1Params1 = {
                ...proposerAdapterERC20V1Params1,
                token: ethers.ZeroAddress,
                index: { typeI: 1, tokenI: 0 },
              };

              proposerAdapterERC20V1Params2 = {
                ...proposerAdapterERC20V1Params2,
                token: ethers.ZeroAddress,
                index: { typeI: 1, tokenI: 0 },
              };

              const setupSafeParams = createSetupSafeParams({
                votesERC20Params: {
                  votesERC20V1Params: [],
                  votesERC20LockableV1Params: [votesERC20LockableV1Params1],
                },
                azoriusGovernanceParams: {
                  votingAdapterParams: {
                    votingAdapterERC20V1Params: [votingAdapterERC20V1Params1],
                    votingAdapterERC721V1Params: [],
                  },
                  proposerAdapterParams: {
                    proposerAdapterERC20V1Params: [
                      proposerAdapterERC20V1Params1,
                      proposerAdapterERC20V1Params2,
                    ],
                    proposerAdapterERC721V1Params: [],
                    proposerAdapterHatsV1Params: [],
                  },
                  strategyV1Params,
                  moduleAzoriusV1Params,
                },
              });

              const { safeAddress, receipt } = await deploySafeWithSetup({
                fixtureData,
                owners,
                threshold,
                setupSafeParams,
              });

              await findAndVerifySafe({
                fixtureData,
                receipt,
                safeAddress,
                owners,
                threshold,
                votesERC20Datas: [[], [votesERC20LockableV1Params1]],
                proposerAdapterERC20V1Datas: [
                  { params: proposerAdapterERC20V1Params1 },
                  { params: proposerAdapterERC20V1Params2 },
                ],
                strategyV1Params,
                moduleAzoriusV1Params,
                votingAdapterERC20V1Datas: [
                  { params: votingAdapterERC20V1Params1, token: randomVotesERC20Contract },
                ],
                numberOfNewContracts: 6,
              });
            });

            it('reverts if the ProposerAdapterERC20 points to an invalid new token index', async () => {
              const setupSafeParams = createSetupSafeParams({
                votesERC20Params: {
                  votesERC20V1Params: [],
                  votesERC20LockableV1Params: [votesERC20LockableV1Params1],
                },
                azoriusGovernanceParams: {
                  votingAdapterParams: {
                    votingAdapterERC20V1Params: [votingAdapterERC20V1Params1],
                    votingAdapterERC721V1Params: [],
                  },
                  proposerAdapterParams: {
                    proposerAdapterERC20V1Params: [proposerAdapterERC20V1Params1],
                    proposerAdapterERC721V1Params: [],
                    proposerAdapterHatsV1Params: [],
                  },
                  strategyV1Params,
                  moduleAzoriusV1Params,
                },
              });

              const data = {
                fixtureData,
                owners,
                threshold,
                setupSafeParams,
              };

              // initial deployment should succeed
              await deploySafeWithSetup(data);

              // now updating the setupSafeParams to include an invalid index should fail
              // also the default proposerAdapterERC20V1Params1 token is an external token, so set it to zero address so index is used
              data.setupSafeParams.azoriusGovernanceParams.proposerAdapterParams.proposerAdapterERC20V1Params[0].index =
                { typeI: 1, tokenI: 1 };
              data.setupSafeParams.azoriusGovernanceParams.proposerAdapterParams.proposerAdapterERC20V1Params[0].token =
                ethers.ZeroAddress;

              await expect(deploySafeWithSetup(data)).to.be.reverted;
            });
          });

          describe('Multiple new VotesERC20Lockable tokens', () => {
            it('deploys a ProposerAdapterERC20V1 pointing to one of the new tokens', async () => {
              proposerAdapterERC20V1Params1 = {
                ...proposerAdapterERC20V1Params1,
                token: ethers.ZeroAddress,
                index: { typeI: 1, tokenI: 1 },
              };

              const setupSafeParams = createSetupSafeParams({
                votesERC20Params: {
                  votesERC20V1Params: [],
                  votesERC20LockableV1Params: [
                    votesERC20LockableV1Params1,
                    votesERC20LockableV1Params2,
                  ],
                },
                azoriusGovernanceParams: {
                  votingAdapterParams: {
                    votingAdapterERC20V1Params: [votingAdapterERC20V1Params1],
                    votingAdapterERC721V1Params: [],
                  },
                  proposerAdapterParams: {
                    proposerAdapterERC20V1Params: [proposerAdapterERC20V1Params1],
                    proposerAdapterERC721V1Params: [],
                    proposerAdapterHatsV1Params: [],
                  },
                  strategyV1Params,
                  moduleAzoriusV1Params,
                },
              });

              const { safeAddress, receipt } = await deploySafeWithSetup({
                fixtureData,
                owners,
                threshold,
                setupSafeParams,
              });

              await findAndVerifySafe({
                fixtureData,
                receipt,
                safeAddress,
                owners,
                threshold,
                votesERC20Datas: [[], [votesERC20LockableV1Params1, votesERC20LockableV1Params2]],
                proposerAdapterERC20V1Datas: [{ params: proposerAdapterERC20V1Params1 }],
                strategyV1Params,
                moduleAzoriusV1Params,
                votingAdapterERC20V1Datas: [
                  { params: votingAdapterERC20V1Params1, token: randomVotesERC20Contract },
                ],
                numberOfNewContracts: 6,
              });
            });

            it('deploys multiple ProposerAdapterERC20V1s, each pointing to one of the new tokens', async () => {
              proposerAdapterERC20V1Params1 = {
                ...proposerAdapterERC20V1Params1,
                token: ethers.ZeroAddress,
                index: { typeI: 1, tokenI: 1 },
              };

              proposerAdapterERC20V1Params2 = {
                ...proposerAdapterERC20V1Params2,
                token: ethers.ZeroAddress,
                index: { typeI: 1, tokenI: 0 },
              };

              const setupSafeParams = createSetupSafeParams({
                votesERC20Params: {
                  votesERC20V1Params: [],
                  votesERC20LockableV1Params: [
                    votesERC20LockableV1Params1,
                    votesERC20LockableV1Params2,
                  ],
                },
                azoriusGovernanceParams: {
                  votingAdapterParams: {
                    votingAdapterERC20V1Params: [votingAdapterERC20V1Params1],
                    votingAdapterERC721V1Params: [],
                  },
                  proposerAdapterParams: {
                    proposerAdapterERC20V1Params: [
                      proposerAdapterERC20V1Params1,
                      proposerAdapterERC20V1Params2,
                    ],
                    proposerAdapterERC721V1Params: [],
                    proposerAdapterHatsV1Params: [],
                  },
                  strategyV1Params,
                  moduleAzoriusV1Params,
                },
              });

              const { safeAddress, receipt } = await deploySafeWithSetup({
                fixtureData,
                owners,
                threshold,
                setupSafeParams,
              });

              await findAndVerifySafe({
                fixtureData,
                receipt,
                safeAddress,
                owners,
                threshold,
                votesERC20Datas: [[], [votesERC20LockableV1Params1, votesERC20LockableV1Params2]],
                proposerAdapterERC20V1Datas: [
                  { params: proposerAdapterERC20V1Params1 },
                  { params: proposerAdapterERC20V1Params2 },
                ],
                strategyV1Params,
                moduleAzoriusV1Params,
                votingAdapterERC20V1Datas: [
                  { params: votingAdapterERC20V1Params1, token: randomVotesERC20Contract },
                ],
                numberOfNewContracts: 7,
              });
            });
          });

          describe('New VotesERC20 and VotesERC20Lockable tokens', () => {
            it('deploys a ProposerAdapterERC20V1 pointing to one of the new tokens', async () => {
              proposerAdapterERC20V1Params1 = {
                ...proposerAdapterERC20V1Params1,
                token: ethers.ZeroAddress,
                index: { typeI: 1, tokenI: 1 },
              };

              const setupSafeParams = createSetupSafeParams({
                votesERC20Params: {
                  votesERC20V1Params: [votesERC20V1Params1, votesERC20V1Params2],
                  votesERC20LockableV1Params: [
                    votesERC20LockableV1Params1,
                    votesERC20LockableV1Params2,
                  ],
                },
                azoriusGovernanceParams: {
                  votingAdapterParams: {
                    votingAdapterERC20V1Params: [votingAdapterERC20V1Params1],
                    votingAdapterERC721V1Params: [],
                  },
                  proposerAdapterParams: {
                    proposerAdapterERC20V1Params: [proposerAdapterERC20V1Params1],
                    proposerAdapterERC721V1Params: [],
                    proposerAdapterHatsV1Params: [],
                  },
                  strategyV1Params,
                  moduleAzoriusV1Params,
                },
              });

              const { safeAddress, receipt } = await deploySafeWithSetup({
                fixtureData,
                owners,
                threshold,
                setupSafeParams,
              });

              await findAndVerifySafe({
                fixtureData,
                receipt,
                safeAddress,
                owners,
                threshold,
                votesERC20Datas: [
                  [votesERC20V1Params1, votesERC20V1Params2],
                  [votesERC20LockableV1Params1, votesERC20LockableV1Params2],
                ],
                proposerAdapterERC20V1Datas: [{ params: proposerAdapterERC20V1Params1 }],
                strategyV1Params,
                moduleAzoriusV1Params,
                votingAdapterERC20V1Datas: [
                  { params: votingAdapterERC20V1Params1, token: randomVotesERC20Contract },
                ],
                numberOfNewContracts: 8,
              });
            });

            it('deploys multiple ProposerAdapterERC20V1s, each pointing to one of the new tokens', async () => {
              proposerAdapterERC20V1Params1 = {
                ...proposerAdapterERC20V1Params1,
                token: ethers.ZeroAddress,
                index: { typeI: 1, tokenI: 1 },
              };

              proposerAdapterERC20V1Params2 = {
                ...proposerAdapterERC20V1Params2,
                token: ethers.ZeroAddress,
                index: { typeI: 0, tokenI: 0 },
              };

              const setupSafeParams = createSetupSafeParams({
                votesERC20Params: {
                  votesERC20V1Params: [votesERC20V1Params1, votesERC20V1Params2],
                  votesERC20LockableV1Params: [
                    votesERC20LockableV1Params1,
                    votesERC20LockableV1Params2,
                  ],
                },
                azoriusGovernanceParams: {
                  votingAdapterParams: {
                    votingAdapterERC20V1Params: [votingAdapterERC20V1Params1],
                    votingAdapterERC721V1Params: [],
                  },
                  proposerAdapterParams: {
                    proposerAdapterERC20V1Params: [
                      proposerAdapterERC20V1Params1,
                      proposerAdapterERC20V1Params2,
                    ],
                    proposerAdapterERC721V1Params: [],
                    proposerAdapterHatsV1Params: [],
                  },
                  strategyV1Params,
                  moduleAzoriusV1Params,
                },
              });

              const { safeAddress, receipt } = await deploySafeWithSetup({
                fixtureData,
                owners,
                threshold,
                setupSafeParams,
              });

              await findAndVerifySafe({
                fixtureData,
                receipt,
                safeAddress,
                owners,
                threshold,
                votesERC20Datas: [
                  [votesERC20V1Params1, votesERC20V1Params2],
                  [votesERC20LockableV1Params1, votesERC20LockableV1Params2],
                ],
                proposerAdapterERC20V1Datas: [
                  { params: proposerAdapterERC20V1Params1 },
                  { params: proposerAdapterERC20V1Params2 },
                ],
                strategyV1Params,
                moduleAzoriusV1Params,
                votingAdapterERC20V1Datas: [
                  { params: votingAdapterERC20V1Params1, token: randomVotesERC20Contract },
                ],
                numberOfNewContracts: 9,
              });
            });
          });
        });

        describe('ERC721 proposer adapters', () => {
          it('deploys successfully with one ProposerAdapterERC721', async () => {
            const setupSafeParams = createSetupSafeParams({
              azoriusGovernanceParams: {
                votingAdapterParams: {
                  votingAdapterERC20V1Params: [votingAdapterERC20V1Params1],
                  votingAdapterERC721V1Params: [],
                },
                proposerAdapterParams: {
                  proposerAdapterERC20V1Params: [],
                  proposerAdapterERC721V1Params: [proposerAdapterERC721V1Params1],
                  proposerAdapterHatsV1Params: [],
                },
                strategyV1Params,
                moduleAzoriusV1Params,
              },
            });

            const { safeAddress, receipt } = await deploySafeWithSetup({
              fixtureData,
              owners,
              threshold,
              setupSafeParams,
            });

            await findAndVerifySafe({
              fixtureData,
              receipt,
              safeAddress,
              owners,
              threshold,
              proposerAdapterERC721V1Datas: [{ params: proposerAdapterERC721V1Params1 }],
              strategyV1Params,
              moduleAzoriusV1Params,
              votingAdapterERC20V1Datas: [
                { params: votingAdapterERC20V1Params1, token: randomVotesERC20Contract },
              ],
              numberOfNewContracts: 4,
            });
          });

          it('deploys successfully with multiple ProposerAdapterERC721s', async () => {
            const setupSafeParams = createSetupSafeParams({
              azoriusGovernanceParams: {
                votingAdapterParams: {
                  votingAdapterERC20V1Params: [votingAdapterERC20V1Params1],
                  votingAdapterERC721V1Params: [],
                },
                proposerAdapterParams: {
                  proposerAdapterERC20V1Params: [],
                  proposerAdapterERC721V1Params: [
                    proposerAdapterERC721V1Params1,
                    proposerAdapterERC721V1Params2,
                  ],
                  proposerAdapterHatsV1Params: [],
                },
                strategyV1Params,
                moduleAzoriusV1Params,
              },
            });

            const { safeAddress, receipt } = await deploySafeWithSetup({
              fixtureData,
              owners,
              threshold,
              setupSafeParams,
            });

            await findAndVerifySafe({
              fixtureData,
              receipt,
              safeAddress,
              owners,
              threshold,
              proposerAdapterERC721V1Datas: [
                { params: proposerAdapterERC721V1Params1 },
                { params: proposerAdapterERC721V1Params2 },
              ],
              strategyV1Params,
              moduleAzoriusV1Params,
              votingAdapterERC20V1Datas: [
                { params: votingAdapterERC20V1Params1, token: randomVotesERC20Contract },
              ],
              numberOfNewContracts: 5,
            });
          });
        });

        describe('Hats proposer adapters', () => {
          it('deploys successfully with one ProposerAdapterHats', async () => {
            const setupSafeParams = createSetupSafeParams({
              azoriusGovernanceParams: {
                votingAdapterParams: {
                  votingAdapterERC20V1Params: [votingAdapterERC20V1Params1],
                  votingAdapterERC721V1Params: [],
                },
                proposerAdapterParams: {
                  proposerAdapterERC20V1Params: [],
                  proposerAdapterERC721V1Params: [],
                  proposerAdapterHatsV1Params: [proposerAdapterHatsV1Params1],
                },
                strategyV1Params,
                moduleAzoriusV1Params,
              },
            });

            const { safeAddress, receipt } = await deploySafeWithSetup({
              fixtureData,
              owners,
              threshold,
              setupSafeParams,
            });

            await findAndVerifySafe({
              fixtureData,
              receipt,
              safeAddress,
              owners,
              threshold,
              proposerAdapterHatsV1Datas: [{ params: proposerAdapterHatsV1Params1 }],
              strategyV1Params,
              moduleAzoriusV1Params,
              votingAdapterERC20V1Datas: [
                { params: votingAdapterERC20V1Params1, token: randomVotesERC20Contract },
              ],
              numberOfNewContracts: 4,
            });
          });

          it('deploys successfully with multiple ProposerAdapterHats', async () => {
            const setupSafeParams = createSetupSafeParams({
              azoriusGovernanceParams: {
                votingAdapterParams: {
                  votingAdapterERC20V1Params: [votingAdapterERC20V1Params1],
                  votingAdapterERC721V1Params: [],
                },
                proposerAdapterParams: {
                  proposerAdapterERC20V1Params: [],
                  proposerAdapterERC721V1Params: [],
                  proposerAdapterHatsV1Params: [
                    proposerAdapterHatsV1Params1,
                    proposerAdapterHatsV1Params2,
                  ],
                },
                strategyV1Params,
                moduleAzoriusV1Params,
              },
            });

            const { safeAddress, receipt } = await deploySafeWithSetup({
              fixtureData,
              owners,
              threshold,
              setupSafeParams,
            });

            await findAndVerifySafe({
              fixtureData,
              receipt,
              safeAddress,
              owners,
              threshold,
              proposerAdapterHatsV1Datas: [
                { params: proposerAdapterHatsV1Params1 },
                { params: proposerAdapterHatsV1Params2 },
              ],
              strategyV1Params,
              moduleAzoriusV1Params,
              votingAdapterERC20V1Datas: [
                { params: votingAdapterERC20V1Params1, token: randomVotesERC20Contract },
              ],
              numberOfNewContracts: 5,
            });
          });
        });

        describe('Mixed proposer adapters', () => {
          it('deploys successfully with multiple proposer adapters', async () => {
            const setupSafeParams = createSetupSafeParams({
              azoriusGovernanceParams: {
                votingAdapterParams: {
                  votingAdapterERC20V1Params: [votingAdapterERC20V1Params1],
                  votingAdapterERC721V1Params: [],
                },
                proposerAdapterParams: {
                  proposerAdapterERC20V1Params: [proposerAdapterERC20V1Params1],
                  proposerAdapterERC721V1Params: [proposerAdapterERC721V1Params1],
                  proposerAdapterHatsV1Params: [proposerAdapterHatsV1Params1],
                },
                strategyV1Params,
                moduleAzoriusV1Params,
              },
            });

            const { safeAddress, receipt } = await deploySafeWithSetup({
              fixtureData,
              owners,
              threshold,
              setupSafeParams,
            });

            await findAndVerifySafe({
              fixtureData,
              receipt,
              safeAddress,
              owners,
              threshold,
              proposerAdapterERC20V1Datas: [
                {
                  params: proposerAdapterERC20V1Params1,
                  token: randomVotesERC20Contract,
                },
              ],
              proposerAdapterERC721V1Datas: [{ params: proposerAdapterERC721V1Params1 }],
              proposerAdapterHatsV1Datas: [{ params: proposerAdapterHatsV1Params1 }],
              strategyV1Params,
              moduleAzoriusV1Params,
              votingAdapterERC20V1Datas: [
                { params: votingAdapterERC20V1Params1, token: randomVotesERC20Contract },
              ],
              numberOfNewContracts: 6,
            });
          });
        });
      });

      describe('with Fractal Module', () => {
        it('deploys with a Fractal Module', async () => {
          const setupSafeParams = createSetupSafeParams({
            azoriusGovernanceParams: {
              proposerAdapterParams: {
                proposerAdapterERC20V1Params: [{ ...proposerAdapterERC20V1Params1 }],
                proposerAdapterERC721V1Params: [],
                proposerAdapterHatsV1Params: [],
              },
              votingAdapterParams: {
                votingAdapterERC20V1Params: [{ ...votingAdapterERC20V1Params1 }],
                votingAdapterERC721V1Params: [],
              },
              strategyV1Params,
              moduleAzoriusV1Params,
            },
            moduleFractalParams: moduleFractalV1Params,
          });

          const { safeAddress, receipt } = await deploySafeWithSetup({
            fixtureData,
            owners,
            threshold,
            setupSafeParams,
          });

          await findAndVerifySafe({
            fixtureData,
            receipt,
            safeAddress,
            owners,
            threshold,
            moduleFractalV1Params,
            proposerAdapterERC20V1Datas: [
              {
                params: proposerAdapterERC20V1Params1,
                token: randomVotesERC20Contract,
              },
            ],
            strategyV1Params,
            moduleAzoriusV1Params,
            votingAdapterERC20V1Datas: [
              {
                params: votingAdapterERC20V1Params1,
                token: randomVotesERC20Contract,
              },
            ],
            numberOfNewContracts: 5,
          });
        });
      });

      describe('with FreezeGuards', () => {
        describe('FreezeGuardMultisig configurations', () => {
          it('deploys with a FreezeGuardMultisig with FreezeVotingMultisig', async () => {
            const setupSafeParams = createSetupSafeParams({
              azoriusGovernanceParams: {
                proposerAdapterParams: {
                  proposerAdapterERC20V1Params: [{ ...proposerAdapterERC20V1Params1 }],
                  proposerAdapterERC721V1Params: [],
                  proposerAdapterHatsV1Params: [],
                },
                strategyV1Params,
                votingAdapterParams: {
                  votingAdapterERC20V1Params: [{ ...votingAdapterERC20V1Params1 }],
                  votingAdapterERC721V1Params: [],
                },
                moduleAzoriusV1Params,
              },
              freezeVotingMultisigParams,
              freezeGuardMultisigParams,
            });

            const { safeAddress, receipt } = await deploySafeWithSetup({
              fixtureData,
              owners,
              threshold,
              setupSafeParams,
            });

            await findAndVerifySafe({
              fixtureData,
              receipt,
              safeAddress,
              owners,
              threshold,
              proposerAdapterERC20V1Datas: [
                {
                  params: proposerAdapterERC20V1Params1,
                  token: randomVotesERC20Contract,
                },
              ],
              strategyV1Params,
              moduleAzoriusV1Params,
              votingAdapterERC20V1Datas: [
                {
                  params: votingAdapterERC20V1Params1,
                  token: randomVotesERC20Contract,
                },
              ],
              freezeGuardMultisigV1Data: {
                guardParams: freezeGuardMultisigParams,
                votingMultisigParams: freezeVotingMultisigParams,
              },
              numberOfNewContracts: 6,
            });
          });

          it('deploys with a FreezeGuardMultisig with FreezeVotingAzorius', async () => {
            const setupSafeParams = createSetupSafeParams({
              azoriusGovernanceParams: {
                proposerAdapterParams: {
                  proposerAdapterERC20V1Params: [{ ...proposerAdapterERC20V1Params1 }],
                  proposerAdapterERC721V1Params: [],
                  proposerAdapterHatsV1Params: [],
                },
                strategyV1Params,
                votingAdapterParams: {
                  votingAdapterERC20V1Params: [{ ...votingAdapterERC20V1Params1 }],
                  votingAdapterERC721V1Params: [],
                },
                moduleAzoriusV1Params,
              },
              freezeVotingAzoriusParams,
              freezeGuardMultisigParams,
            });

            const { safeAddress, receipt } = await deploySafeWithSetup({
              fixtureData,
              owners,
              threshold,
              setupSafeParams,
            });

            await findAndVerifySafe({
              fixtureData,
              receipt,
              safeAddress,
              owners,
              threshold,
              proposerAdapterERC20V1Datas: [
                {
                  params: proposerAdapterERC20V1Params1,
                  token: randomVotesERC20Contract,
                },
              ],
              strategyV1Params,
              moduleAzoriusV1Params,
              votingAdapterERC20V1Datas: [
                {
                  params: votingAdapterERC20V1Params1,
                  token: randomVotesERC20Contract,
                },
              ],
              freezeGuardMultisigV1Data: {
                guardParams: freezeGuardMultisigParams,
                votingAzoriusParams: freezeVotingAzoriusParams,
              },
              numberOfNewContracts: 6,
            });
          });

          it('reverts if we deploy a FreezeGuardMultisig and NEITHER FreezeVoting contracts', async () => {
            const setupSafeParams = createSetupSafeParams({
              azoriusGovernanceParams: {
                proposerAdapterParams: {
                  proposerAdapterERC20V1Params: [{ ...proposerAdapterERC20V1Params1 }],
                  proposerAdapterERC721V1Params: [],
                  proposerAdapterHatsV1Params: [],
                },
                strategyV1Params,
                votingAdapterParams: {
                  votingAdapterERC20V1Params: [{ ...votingAdapterERC20V1Params1 }],
                  votingAdapterERC721V1Params: [],
                },
                moduleAzoriusV1Params,
              },
              freezeVotingAzoriusParams,
              freezeGuardMultisigParams,
            });

            const data = {
              fixtureData,
              owners,
              threshold,
              setupSafeParams,
            };

            // initial deployment should succeed
            await deploySafeWithSetup(data);

            // delete the freezeVotingAzoriusParams by setting the implementation to zero address
            data.setupSafeParams.freezeParams.freezeVotingParams.freezeVotingAzoriusV1Params.implementation =
              ethers.ZeroAddress;

            // now deploying should fail
            await expect(deploySafeWithSetup(data)).to.be.reverted;
          });

          it('reverts if we deploy a FreezeGuardMultisig and BOTH FreezeVoting contracts', async () => {
            const setupSafeParams = createSetupSafeParams({
              azoriusGovernanceParams: {
                proposerAdapterParams: {
                  proposerAdapterERC20V1Params: [{ ...proposerAdapterERC20V1Params1 }],
                  proposerAdapterERC721V1Params: [],
                  proposerAdapterHatsV1Params: [],
                },
                strategyV1Params,
                votingAdapterParams: {
                  votingAdapterERC20V1Params: [{ ...votingAdapterERC20V1Params1 }],
                  votingAdapterERC721V1Params: [],
                },
                moduleAzoriusV1Params,
              },
              freezeVotingAzoriusParams,
              freezeGuardMultisigParams,
            });

            const data = {
              fixtureData,
              owners,
              threshold,
              setupSafeParams,
            };

            // initial deployment should succeed
            await deploySafeWithSetup(data);

            // now add the freezeVotingMultisigParams
            data.setupSafeParams.freezeParams.freezeVotingParams.freezeVotingMultisigV1Params =
              freezeVotingMultisigParams;

            // now deploying should fail
            await expect(deploySafeWithSetup(data)).to.be.reverted;
          });
        });

        describe('FreezeGuardAzorius configurations', () => {
          it('deploys with a FreezeGuardAzorius with FreezeVotingMultisig', async () => {
            const setupSafeParams = createSetupSafeParams({
              azoriusGovernanceParams: {
                proposerAdapterParams: {
                  proposerAdapterERC20V1Params: [{ ...proposerAdapterERC20V1Params1 }],
                  proposerAdapterERC721V1Params: [],
                  proposerAdapterHatsV1Params: [],
                },
                strategyV1Params,
                votingAdapterParams: {
                  votingAdapterERC20V1Params: [{ ...votingAdapterERC20V1Params1 }],
                  votingAdapterERC721V1Params: [],
                },
                moduleAzoriusV1Params,
              },
              freezeVotingMultisigParams,
              freezeGuardAzoriusParams,
            });

            const { safeAddress, receipt } = await deploySafeWithSetup({
              fixtureData,
              owners,
              threshold,
              setupSafeParams,
            });

            await findAndVerifySafe({
              fixtureData,
              receipt,
              safeAddress,
              owners,
              threshold,
              proposerAdapterERC20V1Datas: [
                {
                  params: proposerAdapterERC20V1Params1,
                  token: randomVotesERC20Contract,
                },
              ],
              strategyV1Params,
              moduleAzoriusV1Params,
              votingAdapterERC20V1Datas: [
                {
                  params: votingAdapterERC20V1Params1,
                  token: randomVotesERC20Contract,
                },
              ],
              freezeGuardAzoriusV1Data: {
                guardParams: freezeGuardAzoriusParams,
                votingMultisigParams: freezeVotingMultisigParams,
              },
              numberOfNewContracts: 6,
            });
          });

          it('deploys with a FreezeGuardAzorius with FreezeVotingAzorius', async () => {
            const setupSafeParams = createSetupSafeParams({
              azoriusGovernanceParams: {
                proposerAdapterParams: {
                  proposerAdapterERC20V1Params: [{ ...proposerAdapterERC20V1Params1 }],
                  proposerAdapterERC721V1Params: [],
                  proposerAdapterHatsV1Params: [],
                },
                strategyV1Params,
                votingAdapterParams: {
                  votingAdapterERC20V1Params: [{ ...votingAdapterERC20V1Params1 }],
                  votingAdapterERC721V1Params: [],
                },
                moduleAzoriusV1Params,
              },
              freezeVotingAzoriusParams,
              freezeGuardAzoriusParams,
            });

            const { safeAddress, receipt } = await deploySafeWithSetup({
              fixtureData,
              owners,
              threshold,
              setupSafeParams,
            });

            await findAndVerifySafe({
              fixtureData,
              receipt,
              safeAddress,
              owners,
              threshold,
              proposerAdapterERC20V1Datas: [
                {
                  params: proposerAdapterERC20V1Params1,
                  token: randomVotesERC20Contract,
                },
              ],
              strategyV1Params,
              moduleAzoriusV1Params,
              votingAdapterERC20V1Datas: [
                {
                  params: votingAdapterERC20V1Params1,
                  token: randomVotesERC20Contract,
                },
              ],
              freezeGuardAzoriusV1Data: {
                guardParams: freezeGuardAzoriusParams,
                votingAzoriusParams: freezeVotingAzoriusParams,
              },
              numberOfNewContracts: 6,
            });
          });

          it('reverts if we deploy a FreezeGuardAzorius and NEITHER FreezeVoting contract', async () => {
            const setupSafeParams = createSetupSafeParams({
              azoriusGovernanceParams: {
                proposerAdapterParams: {
                  proposerAdapterERC20V1Params: [{ ...proposerAdapterERC20V1Params1 }],
                  proposerAdapterERC721V1Params: [],
                  proposerAdapterHatsV1Params: [],
                },
                strategyV1Params,
                votingAdapterParams: {
                  votingAdapterERC20V1Params: [{ ...votingAdapterERC20V1Params1 }],
                  votingAdapterERC721V1Params: [],
                },
                moduleAzoriusV1Params,
              },
              freezeVotingAzoriusParams,
              freezeGuardAzoriusParams,
            });

            const data = {
              fixtureData,
              owners,
              threshold,
              setupSafeParams,
            };

            // initial deployment should succeed
            await deploySafeWithSetup(data);

            // now delete the freezeVotingAzoriusParams by setting the implementation to zero address
            data.setupSafeParams.freezeParams.freezeVotingParams.freezeVotingAzoriusV1Params.implementation =
              ethers.ZeroAddress;

            // now deploying should fail
            await expect(deploySafeWithSetup(data)).to.be.reverted;
          });

          it('reverts if we deploy a FreezeGuardAzorius and BOTH FreezeVoting contracts', async () => {
            const setupSafeParams = createSetupSafeParams({
              azoriusGovernanceParams: {
                proposerAdapterParams: {
                  proposerAdapterERC20V1Params: [{ ...proposerAdapterERC20V1Params1 }],
                  proposerAdapterERC721V1Params: [],
                  proposerAdapterHatsV1Params: [],
                },
                strategyV1Params,
                votingAdapterParams: {
                  votingAdapterERC20V1Params: [{ ...votingAdapterERC20V1Params1 }],
                  votingAdapterERC721V1Params: [],
                },
                moduleAzoriusV1Params,
              },
              freezeVotingAzoriusParams,
              freezeGuardAzoriusParams,
            });

            const data = {
              fixtureData,
              owners,
              threshold,
              setupSafeParams,
            };

            // initial deployment should succeed
            await deploySafeWithSetup(data);

            // now add the freezeVotingMultisigParams
            data.setupSafeParams.freezeParams.freezeVotingParams.freezeVotingMultisigV1Params =
              freezeVotingMultisigParams;

            // now deploying should fail
            await expect(deploySafeWithSetup(data)).to.be.reverted;
          });
        });

        describe('Both FreezeGuard contracts', () => {
          it('deploys with both FreezeGuards using FreezeVotingAzorius', async () => {
            const setupSafeParams = createSetupSafeParams({
              azoriusGovernanceParams: {
                proposerAdapterParams: {
                  proposerAdapterERC20V1Params: [{ ...proposerAdapterERC20V1Params1 }],
                  proposerAdapterERC721V1Params: [],
                  proposerAdapterHatsV1Params: [],
                },
                strategyV1Params,
                votingAdapterParams: {
                  votingAdapterERC20V1Params: [{ ...votingAdapterERC20V1Params1 }],
                  votingAdapterERC721V1Params: [],
                },
                moduleAzoriusV1Params,
              },
              freezeVotingAzoriusParams,
              freezeGuardMultisigParams,
              freezeGuardAzoriusParams,
            });

            const { safeAddress, receipt } = await deploySafeWithSetup({
              fixtureData,
              owners,
              threshold,
              setupSafeParams,
            });

            await findAndVerifySafe({
              fixtureData,
              receipt,
              safeAddress,
              owners,
              threshold,
              proposerAdapterERC20V1Datas: [
                {
                  params: proposerAdapterERC20V1Params1,
                  token: randomVotesERC20Contract,
                },
              ],
              strategyV1Params,
              moduleAzoriusV1Params,
              votingAdapterERC20V1Datas: [
                {
                  params: votingAdapterERC20V1Params1,
                  token: randomVotesERC20Contract,
                },
              ],
              freezeGuardMultisigV1Data: {
                guardParams: freezeGuardMultisigParams,
                votingAzoriusParams: freezeVotingAzoriusParams,
              },
              freezeGuardAzoriusV1Data: {
                guardParams: freezeGuardAzoriusParams,
                votingAzoriusParams: freezeVotingAzoriusParams,
              },
              numberOfNewContracts: 7,
            });
          });

          it('deploys with both FreezeGuards using FreezeVotingMultisig', async () => {
            const setupSafeParams = createSetupSafeParams({
              azoriusGovernanceParams: {
                proposerAdapterParams: {
                  proposerAdapterERC20V1Params: [{ ...proposerAdapterERC20V1Params1 }],
                  proposerAdapterERC721V1Params: [],
                  proposerAdapterHatsV1Params: [],
                },
                strategyV1Params,
                votingAdapterParams: {
                  votingAdapterERC20V1Params: [{ ...votingAdapterERC20V1Params1 }],
                  votingAdapterERC721V1Params: [],
                },
                moduleAzoriusV1Params,
              },
              freezeVotingMultisigParams,
              freezeGuardMultisigParams,
              freezeGuardAzoriusParams,
            });

            const { safeAddress, receipt } = await deploySafeWithSetup({
              fixtureData,
              owners,
              threshold,
              setupSafeParams,
            });

            await findAndVerifySafe({
              fixtureData,
              receipt,
              safeAddress,
              owners,
              threshold,
              proposerAdapterERC20V1Datas: [
                {
                  params: proposerAdapterERC20V1Params1,
                  token: randomVotesERC20Contract,
                },
              ],
              strategyV1Params,
              moduleAzoriusV1Params,
              votingAdapterERC20V1Datas: [
                {
                  params: votingAdapterERC20V1Params1,
                  token: randomVotesERC20Contract,
                },
              ],
              freezeGuardMultisigV1Data: {
                guardParams: freezeGuardMultisigParams,
                votingMultisigParams: freezeVotingMultisigParams,
              },
              freezeGuardAzoriusV1Data: {
                guardParams: freezeGuardAzoriusParams,
                votingMultisigParams: freezeVotingMultisigParams,
              },
              numberOfNewContracts: 7,
            });
          });

          it('reverts if we deploy both FreezeGuards and NEITHER FreezeVoting contract', async () => {
            const setupSafeParams = createSetupSafeParams({
              azoriusGovernanceParams: {
                proposerAdapterParams: {
                  proposerAdapterERC20V1Params: [{ ...proposerAdapterERC20V1Params1 }],
                  proposerAdapterERC721V1Params: [],
                  proposerAdapterHatsV1Params: [],
                },
                strategyV1Params,
                votingAdapterParams: {
                  votingAdapterERC20V1Params: [{ ...votingAdapterERC20V1Params1 }],
                  votingAdapterERC721V1Params: [],
                },
                moduleAzoriusV1Params,
              },
              freezeVotingAzoriusParams,
              freezeGuardAzoriusParams,
              freezeGuardMultisigParams,
            });

            const data = {
              fixtureData,
              owners,
              threshold,
              setupSafeParams,
            };

            // initial deployment should succeed
            await deploySafeWithSetup(data);

            // now delete the freezeVotingAzoriusParams by setting the implementation to zero address
            data.setupSafeParams.freezeParams.freezeVotingParams.freezeVotingAzoriusV1Params.implementation =
              ethers.ZeroAddress;

            // now deploying should fail
            await expect(deploySafeWithSetup(data)).to.be.reverted;
          });

          it('reverts if we deploy both FreezeGuards and BOTH FreezeVoting contracts', async () => {
            const setupSafeParams = createSetupSafeParams({
              azoriusGovernanceParams: {
                proposerAdapterParams: {
                  proposerAdapterERC20V1Params: [{ ...proposerAdapterERC20V1Params1 }],
                  proposerAdapterERC721V1Params: [],
                  proposerAdapterHatsV1Params: [],
                },
                strategyV1Params,
                votingAdapterParams: {
                  votingAdapterERC20V1Params: [{ ...votingAdapterERC20V1Params1 }],
                  votingAdapterERC721V1Params: [],
                },
                moduleAzoriusV1Params,
              },
              freezeVotingAzoriusParams,
              freezeGuardAzoriusParams,
              freezeGuardMultisigParams,
            });

            const data = {
              fixtureData,
              owners,
              threshold,
              setupSafeParams,
            };

            // initial deployment should succeed
            await deploySafeWithSetup(data);

            // now add the freezeVotingMultisigParams
            data.setupSafeParams.freezeParams.freezeVotingParams.freezeVotingMultisigV1Params =
              freezeVotingMultisigParams;

            // now deploying should fail
            await expect(deploySafeWithSetup(data)).to.be.reverted;
          });
        });
      });
    });
  });
});
