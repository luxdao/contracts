import path from 'node:path';
import hardhatEthers from '@nomicfoundation/hardhat-ethers';
import hardhatEthersChaiMatchers from '@nomicfoundation/hardhat-ethers-chai-matchers';
import hardhatIgnitionEthers from '@nomicfoundation/hardhat-ignition-ethers';
import hardhatMocha from '@nomicfoundation/hardhat-mocha';
import hardhatNetworkHelpers from '@nomicfoundation/hardhat-network-helpers';
import hardhatTypechain from '@nomicfoundation/hardhat-typechain';
import hardhatVerify from '@nomicfoundation/hardhat-verify';
import dotenv from 'dotenv';
import { HardhatUserConfig } from 'hardhat/config';

dotenv.config();

const config: HardhatUserConfig = {
  plugins: [
    hardhatEthers,
    hardhatEthersChaiMatchers,
    hardhatIgnitionEthers,
    hardhatNetworkHelpers,
    hardhatTypechain,
    hardhatVerify,
    hardhatMocha,
  ],
  solidity: {
    compilers: [
      {
        version: '0.8.30',
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
      {
        version: '0.8.22',
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
      {
        version: '0.8.19',
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
    ],
  },
  networks: {
    // Default in-memory EDR network used by the Mocha test-suite.
    // - gasMultiplier gives `eth_estimateGas` headroom for the nested low-level
    //   delegatecalls in the deployer/roles flows; with the default of 1 the
    //   inner call hits the EIP-150 63/64 rule and reverts.
    // - blockGasLimit is raised to 30M (vs the 16.7M default).
    // - transactionGasCap: false disables the EIP-7825 (Osaka) 16,777,216
    //   per-transaction cap so the large-initialization-data and Safe
    //   `execTransaction` deployment paths fit under the block gas limit.
    default: {
      type: 'edr-simulated',
      chainId: 31337,
      gasMultiplier: 1.5,
      blockGasLimit: 30_000_000,
      transactionGasCap: false,
    },
    sepolia: {
      chainId: 11155111,
      url: process.env.SEPOLIA_PROVIDER || 'https://ethereum-sepolia-rpc.publicnode.com',
      accounts: {
        mnemonic: process.env.MNEMONIC || 'light light light light light light light light light light light energy',
      },
      type: 'http',
    },
    mainnet: {
      chainId: 1,
      url: process.env.MAINNET_PROVIDER || 'https://rpc.ankr.com/eth',
      accounts: {
        mnemonic: process.env.MNEMONIC || 'light light light light light light light light light light light energy',
      },
      type: 'http',
    },
    polygon: {
      chainId: 137,
      url: process.env.POLYGON_PROVIDER || 'https://rpc.ankr.com/polygon',
      accounts: {
        mnemonic: process.env.MNEMONIC || 'light light light light light light light light light light light energy',
      },
      type: 'http',
    },
    base: {
      chainId: 8453,
      url: process.env.BASE_PROVIDER || 'https://mainnet.base.org',
      accounts: {
        mnemonic: process.env.MNEMONIC || 'light light light light light light light light light light light energy',
      },
      type: 'http',
    },
    optimism: {
      chainId: 10,
      url: process.env.OPTIMISM_PROVIDER || 'https://mainnet.optimism.io',
      accounts: {
        mnemonic: process.env.MNEMONIC || 'light light light light light light light light light light light energy',
      },
      type: 'http',
    },
    'lux-mainnet': {
      chainId: 96369,
      url: process.env.LUX_MAINNET_PROVIDER || 'https://api.lux.network',
      accounts: {
        mnemonic: process.env.MNEMONIC || 'light light light light light light light light light light light energy',
      },
      type: 'http',
    },
    'lux-testnet': {
      chainId: 96368,
      url: process.env.LUX_TESTNET_PROVIDER || 'https://testnet.api.lux.network',
      accounts: {
        mnemonic: process.env.MNEMONIC || 'light light light light light light light light light light light energy',
      },
      type: 'http',
    },
    pars: {
      chainId: 7070,
      url: process.env.PARS_PROVIDER || 'https://rpc.pars.network',
      accounts: {
        mnemonic: process.env.MNEMONIC || 'light light light light light light light light light light light energy',
      },
      type: 'http',
    },
    localhost: {
      chainId: 1337, // Anvil default chain ID
      url: process.env.RPC_URL || 'http://127.0.0.1:8545',
      accounts: process.env.PRIVATE_KEY
        ? [process.env.PRIVATE_KEY]
        : [
          // Anvil default accounts
          '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80',
          '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d',
          '0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a',
        ],
      type: 'http',
    },
    'lux-local': {
      chainId: 31337,
      url: process.env.LUX_LOCAL_PROVIDER || 'http://127.0.0.1:9630/ext/bc/C/rpc',
      accounts: {
        mnemonic: process.env.MNEMONIC || 'light light light light light light light light light light light energy',
      },
      gasPrice: 30_000_000_000,
      gas: 'auto',
      timeout: 600_000,
      type: 'http',
    },
    'lux-devnet': {
      chainId: 96370,
      url: process.env.LUX_DEVNET_PROVIDER || 'https://devnet.api.lux.network',
      accounts: {
        mnemonic: process.env.MNEMONIC || 'light light light light light light light light light light light energy',
      },
      type: 'http',
    },
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY || '',
  },
  sourcify: {
    enabled: false,
  },
  ignition: {
    strategyConfig: {
      create2: {
        salt:
          process.env.DAO_CREATE2_SALT ||
          '0x0000000000000000000000000000000000000000000000000000000000000000',
      },
    },
  },
  typechain: {
    outDir: path.join(import.meta.dirname, 'typechain-types'),
  },
};

export default config;
