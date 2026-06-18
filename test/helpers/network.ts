import { network } from 'hardhat';

/**
 * Canonical Hardhat 3 network connection for the Mocha test-suite.
 *
 * Hardhat 3 no longer exposes a global `ethers` object (`import { ethers } from
 * 'hardhat'`) nor standalone `@nomicfoundation/hardhat-network-helpers`
 * functions. Both now hang off a network connection obtained via the network
 * manager. This module establishes that connection exactly once (cached by
 * network name via `getOrCreate`) and re-exports the pieces the tests need, so
 * every test draws `ethers` and the network helpers from a single shared source.
 */
const connection = await network.getOrCreate();

export const { ethers } = connection;

const { networkHelpers } = connection;
export const { time } = networkHelpers;
export const mine = networkHelpers.mine.bind(networkHelpers);
export const loadFixture = networkHelpers.loadFixture.bind(networkHelpers);
