import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import { KeyValuePairs, KeyValuePairs__factory } from '../../typechain-types';

describe('KeyValuePairs', function () {
  let keyValuePairs: KeyValuePairs;
  let deployer: SignerWithAddress;
  let user: SignerWithAddress;

  beforeEach(async function () {
    [deployer, user] = await ethers.getSigners();
    keyValuePairs = await new KeyValuePairs__factory(deployer).deploy();
  });

  describe('updateValues', function () {
    it('should emit ValueUpdated events for each key-value pair', async function () {
      const keyValuePairsData = [
        { key: 'name', value: 'Alice' },
        { key: 'age', value: '25' },
        { key: 'city', value: 'New York' },
      ];

      await expect(keyValuePairs.connect(user).updateValues(keyValuePairsData))
        .to.emit(keyValuePairs, 'ValueUpdated')
        .withArgs(user.address, 'name', 'Alice')
        .to.emit(keyValuePairs, 'ValueUpdated')
        .withArgs(user.address, 'age', '25')
        .to.emit(keyValuePairs, 'ValueUpdated')
        .withArgs(user.address, 'city', 'New York');
    });

    it('should work with a single key-value pair', async function () {
      const keyValuePairsData = [{ key: 'single', value: 'value' }];

      await expect(keyValuePairs.connect(user).updateValues(keyValuePairsData))
        .to.emit(keyValuePairs, 'ValueUpdated')
        .withArgs(user.address, 'single', 'value');
    });

    it('should work with empty arrays', async function () {
      const keyValuePairsData: { key: string; value: string }[] = [];

      await expect(keyValuePairs.connect(user).updateValues(keyValuePairsData)).to.not.be.reverted;
    });
  });
});
