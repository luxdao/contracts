import hre from 'hardhat';
import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

function formatEther(wei: bigint): string {
  return (Number(wei) / 1e18).toFixed(4);
}

/**
 * Deploy all DAO master copy contracts to the current network
 * Usage: npx hardhat run scripts/deploy-all.ts --network localhost
 */

interface DeployedAddresses {
  network: string;
  chainId: number;
  timestamp: string;
  deployer: string;
  contracts: {
    // Safe contracts
    gnosisSafeL2Singleton: string;
    gnosisSafeProxyFactory: string;
    compatibilityFallbackHandler: string;
    multiSendCallOnly: string;

    // Module Factory
    moduleProxyFactory: string;

    // Governor/Voting
    moduleGovernorMasterCopy: string;
    moduleFractalMasterCopy: string;
    strategyMasterCopy: string;

    // Voting strategies
    linearVotingErc20MasterCopy: string;
    linearVotingErc20RolesWhitelistingMasterCopy: string;
    linearVotingErc721MasterCopy: string;
    linearVotingErc721RolesWhitelistingMasterCopy: string;
    linearVotingErc20V1MasterCopy: string;
    linearVotingErc20RolesWhitelistingV1MasterCopy: string;
    linearVotingErc721V1MasterCopy: string;
    linearVotingErc721RolesWhitelistingV1MasterCopy: string;

    // Freeze
    freezeGuardGovernorMasterCopy: string;
    freezeGuardMultisigMasterCopy: string;
    freezeVotingErc20MasterCopy: string;
    freezeVotingErc721MasterCopy: string;
    freezeVotingMultisigMasterCopy: string;

    // Tokens
    votesErc20MasterCopy: string;
    votesErc20LockableMasterCopy: string;
    votesErc20StakedMasterCopy: string;
    claimErc20MasterCopy: string;

    // Autonomous admin
    daoAutonomousAdminV1MasterCopy: string;

    // Key-value pairs
    keyValuePairs: string;
  };
}

