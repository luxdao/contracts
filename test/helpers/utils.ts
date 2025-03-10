import type { BaseContract } from 'ethers';
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
