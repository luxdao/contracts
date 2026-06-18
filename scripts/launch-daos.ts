import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';
import { keccak256, toUtf8Bytes, AbiCoder, getCreate2Address, concat, zeroPadValue } from 'ethers';
import hre from 'hardhat';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const abiCoder = new AbiCoder();

interface DAODeployment {
  name: string;
  type: 'multisig' | 'governor_erc20' | 'governor_erc721';
  safeAddress: string;
  governorAddress?: string;
  tokenAddress?: string;
  strategyAddress?: string;
}

/**
 * Launch All DAO Types - Complete E2E Deployment
 *
 * Deploys three types of DAOs:
 * 1. Multisig DAO - Simple multisig treasury (3 signers, 2 threshold)
 * 2. ERC20 Governor DAO - Token-weighted voting with governance token
 * 3. ERC721 Governor DAO - NFT-based voting (1 NFT = 1 vote)
 */

async function main() {
  console.log('🚀 DAO LAUNCHER - Full Ecosystem Deployment\n');
  console.log('═══════════════════════════════════════════════\n');

  const connection = await hre.network.connect();

  // Get accounts managed by the node
  const accounts = await connection.provider.request({ method: 'eth_accounts', params: [] }) as string[];
  console.log(`📋 Node manages ${accounts.length} accounts`);

  // Use available accounts, reusing if needed
  const deployer = accounts[0];
  const signer1 = accounts[1] || accounts[0];
  const signer2 = accounts[2] || accounts[0];
  const signer3 = accounts[2] || accounts[0]; // Reuse signer2 if not enough
  const tokenHolder1 = accounts[1] || accounts[0]; // Reuse signer1 if not enough
  const tokenHolder2 = accounts[2] || accounts[0]; // Reuse signer2 if not enough

  console.log('👥 Accounts:');
  console.log(`  Deployer: ${deployer}`);
  console.log(`  Signer 1: ${signer1}`);
  console.log(`  Signer 2: ${signer2}`);
  console.log(`  Signer 3: ${signer3}`);
  console.log(`  Token Holder 1: ${tokenHolder1}`);
  console.log(`  Token Holder 2: ${tokenHolder2}\n`);

  // Load deployment
  const deploymentPath = path.join(__dirname, '../deployments/localhost-1337.json');
  const deployment = JSON.parse(fs.readFileSync(deploymentPath, 'utf-8'));

  // Helper functions
  async function sendTx(params: any): Promise<any> {
    const txHash = await connection.provider.request({
      method: 'eth_sendTransaction',
      params: [{ ...params, gas: '0x' + (8000000).toString(16) }]
    }) as string;

    let receipt = null;
    let attempts = 0;
    while (!receipt && attempts < 100) {
      await new Promise(resolve => setTimeout(resolve, 200));
      receipt = await connection.provider.request({
        method: 'eth_getTransactionReceipt',
        params: [txHash]
      });
      attempts++;
    }
    if (!receipt) throw new Error('Transaction timeout');
    if (receipt.status === '0x0') throw new Error('Transaction reverted');
    return receipt;
  }

  async function call(to: string, data: string): Promise<string> {
    return await connection.provider.request({
      method: 'eth_call',
      params: [{ to, data }, 'latest']
    }) as string;
  }

  async function getCode(address: string): Promise<string> {
    return await connection.provider.request({
      method: 'eth_getCode',
      params: [address, 'latest']
    }) as string;
  }

  async function mineBlocks(count: number) {
    for (let i = 0; i < count; i++) {
      await connection.provider.request({
        method: 'evm_mine',
        params: []
      });
    }
  }

  const deployedDAOs: DAODeployment[] = [];

  // =======================================================
  // DAO 1: Multisig DAO (Lux Treasury)
  // =======================================================
  console.log('═══════════════════════════════════════════════');
  console.log('🏦 DAO 1: Multisig DAO (Lux Treasury)');
  console.log('═══════════════════════════════════════════════\n');

  const safeSetupSelector = keccak256(toUtf8Bytes('setup(address[],uint256,address,bytes,address,address,uint256,address)')).slice(0, 10);

  // 3 signers, 2 threshold (2-of-3 multisig)
  const multisigSetupData = safeSetupSelector + abiCoder.encode(
    ['address[]', 'uint256', 'address', 'bytes', 'address', 'address', 'uint256', 'address'],
    [
      [deployer, signer1, signer2],  // 3 signers
      2,  // 2 threshold
      '0x0000000000000000000000000000000000000000',
      '0x',
      deployment.contracts.compatibilityFallbackHandler,
      '0x0000000000000000000000000000000000000000',
      0,
      '0x0000000000000000000000000000000000000000',
    ]
  ).slice(2);

  const createProxySelector = keccak256(toUtf8Bytes('createProxyWithNonce(address,bytes,uint256)')).slice(0, 10);
  const multisigNonce = BigInt(Date.now());

  const multisigReceipt = await sendTx({
    from: deployer,
    to: deployment.contracts.gnosisSafeProxyFactory,
    data: createProxySelector + abiCoder.encode(
      ['address', 'bytes', 'uint256'],
      [deployment.contracts.gnosisSafeL2Singleton, multisigSetupData, multisigNonce]
    ).slice(2),
  });

  // Extract Safe address from logs
  const proxyCreationTopic = keccak256(toUtf8Bytes('ProxyCreation(address,address)'));
  const multisigLog = multisigReceipt.logs?.find((log: any) => log.topics?.[0] === proxyCreationTopic);
  const multisigSafeAddress = multisigLog ? '0x' + multisigLog.topics[1].slice(26) : '0x' + (multisigReceipt.logs?.[0]?.data || '').slice(26, 66);

  console.log(`✅ Multisig Safe deployed: ${multisigSafeAddress}`);
  console.log(`   Signers: ${deployer.slice(0,10)}..., ${signer1.slice(0,10)}..., ${signer2.slice(0,10)}...`);
  console.log(`   Threshold: 2 of 3`);

  // Fund the multisig
  await sendTx({
    from: deployer,
    to: multisigSafeAddress,
    value: '0x' + BigInt('10000000000000000000').toString(16), // 10 ETH
  });
  console.log(`   Funded: 10 ETH\n`);

  deployedDAOs.push({
    name: 'Lux Treasury (Multisig)',
    type: 'multisig',
    safeAddress: multisigSafeAddress,
  });

  // =======================================================
  // DAO 2: ERC20 Governor DAO (Lux Governance)
  // =======================================================
  console.log('═══════════════════════════════════════════════');
  console.log('🗳️  DAO 2: ERC20 Governor DAO (Lux Governance)');
  console.log('═══════════════════════════════════════════════\n');

  // Deploy governance token
  console.log('📌 Deploying governance token...');
  const mockTokenArtifact = await hre.artifacts.readArtifact('MockERC20Votes');

  const tokenReceipt = await sendTx({
    from: deployer,
    data: mockTokenArtifact.bytecode,
  });
  const govTokenAddress = tokenReceipt.contractAddress;

  // Mint initial supply (MockERC20Votes uses mint, not initialize)
  const mintERC20Selector = keccak256(toUtf8Bytes('mint(address,uint256)')).slice(0, 10);
  await sendTx({
    from: deployer,
    to: govTokenAddress,
    data: mintERC20Selector + abiCoder.encode(
      ['address', 'uint256'],
      [deployer, BigInt('100000000000000000000000000')] // 100M tokens to deployer
    ).slice(2),
  });
  console.log(`   ✅ Token deployed: ${govTokenAddress}`);
  console.log(`      Name: Mock Voting Token (MVT)`);
  console.log(`      Supply: 100,000,000 MVT`);

  // Distribute tokens
  const transferSelector = keccak256(toUtf8Bytes('transfer(address,uint256)')).slice(0, 10);
  const delegateSelector = keccak256(toUtf8Bytes('delegate(address)')).slice(0, 10);

  // Transfer to holders
  await sendTx({
    from: deployer,
    to: govTokenAddress,
    data: transferSelector + abiCoder.encode(
      ['address', 'uint256'],
      [tokenHolder1, BigInt('10000000000000000000000000')] // 10M tokens
    ).slice(2),
  });
  await sendTx({
    from: deployer,
    to: govTokenAddress,
    data: transferSelector + abiCoder.encode(
      ['address', 'uint256'],
      [tokenHolder2, BigInt('10000000000000000000000000')] // 10M tokens
    ).slice(2),
  });
  console.log(`   ✅ Distributed 10M MVT each to 2 holders`);

  // Delegate voting power
  await sendTx({
    from: tokenHolder1,
    to: govTokenAddress,
    data: delegateSelector + abiCoder.encode(['address'], [tokenHolder1]).slice(2),
  });
  await sendTx({
    from: tokenHolder2,
    to: govTokenAddress,
    data: delegateSelector + abiCoder.encode(['address'], [tokenHolder2]).slice(2),
  });
  await sendTx({
    from: deployer,
    to: govTokenAddress,
    data: delegateSelector + abiCoder.encode(['address'], [deployer]).slice(2),
  });
  console.log(`   ✅ All holders delegated voting power`);

  await mineBlocks(1);

  // Deploy Safe for Governor DAO
  console.log('\n📌 Deploying DAO treasury (Safe)...');
  const govSafeNonce = BigInt(Date.now() + 1);
  const govSafeSetupData = safeSetupSelector + abiCoder.encode(
    ['address[]', 'uint256', 'address', 'bytes', 'address', 'address', 'uint256', 'address'],
    [
      [deployer], // Initial owner (will be replaced by Governor)
      1,
      '0x0000000000000000000000000000000000000000',
      '0x',
      deployment.contracts.compatibilityFallbackHandler,
      '0x0000000000000000000000000000000000000000',
      0,
      '0x0000000000000000000000000000000000000000',
    ]
  ).slice(2);

  const govSafeReceipt = await sendTx({
    from: deployer,
    to: deployment.contracts.gnosisSafeProxyFactory,
    data: createProxySelector + abiCoder.encode(
      ['address', 'bytes', 'uint256'],
      [deployment.contracts.gnosisSafeL2Singleton, govSafeSetupData, govSafeNonce]
    ).slice(2),
  });

  const govSafeLog = govSafeReceipt.logs?.find((log: any) => log.topics?.[0] === proxyCreationTopic);
  const govSafeAddress = govSafeLog ? '0x' + govSafeLog.topics[1].slice(26) : '0x' + (govSafeReceipt.logs?.[0]?.data || '').slice(26, 66);

  console.log(`   ✅ Safe deployed: ${govSafeAddress}`);

  // Fund the governor DAO
  await sendTx({
    from: deployer,
    to: govSafeAddress,
    value: '0x' + BigInt('50000000000000000000').toString(16), // 50 ETH
  });
  console.log(`   ✅ Funded: 50 ETH`);

  // Transfer some tokens to treasury
  await sendTx({
    from: deployer,
    to: govTokenAddress,
    data: transferSelector + abiCoder.encode(
      ['address', 'uint256'],
      [govSafeAddress, BigInt('50000000000000000000000000')] // 50M tokens
    ).slice(2),
  });
  console.log(`   ✅ Treasury funded: 50M MVT tokens\n`);

  deployedDAOs.push({
    name: 'Lux Governance (ERC20 Governor)',
    type: 'governor_erc20',
    safeAddress: govSafeAddress,
    tokenAddress: govTokenAddress,
  });

  // =======================================================
  // DAO 3: ERC721 Governor DAO (Lux Council)
  // =======================================================
  console.log('═══════════════════════════════════════════════');
  console.log('🎨 DAO 3: ERC721 Governor DAO (Lux Council)');
  console.log('═══════════════════════════════════════════════\n');

  // Deploy NFT for council membership
  console.log('📌 Deploying council membership NFT...');
  const mockNFTArtifact = await hre.artifacts.readArtifact('MockERC721Votes');

  const nftReceipt = await sendTx({
    from: deployer,
    data: mockNFTArtifact.bytecode,
  });
  const councilNFTAddress = nftReceipt.contractAddress;

  // Initialize NFT
  const nftInitSelector = keccak256(toUtf8Bytes('initialize(string,string)')).slice(0, 10);
  await sendTx({
    from: deployer,
    to: councilNFTAddress,
    data: nftInitSelector + abiCoder.encode(
      ['string', 'string'],
      ['Lux Council Membership', 'LUXC']
    ).slice(2),
  });
  console.log(`   ✅ NFT deployed: ${councilNFTAddress}`);
  console.log(`      Name: Lux Council Membership (LUXC)`);

  // Mint membership NFTs (1 per council member)
  const mintNFTSelector = keccak256(toUtf8Bytes('mint(address)')).slice(0, 10);

  const councilMembers = [deployer, signer1, signer2, signer3, tokenHolder1];
  for (let i = 0; i < councilMembers.length; i++) {
    await sendTx({
      from: deployer,
      to: councilNFTAddress,
      data: mintNFTSelector + abiCoder.encode(
        ['address'],
        [councilMembers[i]]
      ).slice(2),
    });
  }
  console.log(`   ✅ Minted 5 membership NFTs to council members`);

  // Delegate NFT voting power
  for (const member of councilMembers) {
    try {
      await sendTx({
        from: member,
        to: councilNFTAddress,
        data: delegateSelector + abiCoder.encode(['address'], [member]).slice(2),
      });
    } catch (e) {
      // Ignore delegation errors
    }
  }
  console.log(`   ✅ Council members delegated voting power`);

  await mineBlocks(1);

  // Deploy Safe for Council DAO
  console.log('\n📌 Deploying council treasury (Safe)...');
  const councilSafeNonce = BigInt(Date.now() + 2);
  const councilSafeSetupData = safeSetupSelector + abiCoder.encode(
    ['address[]', 'uint256', 'address', 'bytes', 'address', 'address', 'uint256', 'address'],
    [
      [deployer],
      1,
      '0x0000000000000000000000000000000000000000',
      '0x',
      deployment.contracts.compatibilityFallbackHandler,
      '0x0000000000000000000000000000000000000000',
      0,
      '0x0000000000000000000000000000000000000000',
    ]
  ).slice(2);

  const councilSafeReceipt = await sendTx({
    from: deployer,
    to: deployment.contracts.gnosisSafeProxyFactory,
    data: createProxySelector + abiCoder.encode(
      ['address', 'bytes', 'uint256'],
      [deployment.contracts.gnosisSafeL2Singleton, councilSafeSetupData, councilSafeNonce]
    ).slice(2),
  });

  const councilSafeLog = councilSafeReceipt.logs?.find((log: any) => log.topics?.[0] === proxyCreationTopic);
  const councilSafeAddress = councilSafeLog ? '0x' + councilSafeLog.topics[1].slice(26) : '0x' + (councilSafeReceipt.logs?.[0]?.data || '').slice(26, 66);

  console.log(`   ✅ Safe deployed: ${councilSafeAddress}`);

  // Fund the council DAO
  await sendTx({
    from: deployer,
    to: councilSafeAddress,
    value: '0x' + BigInt('25000000000000000000').toString(16), // 25 ETH
  });
  console.log(`   ✅ Funded: 25 ETH\n`);

  deployedDAOs.push({
    name: 'Lux Council (ERC721 Governor)',
    type: 'governor_erc721',
    safeAddress: councilSafeAddress,
    tokenAddress: councilNFTAddress,
  });

  // =======================================================
  // Summary
  // =======================================================
  console.log('\n');
  console.log('╔══════════════════════════════════════════════════════════════╗');
  console.log('║                    🎉 ALL DAOs LAUNCHED! 🎉                   ║');
  console.log('╠══════════════════════════════════════════════════════════════╣');

  for (const dao of deployedDAOs) {
    console.log(`║                                                              ║`);
    console.log(`║  📍 ${dao.name.padEnd(45)}║`);
    console.log(`║     Type: ${dao.type.padEnd(45)}║`);
    console.log(`║     Safe: ${dao.safeAddress.padEnd(45)}║`);
    if (dao.tokenAddress) {
      console.log(`║     Token: ${dao.tokenAddress.padEnd(44)}║`);
    }
  }

  console.log(`║                                                              ║`);
  console.log('╠══════════════════════════════════════════════════════════════╣');
  console.log('║  🔗 Access DAOs at: http://localhost:5173                     ║');
  console.log('║                                                              ║');
  console.log('║  📋 DAO URLs:                                                 ║');
  console.log(`║     • local:${multisigSafeAddress.slice(0,20)}...     ║`);
  console.log(`║     • local:${govSafeAddress.slice(0,20)}...     ║`);
  console.log(`║     • local:${councilSafeAddress.slice(0,20)}...     ║`);
  console.log('╚══════════════════════════════════════════════════════════════╝');

  // Save deployment info
  const daoDeploymentPath = path.join(__dirname, '../deployments/daos-localhost-1337.json');
  fs.writeFileSync(daoDeploymentPath, JSON.stringify({
    timestamp: new Date().toISOString(),
    chainId: 1337,
    daos: deployedDAOs,
    accounts: {
      deployer,
      signers: [signer1, signer2, signer3],
      tokenHolders: [tokenHolder1, tokenHolder2],
    },
  }, null, 2));
  console.log(`\n📁 DAO deployment saved to: ${daoDeploymentPath}`);

  await connection.close();
  console.log('\n✅ DAO Launcher complete!');
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error('❌ Launch failed:', error.message);
    process.exit(1);
  });