async function main() {
  const connection = await hre.network.connect();
  const chainId = await connection.provider.request({ method: 'eth_chainId', params: [] });
  const accounts = await connection.provider.request({ method: 'eth_accounts', params: [] }) as string[];

  if (!accounts || accounts.length === 0) {
    throw new Error('No accounts available');
  }

  const deployer = accounts[0];
  const balance = await connection.provider.request({
    method: 'eth_getBalance',
    params: [deployer, 'latest']
  }) as string;

  console.log('Deploying contracts with account:', deployer);
  console.log('Network:', connection.networkName, 'Chain ID:', parseInt(chainId as string, 16));
  console.log('Balance:', formatEther(BigInt(balance)), 'ETH');
  console.log('');

  const addresses: Partial<DeployedAddresses['contracts']> = {};

  // Helper function to deploy and log
  async function deploy(name: string, contractName: string): Promise<string> {
    console.log(`Deploying ${name}...`);

    const artifact = await hre.artifacts.readArtifact(contractName);

    const txHash = await connection.provider.request({
      method: 'eth_sendTransaction',
      params: [{
        from: deployer,
        data: artifact.bytecode,
        gas: '0x' + (5000000).toString(16),
      }]
    }) as string;

    // Wait for the transaction to be mined
    let receipt = null;
    while (!receipt) {
      await new Promise(resolve => setTimeout(resolve, 100));
      receipt = await connection.provider.request({
        method: 'eth_getTransactionReceipt',
        params: [txHash]
      });
    }

    const address = (receipt as any).contractAddress;
    console.log(`  ${name}: ${address}`);
    return address;
  }

  // Deploy Safe contracts (mocks for local testing)
  console.log('\n=== Deploying Safe Contracts ===');

  addresses.gnosisSafeL2Singleton = await deploy('GnosisSafeL2Singleton', 'SafeL2');
  addresses.gnosisSafeProxyFactory = await deploy('SafeProxyFactory', 'SafeProxyFactory');
  addresses.compatibilityFallbackHandler = await deploy('CompatibilityFallbackHandler', 'CompatibilityFallbackHandler');
  addresses.multiSendCallOnly = await deploy('MultiSendCallOnly', 'MultiSendCallOnly');

  // Deploy Module Proxy Factory
  console.log('\n=== Deploying Module Factory ===');
  addresses.moduleProxyFactory = await deploy('ModuleProxyFactory', 'contracts/mocks/MockSystemDeployer.sol:MockSystemDeployer');

  // Deploy Governor contracts
  console.log('\n=== Deploying Governor Contracts ===');

  addresses.moduleGovernorMasterCopy = await deploy('ModuleGovernorV1', 'ModuleGovernorV1');
  addresses.moduleFractalMasterCopy = await deploy('ModuleFractalV1', 'ModuleFractalV1');
  addresses.strategyMasterCopy = await deploy('StrategyV1', 'StrategyV1');

  // Deploy Voting Strategy contracts
  console.log('\n=== Deploying Voting Strategies ===');

  addresses.linearVotingErc20MasterCopy = await deploy('VotingWeightERC20V1', 'VotingWeightERC20V1');
  addresses.linearVotingErc20V1MasterCopy = addresses.linearVotingErc20MasterCopy;

  addresses.linearVotingErc721MasterCopy = await deploy('VotingWeightERC721V1', 'VotingWeightERC721V1');
  addresses.linearVotingErc721V1MasterCopy = addresses.linearVotingErc721MasterCopy;

  // Roles whitelisting versions (using same contracts for now)
  addresses.linearVotingErc20RolesWhitelistingMasterCopy = addresses.linearVotingErc20MasterCopy;
  addresses.linearVotingErc721RolesWhitelistingMasterCopy = addresses.linearVotingErc721MasterCopy;
  addresses.linearVotingErc20RolesWhitelistingV1MasterCopy = addresses.linearVotingErc20MasterCopy;
  addresses.linearVotingErc721RolesWhitelistingV1MasterCopy = addresses.linearVotingErc721MasterCopy;

  // Deploy Freeze contracts
  console.log('\n=== Deploying Freeze Contracts ===');

  addresses.freezeGuardGovernorMasterCopy = await deploy('FreezeGuardGovernorV1', 'FreezeGuardGovernorV1');
  addresses.freezeGuardMultisigMasterCopy = await deploy('FreezeGuardMultisigV1', 'FreezeGuardMultisigV1');
  addresses.freezeVotingErc20MasterCopy = await deploy('FreezeVotingGovernorV1', 'FreezeVotingGovernorV1');
  addresses.freezeVotingErc721MasterCopy = addresses.freezeVotingErc20MasterCopy;
  addresses.freezeVotingMultisigMasterCopy = await deploy('FreezeVotingMultisigV1', 'FreezeVotingMultisigV1');

  // Deploy Token contracts
  console.log('\n=== Deploying Token Contracts ===');

  addresses.votesErc20MasterCopy = await deploy('VotesERC20V1', 'VotesERC20V1');
  addresses.votesErc20LockableMasterCopy = addresses.votesErc20MasterCopy; // Same contract, different init
  addresses.votesErc20StakedMasterCopy = await deploy('VotesERC20StakedV1', 'VotesERC20StakedV1');

  // Deploy Autonomous Admin
  console.log('\n=== Deploying Autonomous Admin ===');

  addresses.daoAutonomousAdminV1MasterCopy = await deploy('AutonomousAdminV1', 'AutonomousAdminV1');

  // Deploy Key-Value Pairs
  console.log('\n=== Deploying Utility Contracts ===');

  addresses.keyValuePairs = await deploy('KeyValuePairsV1', 'KeyValuePairsV1');

  // Deploy Claim contract
  addresses.claimErc20MasterCopy = await deploy('PublicSaleV1 (Claim)', 'PublicSaleV1');

  // Save deployed addresses
  const deploymentInfo: DeployedAddresses = {
    network: connection.networkName,
    chainId: parseInt(chainId as string, 16),
    timestamp: new Date().toISOString(),
    deployer: deployer,
    contracts: addresses as DeployedAddresses['contracts'],
  };

  const outputDir = path.join(__dirname, '../deployments');
  fs.mkdirSync(outputDir, { recursive: true });

  const outputPath = path.join(outputDir, `${connection.networkName}.json`);
  fs.writeFileSync(outputPath, JSON.stringify(deploymentInfo, null, 2));

  console.log('\n=== Deployment Complete ===');
  console.log(`Addresses saved to: ${outputPath}`);
  console.log('\nAll deployed addresses:');
  console.log(JSON.stringify(addresses, null, 2));

  await connection.close();
  return deploymentInfo;
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
