import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import type { ContractTransactionResponse } from 'ethers';
import { ethers } from 'hardhat';
import {
  ERC1967Proxy__factory,
  IAccessControl__factory,
  IERC165__factory,
  IERC20__factory,
  IVersion__factory,
  IVotesERC20LockableV1__factory,
  IVotesERC20V1__factory,
  VotesERC20LockableV1,
  VotesERC20LockableV1__factory,
} from '../../../typechain-types';
import { calculateInterfaceId } from '../../helpers/utils';
import { runUUPSUpgradeabilityTests } from '../../helpers/uupsUpgradeabilityTests';

async function deployVotesERC20Lockable(
  deployer: SignerWithAddress,
  implementation: VotesERC20LockableV1,
  owner: SignerWithAddress,
  locked: boolean,
  maxTotalSupply: bigint,
  name: string,
  symbol: string,
  allocationAddresses: string[],
  allocationAmounts: bigint[],
): Promise<VotesERC20LockableV1> {
  const allocations = allocationAddresses.map((address, index) => ({
    to: address,
    amount: allocationAmounts[index],
  }));

  const fullInitData =
    VotesERC20LockableV1__factory.createInterface().getFunction(
      'initialize(address,bool,uint256,string,string,(address,uint256)[])',
    ).selector +
    ethers.AbiCoder.defaultAbiCoder()
      .encode(
        ['address', 'bool', 'uint256', 'string', 'string', 'tuple(address to, uint256 amount)[]'],
        [owner.address, locked, maxTotalSupply, name, symbol, allocations],
      )
      .slice(2);

  // Deploy the proxy with the implementation
  const proxy = await new ERC1967Proxy__factory(deployer).deploy(implementation, fullInitData);

  return VotesERC20LockableV1__factory.connect(await proxy.getAddress(), deployer);
}

