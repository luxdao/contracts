import { ethers } from 'hardhat';
import { ModuleProxyFactory, ModuleProxyFactory__factory } from '../../typechain-types';

let moduleProxyFactory: ModuleProxyFactory;

beforeEach(async () => {
  const [deployer] = await ethers.getSigners();
  moduleProxyFactory = await new ModuleProxyFactory__factory(deployer).deploy();
});

export const getModuleProxyFactory = (): ModuleProxyFactory => {
  return moduleProxyFactory;
};
