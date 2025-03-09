import type { BaseContract, FunctionFragment, Interface } from 'ethers';
import { ethers } from 'hardhat';

export const calculateProxyAddress = async (
  factory: BaseContract,
  masterCopy: string,
  initData: string,
  saltNonce: string,
): Promise<string> => {
  const masterCopyAddress = masterCopy.toLowerCase().replace(/^0x/, '');
  const byteCode =
    '0x602d8060093d393df3363d3d373d3d3d363d73' +
    masterCopyAddress +
    '5af43d82803e903d91602b57fd5bf3';

  const salt = ethers.solidityPackedKeccak256(
    ['bytes32', 'uint256'],
    [ethers.solidityPackedKeccak256(['bytes'], [initData]), saltNonce],
  );

  return ethers.getCreate2Address(await factory.getAddress(), salt, ethers.keccak256(byteCode));
};

export const topHatIdToHatId = (topHatId: bigint): bigint => {
  // Ensure the input is valid (fits within uint32)
  if (topHatId <= 0 || topHatId > 0xffffffff) {
    throw new Error('Top hat ID must be a positive integer that fits within uint32');
  }

  // Shift left by 224 bits (same as in Solidity)
  return topHatId << 224n;
};

/**
 * Calculate an interface ID from an ethers Interface object.
 * The interface ID is the XOR of all function selectors in the interface.
 * @param interfaceObj An ethers Interface object
 * @returns The interface ID as a hex string with 0x prefix
 */
export function calculateInterfaceId(interfaceObj: Interface): string {
  // Get all function fragments from the interface
  const fragments = interfaceObj.fragments.filter(
    (fragment): fragment is FunctionFragment => fragment.type === 'function',
  );

  if (fragments.length === 0) {
    throw new Error('Interface has no functions');
  }

  // XOR all function selectors
  let interfaceId = BigInt(0);
  for (const fragment of fragments) {
    // Get the selector by using the function's signature
    const selector = interfaceObj.getFunction(fragment.selector)?.selector;
    if (selector) {
      interfaceId = interfaceId ^ BigInt(selector);
    }
  }

  return '0x' + interfaceId.toString(16).padStart(8, '0');
}