describe('VotesERC20LockableV1', () => {
  let implementation: VotesERC20LockableV1;
  let deployer: SignerWithAddress;
  let owner: SignerWithAddress;
  let nonOwner: SignerWithAddress;
  let tokenHolder: SignerWithAddress;
  let tokenRecipient: SignerWithAddress;
  let spender: SignerWithAddress;
  const TRANSFER_ROLE = ethers.id('TRANSFER_ROLE');
  const MINTER_ROLE = ethers.id('MINTER_ROLE');

  beforeEach(async () => {
    [deployer, owner, nonOwner, tokenHolder, tokenRecipient, spender] = await ethers.getSigners();

    implementation = await new VotesERC20LockableV1__factory(owner).deploy();
  });

  describe('Initialization', () => {
    describe('Locked Behavior', () => {
      it('should be be locked on deployment when locked is true', async () => {
        const proxy = await deployVotesERC20Lockable(
          deployer,
          implementation,
          owner,
          true,
          ethers.parseEther('2100'),
          'Test',
          'TEST',
          [],
          [],
        );
        expect(await proxy.locked()).to.equal(true);
      });

      it('should be unlocked on deployment when locked is false', async () => {
        const proxy = await deployVotesERC20Lockable(
          deployer,
          implementation,
          owner,
          false,
          ethers.parseEther('2100'),
          'Test',
          'TEST',
          [],
          [],
        );
        expect(await proxy.locked()).to.equal(false);
      });
    });

    describe('Setup safety', () => {
      let proxy: VotesERC20LockableV1;

      beforeEach(async () => {
        proxy = await deployVotesERC20Lockable(
          deployer,
          implementation,
          owner,
          false,
          ethers.parseEther('2100'),
          'Test',
          'TEST',
          [],
          [],
        );
      });

      it('should revert if initializer is called after deployment', async () => {
        await expect(
          proxy['initialize(address,bool,uint256,string,string,(address,uint256)[])'](
            owner.address,
            false,
            ethers.parseEther('2100'),
            'Test',
            'TEST',
            [],
          ),
        ).to.be.revertedWithCustomError(proxy, 'InvalidInitialization');
      });
    });
  });

  describe('Lock function', () => {
    describe('When locked at deployment', () => {
      const locked = true;
      let proxy: VotesERC20LockableV1;

      beforeEach(async () => {
        proxy = await deployVotesERC20Lockable(
          deployer,
          implementation,
          owner,
          locked,
          ethers.parseEther('2100'),
          'Test',
          'TEST',
          [],
          [],
        );
      });

      describe('Unlocking by the owner should succeed', () => {
        let unlockTx: ContractTransactionResponse;

        beforeEach(async () => {
          unlockTx = await proxy.connect(owner).lock(false);
        });

        it('should be unlocked', async () => {
          expect(await proxy.locked()).to.equal(false);
        });

        it('should emit an event', async () => {
          expect(unlockTx).to.emit(proxy, 'Locked').withArgs(false);
        });
      });

      describe('Unlocking by a non-owner should fail', () => {
        it('should revert', async () => {
          await expect(proxy.connect(nonOwner).lock(false)).to.be.revertedWithCustomError(
            proxy,
            'OwnableUnauthorizedAccount',
          );
        });
      });

      describe('Trying to lock (despite being locked) should succeed', () => {
        it('should succeed', async () => {
          await expect(proxy.connect(owner).lock(true)).to.not.be.reverted;
        });
      });
    });

    describe('When unlocked at deployment', () => {
      const locked = false;
      let proxy: VotesERC20LockableV1;

      beforeEach(async () => {
        proxy = await deployVotesERC20Lockable(
          deployer,
          implementation,
          owner,
          locked,
          ethers.parseEther('2100'),
          'Test',
          'TEST',
          [],
          [],
        );
      });

      describe('Locking by the owner should succeed', () => {
        let lockTx: ContractTransactionResponse;

        beforeEach(async () => {
          lockTx = await proxy.connect(owner).lock(true);
        });

        it('should be locked', async () => {
          expect(await proxy.locked()).to.equal(true);
        });

        it('should emit an event', async () => {
          expect(lockTx).to.emit(proxy, 'Locked').withArgs(true);
        });
      });

      describe('Locking by a non-owner should fail', () => {
        it('should revert', async () => {
          await expect(proxy.connect(nonOwner).lock(true)).to.be.revertedWithCustomError(
            proxy,
            'OwnableUnauthorizedAccount',
          );
        });
      });

      describe('Trying to unlock (despite being unlocked) should succeed', () => {
        it('should succeed', async () => {
          await expect(proxy.connect(owner).lock(false)).to.not.be.reverted;
        });
      });
    });
  });

  describe('SetMaxTotalSupply function', () => {
    const locked = false;
    const maxTotalSupply = ethers.parseEther('2');
    const newMaxTotalSupply = ethers.parseEther('20');
    let proxy: VotesERC20LockableV1;

    beforeEach(async () => {
      proxy = await deployVotesERC20Lockable(
        deployer,
        implementation,
        owner,
        locked,
        maxTotalSupply,
        'Test',
        'TEST',
        [],
        [],
      );
    });

    describe('Updating by the owner should succeed', () => {
      let updateTx: ContractTransactionResponse;

      beforeEach(async () => {
        updateTx = await proxy.connect(owner).setMaxTotalSupply(newMaxTotalSupply);
      });

      it('should be updated', async () => {
        expect(await proxy.maxTotalSupply()).to.equal(newMaxTotalSupply);
      });

      it('should emit an event', async () => {
        expect(updateTx).to.emit(proxy, 'MaxTotalSupplyUpdated').withArgs(newMaxTotalSupply);
      });

      it('should not emit an event if newMaxTotalSupply is same', async () => {
        const anotherUpdateTx = await proxy.connect(owner).setMaxTotalSupply(newMaxTotalSupply);
        expect(anotherUpdateTx).not.to.emit(proxy, 'MaxTotalSupplyUpdated');
      });
    });

    describe('Updating by a owner with maxTotalSupply lower than totalSupply', () => {
      it('should revert', async () => {
        const mintedAmount = maxTotalSupply - 1n;
        await proxy.connect(owner).mint(owner, mintedAmount);
        await expect(
          proxy.connect(owner).setMaxTotalSupply(mintedAmount - 1n),
        ).to.be.revertedWithCustomError(proxy, 'InvalidMaxTotalSupply');
      });
    });

    describe('Updating by a non-owner should fail', () => {
      it('should revert', async () => {
        await expect(
          proxy.connect(nonOwner).setMaxTotalSupply(newMaxTotalSupply),
        ).to.be.revertedWithCustomError(proxy, 'OwnableUnauthorizedAccount');
      });
    });
  });

  describe('Transferring Tokens', () => {
    let tokenHolderAddresses: string[];
    let tokenHolderAmounts: bigint[];

    beforeEach(async () => {
      tokenHolderAddresses = [tokenHolder.address, owner.address];
      tokenHolderAmounts = [ethers.parseEther('100'), ethers.parseEther('100')];
    });

    describe('Transfer function', () => {
      let proxy: VotesERC20LockableV1;

      describe('when token is locked', () => {
        const locked = true;

        beforeEach(async () => {
          proxy = await deployVotesERC20Lockable(
            deployer,
            implementation,
            owner,
            locked,
            ethers.parseEther('2100'),
            'Test',
            'TEST',
            tokenHolderAddresses,
            tokenHolderAmounts,
          );
        });

        describe('when caller is owner', () => {
          beforeEach(async () => {
            await proxy.connect(owner).transfer(tokenRecipient.address, ethers.parseEther('1'));
          });

          it('should transfer tokens', async () => {
            expect(await proxy.balanceOf(tokenRecipient.address)).to.equal(ethers.parseEther('1'));
            expect(await proxy.balanceOf(owner.address)).to.equal(ethers.parseEther('99'));
          });
        });

        describe('when caller is whitelisted', () => {
          beforeEach(async () => {
            await proxy.connect(owner).grantRole(TRANSFER_ROLE, tokenHolder.address);
            await proxy
              .connect(tokenHolder)
              .transfer(tokenRecipient.address, ethers.parseEther('1'));
          });

          it('should transfer tokens', async () => {
            expect(await proxy.balanceOf(tokenRecipient.address)).to.equal(ethers.parseEther('1'));
            expect(await proxy.balanceOf(tokenHolder.address)).to.equal(ethers.parseEther('99'));
          });
        });

        describe('when caller is not owner or whitelisted', () => {
          it('should revert', async () => {
            await expect(
              proxy.connect(tokenHolder).transfer(tokenRecipient.address, ethers.parseEther('1')),
            ).to.be.revertedWithCustomError(proxy, 'IsLocked');
          });
        });
      });

      describe('when token is not locked', () => {
        const locked = false;

        beforeEach(async () => {
          proxy = await deployVotesERC20Lockable(
            deployer,
            implementation,
            owner,
            locked,
            ethers.parseEther('2100'),
            'Test',
            'TEST',
            tokenHolderAddresses,
            tokenHolderAmounts,
          );
        });

        describe('when caller is owner', () => {
          beforeEach(async () => {
            await proxy.connect(owner).transfer(tokenRecipient.address, ethers.parseEther('1'));
          });

          it('should transfer tokens', async () => {
            expect(await proxy.balanceOf(tokenRecipient.address)).to.equal(ethers.parseEther('1'));
            expect(await proxy.balanceOf(owner.address)).to.equal(ethers.parseEther('99'));
          });
        });

        describe('when caller is whitelisted', () => {
          beforeEach(async () => {
            await proxy.connect(owner).grantRole(TRANSFER_ROLE, tokenHolder.address);
            await proxy
              .connect(tokenHolder)
              .transfer(tokenRecipient.address, ethers.parseEther('1'));
          });

          it('should transfer tokens', async () => {
            expect(await proxy.balanceOf(tokenRecipient.address)).to.equal(ethers.parseEther('1'));
            expect(await proxy.balanceOf(tokenHolder.address)).to.equal(ethers.parseEther('99'));
          });
        });

        describe('when caller is not owner or whitelisted', () => {
          beforeEach(async () => {
            await proxy
              .connect(tokenHolder)
              .transfer(tokenRecipient.address, ethers.parseEther('1'));
          });

          it('should transfer tokens', async () => {
            expect(await proxy.balanceOf(tokenRecipient.address)).to.equal(ethers.parseEther('1'));
            expect(await proxy.balanceOf(tokenHolder.address)).to.equal(ethers.parseEther('99'));
          });
        });
      });
    });

    describe('TransferFrom function', () => {
      let proxy: VotesERC20LockableV1;

      describe('when token is locked', () => {
        const locked = true;

        beforeEach(async () => {
          proxy = await deployVotesERC20Lockable(
            deployer,
            implementation,
            owner,
            locked,
            ethers.parseEther('2100'),
            'Test',
            'TEST',
            tokenHolderAddresses,
            tokenHolderAmounts,
          );
        });

        describe('when token holder is owner', () => {
          beforeEach(async () => {
            await proxy.connect(owner).approve(spender.address, ethers.parseEther('10'));
            await proxy
              .connect(spender)
              .transferFrom(owner.address, tokenRecipient.address, ethers.parseEther('1'));
          });

          it('should transfer tokens', async () => {
            expect(await proxy.balanceOf(tokenRecipient.address)).to.equal(ethers.parseEther('1'));
            expect(await proxy.balanceOf(owner.address)).to.equal(ethers.parseEther('99'));
          });

          it('should decrease allowance', async () => {
            expect(await proxy.allowance(owner.address, spender.address)).to.equal(
              ethers.parseEther('9'),
            );
          });
        });

        describe('when token holder is whitelisted', () => {
          beforeEach(async () => {
            await proxy.connect(owner).grantRole(TRANSFER_ROLE, tokenHolder.address);
            await proxy.connect(tokenHolder).approve(spender.address, ethers.parseEther('10'));
            await proxy
              .connect(spender)
              .transferFrom(tokenHolder.address, tokenRecipient.address, ethers.parseEther('1'));
          });

          it('should transfer tokens', async () => {
            expect(await proxy.balanceOf(tokenRecipient.address)).to.equal(ethers.parseEther('1'));
            expect(await proxy.balanceOf(tokenHolder.address)).to.equal(ethers.parseEther('99'));
          });

          it('should decrease allowance', async () => {
            expect(await proxy.allowance(tokenHolder.address, spender.address)).to.equal(
              ethers.parseEther('9'),
            );
          });
        });

        describe('when token holder is not owner or whitelisted', () => {
          beforeEach(async () => {
            await proxy.connect(tokenHolder).approve(spender.address, ethers.parseEther('10'));
          });

          it('should revert', async () => {
            await expect(
              proxy
                .connect(spender)
                .transferFrom(tokenHolder.address, tokenRecipient.address, ethers.parseEther('1')),
            ).to.be.revertedWithCustomError(proxy, 'IsLocked');
          });
        });
      });

      describe('when token is not locked', () => {
        const locked = false;

        beforeEach(async () => {
          proxy = await deployVotesERC20Lockable(
            deployer,
            implementation,
            owner,
            locked,
            ethers.parseEther('2100'),
            'Test',
            'TEST',
            tokenHolderAddresses,
            tokenHolderAmounts,
          );
        });

        describe('when token holder is owner', () => {
          beforeEach(async () => {
            await proxy.connect(owner).approve(spender.address, ethers.parseEther('10'));
            await proxy
              .connect(spender)
              .transferFrom(owner.address, tokenRecipient.address, ethers.parseEther('1'));
          });

          it('should transfer tokens', async () => {
            expect(await proxy.balanceOf(tokenRecipient.address)).to.equal(ethers.parseEther('1'));
            expect(await proxy.balanceOf(owner.address)).to.equal(ethers.parseEther('99'));
          });

          it('should decrease allowance', async () => {
            expect(await proxy.allowance(owner.address, spender.address)).to.equal(
              ethers.parseEther('9'),
            );
          });
        });

        describe('when token holder is whitelisted', () => {
          beforeEach(async () => {
            await proxy.connect(owner).grantRole(TRANSFER_ROLE, tokenHolder.address);
            await proxy.connect(tokenHolder).approve(spender.address, ethers.parseEther('10'));
            await proxy
              .connect(spender)
              .transferFrom(tokenHolder.address, tokenRecipient.address, ethers.parseEther('1'));
          });

          it('should transfer tokens', async () => {
            expect(await proxy.balanceOf(tokenRecipient.address)).to.equal(ethers.parseEther('1'));
            expect(await proxy.balanceOf(tokenHolder.address)).to.equal(ethers.parseEther('99'));
          });

          it('should decrease allowance', async () => {
            expect(await proxy.allowance(tokenHolder.address, spender.address)).to.equal(
              ethers.parseEther('9'),
            );
          });
        });

        describe('when token holder is not owner or whitelisted', () => {
          beforeEach(async () => {
            await proxy.connect(tokenHolder).approve(spender.address, ethers.parseEther('10'));
            await proxy
              .connect(spender)
              .transferFrom(tokenHolder.address, tokenRecipient.address, ethers.parseEther('1'));
          });

          it('should transfer tokens', async () => {
            expect(await proxy.balanceOf(tokenRecipient.address)).to.equal(ethers.parseEther('1'));
            expect(await proxy.balanceOf(tokenHolder.address)).to.equal(ethers.parseEther('99'));
          });

          it('should decrease allowance', async () => {
            expect(await proxy.allowance(tokenHolder.address, spender.address)).to.equal(
              ethers.parseEther('9'),
            );
          });
        });

        describe('when spender has insufficient allowance', () => {
          beforeEach(async () => {
            await proxy.connect(tokenHolder).approve(spender.address, ethers.parseEther('0.5'));
          });

          it('should revert', async () => {
            await expect(
              proxy
                .connect(spender)
                .transferFrom(tokenHolder.address, tokenRecipient.address, ethers.parseEther('1')),
            ).to.be.revertedWithCustomError(proxy, 'ERC20InsufficientAllowance');
          });
        });
      });
    });
  });

  describe('Minting Tokens', () => {
    const maxTotalSupply = ethers.parseEther('1');
    let proxy: VotesERC20LockableV1;

    describe('when token is locked', () => {
      const locked = true;

      beforeEach(async () => {
        proxy = await deployVotesERC20Lockable(
          deployer,
          implementation,
          owner,
          locked,
          maxTotalSupply,
          'Test',
          'TEST',
          [],
          [],
        );
      });

      describe('when caller is owner', () => {
        beforeEach(async () => {
          await proxy.connect(owner).mint(owner.address, maxTotalSupply);
        });

        it('should mint tokens', async () => {
          expect(await proxy.balanceOf(owner.address)).to.equal(maxTotalSupply);
        });

        it('should revert when mint more than maxTotalSupply', async () => {
          await expect(proxy.connect(owner).mint(owner.address, 1n)).to.be.revertedWithCustomError(
            proxy,
            'ExceedMaxTotalSupply',
          );
        });
      });

      describe('when caller is has the minter role', () => {
        beforeEach(async () => {
          await proxy.connect(owner).grantRole(MINTER_ROLE, tokenHolder.address);
          await proxy.connect(tokenHolder).mint(tokenHolder.address, maxTotalSupply);
        });

        it('should mint tokens', async () => {
          expect(await proxy.hasRole(MINTER_ROLE, tokenHolder.address)).to.equal(true);
          expect(await proxy.balanceOf(tokenHolder.address)).to.equal(maxTotalSupply);
        });
      });

      describe('when caller has the transfer role', () => {
        beforeEach(async () => {
          await proxy.connect(owner).grantRole(TRANSFER_ROLE, tokenHolder.address);
        });

        it('should revert', async () => {
          expect(await proxy.hasRole(TRANSFER_ROLE, tokenHolder.address)).to.equal(true);

          await expect(
            proxy.connect(tokenHolder).mint(tokenHolder.address, maxTotalSupply),
          ).to.be.revertedWithCustomError(proxy, 'AccessControlUnauthorizedAccount');
        });
      });

      describe('when caller is not owner or whitelisted', () => {
        it('should revert', async () => {
          expect(await proxy.hasRole(MINTER_ROLE, tokenHolder.address)).to.equal(false);
          await expect(
            proxy.connect(tokenHolder).mint(tokenHolder.address, ethers.parseEther('1')),
          ).to.be.revertedWithCustomError(proxy, 'AccessControlUnauthorizedAccount');
        });
      });
    });

    describe('when token is not locked', () => {
      const locked = false;

      beforeEach(async () => {
        proxy = await deployVotesERC20Lockable(
          deployer,
          implementation,
          owner,
          locked,
          ethers.parseEther('2100'),
          'Test',
          'TEST',
          [],
          [],
        );
      });

      describe('when caller is owner', () => {
        beforeEach(async () => {
          await proxy.connect(owner).mint(owner.address, ethers.parseEther('1'));
        });

        it('should mint tokens', async () => {
          expect(await proxy.balanceOf(owner.address)).to.equal(ethers.parseEther('1'));
        });
      });

      describe('when caller is whitelisted', () => {
        beforeEach(async () => {
          await proxy.connect(owner).grantRole(TRANSFER_ROLE, tokenHolder.address);
        });

        it('should revert', async () => {
          expect(await proxy.hasRole(TRANSFER_ROLE, tokenHolder.address)).to.equal(true);

          await expect(
            proxy.connect(tokenHolder).mint(tokenHolder.address, ethers.parseEther('1')),
          ).to.be.revertedWithCustomError(proxy, 'AccessControlUnauthorizedAccount');
        });
      });

      describe('when caller is not owner or whitelisted', () => {
        it('should revert', async () => {
          await expect(
            proxy.connect(tokenHolder).mint(tokenHolder.address, ethers.parseEther('1')),
          ).to.be.revertedWithCustomError(proxy, 'AccessControlUnauthorizedAccount');
        });
      });
    });
  });

  describe('Burning Tokens', () => {
    let tokenHolderAddresses: string[];
    let tokenHolderAmounts: bigint[];
    let proxy: VotesERC20LockableV1;

    beforeEach(async () => {
      tokenHolderAddresses = [tokenHolder.address, owner.address];
      tokenHolderAmounts = [ethers.parseEther('100'), ethers.parseEther('100')];
    });

    describe('when token is locked', () => {
      const locked = true;

      beforeEach(async () => {
        proxy = await deployVotesERC20Lockable(
          deployer,
          implementation,
          owner,
          locked,
          ethers.parseEther('2100'),
          'Test',
          'TEST',
          tokenHolderAddresses,
          tokenHolderAmounts,
        );
      });

      describe('when caller is owner', () => {
        beforeEach(async () => {
          await proxy.connect(owner).burn(ethers.parseEther('1'));
        });

        it('should burn tokens', async () => {
          expect(await proxy.balanceOf(owner.address)).to.equal(ethers.parseEther('99'));
        });
      });

      describe('when caller is whitelisted', () => {
        beforeEach(async () => {
          await proxy.connect(owner).grantRole(TRANSFER_ROLE, tokenHolder.address);
          await proxy.connect(tokenHolder).burn(ethers.parseEther('1'));
        });

        it('should transfer tokens', async () => {
          expect(await proxy.balanceOf(tokenHolder.address)).to.equal(ethers.parseEther('99'));
        });
      });

      describe('when caller is not owner or whitelisted', () => {
        it('should not revert', async () => {
          await proxy.connect(tokenHolder).burn(ethers.parseEther('1'));
          expect(await proxy.balanceOf(tokenHolder.address)).to.equal(ethers.parseEther('99'));
        });
      });
    });

    describe('when token is not locked', () => {
      const locked = false;

      beforeEach(async () => {
        proxy = await deployVotesERC20Lockable(
          deployer,
          implementation,
          owner,
          locked,
          ethers.parseEther('2100'),
          'Test',
          'TEST',
          tokenHolderAddresses,
          tokenHolderAmounts,
        );
      });

      describe('when caller is owner', () => {
        beforeEach(async () => {
          await proxy.connect(owner).transfer(tokenRecipient.address, ethers.parseEther('1'));
        });

        it('should transfer tokens', async () => {
          expect(await proxy.balanceOf(tokenRecipient.address)).to.equal(ethers.parseEther('1'));
          expect(await proxy.balanceOf(owner.address)).to.equal(ethers.parseEther('99'));
        });
      });

      describe('when caller is whitelisted', () => {
        beforeEach(async () => {
          await proxy.connect(owner).grantRole(TRANSFER_ROLE, tokenHolder.address);
          await proxy.connect(tokenHolder).transfer(tokenRecipient.address, ethers.parseEther('1'));
        });

        it('should transfer tokens', async () => {
          expect(await proxy.balanceOf(tokenRecipient.address)).to.equal(ethers.parseEther('1'));
          expect(await proxy.balanceOf(tokenHolder.address)).to.equal(ethers.parseEther('99'));
        });
      });

      describe('when caller is not owner or whitelisted', () => {
        beforeEach(async () => {
          await proxy.connect(tokenHolder).transfer(tokenRecipient.address, ethers.parseEther('1'));
        });

        it('should transfer tokens', async () => {
          expect(await proxy.balanceOf(tokenRecipient.address)).to.equal(ethers.parseEther('1'));
          expect(await proxy.balanceOf(tokenHolder.address)).to.equal(ethers.parseEther('99'));
        });
      });
    });
  });

  describe('Version', () => {
    it('should return the correct version', async () => {
      const proxy = await deployVotesERC20Lockable(
        deployer,
        implementation,
        owner,
        false,
        ethers.parseEther('2100'),
        'Test',
        'TEST',
        [],
        [],
      );
      expect(await proxy.version()).to.equal(1);
    });
  });

  describe('ERC165', function () {
    let proxy: VotesERC20LockableV1;

    beforeEach(async function () {
      proxy = await deployVotesERC20Lockable(
        deployer,
        implementation,
        owner,
        false,
        ethers.parseEther('2100'),
        'Test',
        'TEST',
        [],
        [],
      );
    });

    it('Should support IERC165 interface', async function () {
      void expect(
        await proxy.supportsInterface(calculateInterfaceId(IERC165__factory.createInterface())),
      ).to.be.true;
    });

    it('Should support IVersion interface', async function () {
      void expect(
        await proxy.supportsInterface(calculateInterfaceId(IVersion__factory.createInterface())),
      ).to.be.true;
    });

    it('Should support IVotesERC20LockableV1 interface', async function () {
      void expect(
        await proxy.supportsInterface(
          calculateInterfaceId(IVotesERC20LockableV1__factory.createInterface(), [
            IVotesERC20V1__factory.createInterface(),
          ]),
        ),
      ).to.be.true;
    });

    it('Should support IVotesERC20V1 interface', async function () {
      void expect(
        await proxy.supportsInterface(
          calculateInterfaceId(IVotesERC20V1__factory.createInterface()),
        ),
      ).to.be.true;
    });

    it('Should support IERC20 interface', async function () {
      void expect(
        await proxy.supportsInterface(calculateInterfaceId(IERC20__factory.createInterface())),
      ).to.be.true;
    });

    it('Should support IAccessControl interface', async function () {
      void expect(
        await proxy.supportsInterface(
          calculateInterfaceId(IAccessControl__factory.createInterface()),
        ),
      ).to.be.true;
    });

    it('Should not support random interface', async function () {
      const randomInterfaceId = '0x12345678';
      void expect(await proxy.supportsInterface(randomInterfaceId)).to.be.false;
    });
  });

  describe('VotesERC20LockableV1 UUPS Upgradeability', function () {
    let votesERC20Lockable: VotesERC20LockableV1;

    beforeEach(async function () {
      votesERC20Lockable = await deployVotesERC20Lockable(
        deployer,
        implementation,
        owner,
        false,
        ethers.parseEther('2100'),
        'Test Voting Token',
        'TVT',
        [],
        [],
      );
    });

    // Run UUPS upgradeability tests
    runUUPSUpgradeabilityTests({
      getContract: () => votesERC20Lockable,
      createNewImplementation: async () => {
        const newImplementation = await new VotesERC20LockableV1__factory(owner).deploy();
        return newImplementation;
      },
      owner: () => owner,
      nonOwner: () => nonOwner,
    });
  });
});
