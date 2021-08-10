import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signer-with-address'

import { constants, id } from '@yield-protocol/utils-v2'
const { WAD, MAX256 } = constants
const MAX = MAX256

import StrategyArtifact from '../artifacts/contracts/Strategy.sol/Strategy.json'
import VaultMockArtifact from '../artifacts/contracts/mocks/VaultMock.sol/VaultMock.json'
import PoolMockArtifact from '../artifacts/contracts/mocks/PoolMock.sol/PoolMock.json'
import ERC20MockArtifact from '../artifacts/contracts/mocks/ERC20Mock.sol/ERC20Mock.json'

import { ERC20Mock as ERC20, ERC20Mock } from '../typechain/ERC20Mock'
import { Strategy } from '../typechain/Strategy'
import { VaultMock } from '../typechain/VaultMock'
import { PoolMock } from '../typechain/PoolMock'
import { FYTokenMock } from '../typechain/FYTokenMock'

import { BigNumber } from 'ethers'

import { ethers, waffle } from 'hardhat'
import { expect } from 'chai'
const { deployContract, loadFixture } = waffle

function almostEqual(x: BigNumber, y: BigNumber, p: BigNumber) {
  // Check that abs(x - y) < p:
  const diff = x.gt(y) ? BigNumber.from(x).sub(y) : BigNumber.from(y).sub(x) // Not sure why I have to convert x and y to BigNumber
  expect(diff.div(p)).to.eq(0) // Hack to avoid silly conversions. BigNumber truncates decimals off.
}

describe('Strategy - Pool Management', async function () {
  this.timeout(0)

  let ownerAcc: SignerWithAddress
  let owner: string
  let user1: string
  let user1Acc: SignerWithAddress
  let user2: string
  let user2Acc: SignerWithAddress

  let strategy: Strategy
  let vault: VaultMock
  let base: ERC20
  let fyToken1: FYTokenMock
  let fyToken2: FYTokenMock
  let pool1: PoolMock
  let pool2: PoolMock

  let maturity1 = 1633046399
  let maturity2 = 1640995199

  let baseId: string
  let series1Id: string
  let series2Id: string

  const ZERO_ADDRESS = '0x' + '0'.repeat(40)
  const ZERO_BYTES6 = '0x' + '0'.repeat(12)

  async function fixture() {} // For now we just use this to snapshot and revert the state of the blockchain

  before(async () => {
    await loadFixture(fixture) // This snapshots the blockchain as a side effect
    const signers = await ethers.getSigners()
    ownerAcc = signers[0]
    owner = ownerAcc.address
    user1Acc = signers[1]
    user1 = user1Acc.address
    user2Acc = signers[2]
    user2 = user2Acc.address
  })

  after(async () => {
    await loadFixture(fixture) // We advance the time to test maturity features, this rolls it back after the tests
  })

  beforeEach(async () => {
    // Set up Vault and Series
    vault = (await deployContract(ownerAcc, VaultMockArtifact, [])) as VaultMock
    base = ((await ethers.getContractAt('ERC20Mock', await vault.base(), ownerAcc)) as unknown) as ERC20Mock
    baseId = await vault.baseId()

    series1Id = await vault.callStatic.addSeries(maturity1)
    await vault.addSeries(maturity1)
    fyToken1 = ((await ethers.getContractAt(
      'FYTokenMock',
      (await vault.series(series1Id)).fyToken,
      ownerAcc
    )) as unknown) as FYTokenMock

    series2Id = await vault.callStatic.addSeries(maturity2)
    await vault.addSeries(maturity2)
    fyToken2 = ((await ethers.getContractAt(
      'FYTokenMock',
      (await vault.series(series2Id)).fyToken,
      ownerAcc
    )) as unknown) as FYTokenMock

    // Set up YieldSpace
    pool1 = (await deployContract(ownerAcc, PoolMockArtifact, [base.address, fyToken1.address])) as PoolMock
    pool2 = (await deployContract(ownerAcc, PoolMockArtifact, [base.address, fyToken2.address])) as PoolMock
    await base.mint(pool1.address, WAD.mul(1000000))
    await base.mint(pool2.address, WAD.mul(1000000))
    await fyToken1.mint(pool1.address, WAD.mul(100000))
    await fyToken2.mint(pool2.address, WAD.mul(100000))
    await pool1.mint(owner, true, 0)
    await pool2.mint(owner, true, 0)
    await pool1.sync()
    await pool2.sync()

    strategy = (await deployContract(ownerAcc, StrategyArtifact, [
      'Strategy Token',
      'STR',
      18,
      vault.address,
      base.address,
      baseId,
    ])) as Strategy

    await strategy.grantRoles([id('setNextPool(address,bytes6)')], owner)
  })

  it('sets up testing environment', async () => {})

  it("can't set a pool with mismatched base", async () => {
    const wrongPool = (await deployContract(ownerAcc, PoolMockArtifact, [strategy.address, fyToken1.address])) as PoolMock
    await expect(strategy.setNextPool(wrongPool.address, series2Id)).to.be.revertedWith(
      'Mismatched base'
    )
  })

  it("can't set a pool with mismatched seriesId", async () => {
    await expect(strategy.setNextPool(pool1.address, series2Id)).to.be.revertedWith(
      'Mismatched seriesId'
    )
  })

  it("can't start with a pool if next pool not set", async () => {
    await expect(strategy.startPool()).to.be.revertedWith(
      'Next pool not set'
    )
  })

  it('sets next pool', async () => {
    await expect(strategy.setNextPool(pool1.address, series1Id)).to.emit(
      strategy,
      'NextPoolSet'
    )

    expect(await strategy.nextPool()).to.equal(pool1.address)
    expect(await strategy.nextSeriesId()).to.equal(series1Id)
  })

  describe('with next pool set', async () => {
    beforeEach(async () => {
      await strategy.setNextPool(pool1.address, series1Id)
    })

    it("can't start with a pool if no funds are present", async () => {
      await expect(strategy.startPool()).to.be.revertedWith(
        'No funds to start with'
      )
    })

    it('starts with next pool - sets and deletes pool variables', async () => {
      await base.mint(strategy.address, WAD)
      await expect(strategy.startPool()).to.emit(
        strategy,
        'PoolStarted'
      )

      expect(await strategy.pool()).to.equal(pool1.address)
      expect(await strategy.fyToken()).to.equal(fyToken1.address)
      expect(await strategy.seriesId()).to.equal(series1Id)

      expect(await strategy.nextPool()).to.equal(ZERO_ADDRESS)
      expect(await strategy.nextSeriesId()).to.equal(ZERO_BYTES6)
    })

    it('starts with next pool - borrows and mints', async () => {
      const poolBaseBefore = await base.balanceOf(pool1.address)
      const poolFYTokenBefore = await fyToken1.balanceOf(pool1.address)
      const poolSupplyBefore = await pool1.totalSupply()

      await base.mint(strategy.address, WAD)
      await expect(strategy.startPool()).to.emit(
        strategy,
        'PoolStarted'
      )

      const poolBaseAdded = (await base.balanceOf(pool1.address)).sub(poolBaseBefore)
      const poolFYTokenAdded = (await fyToken1.balanceOf(pool1.address)).sub(poolFYTokenBefore)
      const vaultId = await strategy.vaultId()

      expect((await vault.vaults(vaultId)).owner).to.equal(strategy.address)  // The strategy created a vault
      expect((await vault.balances(vaultId)).art).to.equal(poolFYTokenAdded)  // The strategy borrowed fyToken
      expect(poolBaseAdded.add(poolFYTokenAdded)).to.equal(WAD)               // The strategy used all the funds

      expect(await pool1.balanceOf(strategy.address)).to.equal((await pool1.totalSupply()).sub(poolSupplyBefore)) // The strategy received the LP tokens

      expect(await pool1.baseReserves()).to.equal(await pool1.getBaseReserves())  // The pool used all the received funds to mint
      almostEqual(
        await pool1.fyTokenReserves(),
        await pool1.getFYTokenReserves(),
        BigNumber.from(10)
      )  // The pool used all the received funds to mint (minus rounding in single-digit wei)

      expect(await pool1.balanceOf(strategy.address)).to.equal(await strategy.cached())
      expect(await strategy.balanceOf(owner)).to.equal(await strategy.totalSupply())

      // Sanity check
      expect(await pool1.balanceOf(strategy.address)).not.equal(BigNumber.from(0))
      expect(await strategy.totalSupply()).not.equal(BigNumber.from(0))
    })

    describe('with a pool started', async () => {
      beforeEach(async () => {
        await base.mint(strategy.address, WAD)
        await strategy.startPool()
      })
  
      it('mints strategy tokens', async () => {
        const poolRatio = (WAD.mul(await base.balanceOf(pool1.address)).div(await fyToken1.balanceOf(pool1.address)))
        const poolSupplyBefore = await pool1.totalSupply()
        const strategyReservesBefore = await pool1.balanceOf(strategy.address)
        const strategySupplyBefore = await strategy.totalSupply()

        // Mint some LP tokens, and leave them in the strategy
        await base.mint(pool1.address, WAD)
        await fyToken1.mint(pool1.address, poolRatio) // ... * WAD / WAD
        await pool1.mint(strategy.address, true, 0)
  
        await expect(strategy.mint(user1)).to.emit(
          strategy,
          'Transfer'
        )

        const lpMinted = (await pool1.totalSupply()).sub(poolSupplyBefore)
        const strategyMinted = (await strategy.totalSupply()).sub(strategySupplyBefore)
        expect(await strategy.cached()).to.equal(strategyReservesBefore.add(lpMinted))
        expect(await strategy.balanceOf(user1)).to.equal(strategyMinted)

        // expect(WAD.mul(lpMinted).div(strategyReservesBefore))
        //   .to.equal(WAD.mul(strategyMinted).div(strategySupplyBefore))

        // Sanity check
        expect(lpMinted).not.equal(BigNumber.from(0))
        expect(strategyMinted).not.equal(BigNumber.from(0))
      })
    })
  })

  /* it('inits up', async () => {
    await base.mint(strategy.address, WAD)
    await expect(strategy.init(user1)).to.emit(strategy, 'Transfer')
    expect(await strategy.balanceOf(user1)).to.equal(WAD)
  })

  describe('once initialized', async () => {
    beforeEach(async () => {
      await base.mint(strategy.address, WAD)
      await strategy.init(owner)
    })*/


    /* describe('with a pool queue set', async () => {
      beforeEach(async () => {
        await strategy.setPools([pool1.address, pool2.address], [series1Id, series2Id])
      })

      it("can't set a new pool queue until done", async () => {
        await expect(strategy.setPools([pool1.address, pool2.address], [series1Id, series1Id])).to.be.revertedWith(
          'Pools still queued'
        )
      })

      it('swaps to the first pool', async () => {
        await expect(strategy.swap()).to.emit(strategy, 'PoolSwapped')

        expect(await strategy.poolCounter()).to.equal(0)
        expect(await strategy.pool()).to.equal(pool1.address)
        expect(await strategy.fyToken()).to.equal(fyToken1.address)

        const vaultId = await strategy.vaultId()
        const [vaultOwner, vaultSeriesId] = await vault.vaults(vaultId)
        expect(vaultOwner).to.equal(strategy.address)
        expect(vaultSeriesId).to.equal(series1Id)

        const poolCache = await strategy.poolCache()
        expect(poolCache.base).to.equal(await pool1.baseCached())
        expect(poolCache.fyToken).to.equal(await pool1.fyTokenCached())
      })

      describe('with an active pool', async () => {
        beforeEach(async () => {
          await strategy.swap()
        })

        it("can't swap to a new pool queue until maturity", async () => {
          await expect(strategy.swap()).to.be.revertedWith('Only after maturity')
        })

        it('can swap to the next pool after maturity', async () => {
          const snapshotId = await ethers.provider.send('evm_snapshot', [])
          await ethers.provider.send('evm_mine', [maturity1 + 1])

          await expect(strategy.swap()).to.emit(strategy, 'PoolSwapped')

          expect(await strategy.poolCounter()).to.equal(1)
          expect(await strategy.pool()).to.equal(pool2.address)
          expect(await strategy.fyToken()).to.equal(fyToken2.address)

          const vaultId = await strategy.vaultId()
          const [vaultOwner, vaultSeriesId] = await vault.vaults(vaultId)
          expect(vaultOwner).to.equal(strategy.address)
          expect(vaultSeriesId).to.equal(series2Id)

          const poolCache = await strategy.poolCache()
          expect(poolCache.base).to.equal(await pool2.baseCached())
          expect(poolCache.fyToken).to.equal(await pool2.fyTokenCached())

          await ethers.provider.send('evm_revert', [snapshotId])
        })

        it('can swap out of the last pool', async () => {
          const snapshotId = await ethers.provider.send('evm_snapshot', [])
          await ethers.provider.send('evm_mine', [maturity2 + 1])

          await strategy.swap() // Swap to next pool
          await expect(strategy.swap()).to.emit(strategy, 'PoolSwapped') // Swap out of next pool

          expect(await strategy.poolCounter()).to.equal(MAX)
          expect(await strategy.pool()).to.equal(ZERO_ADDRESS)
          expect(await strategy.fyToken()).to.equal(ZERO_ADDRESS)
          expect(await strategy.vaultId()).to.equal('0x' + '00'.repeat(12))

          const poolCache = await strategy.poolCache()
          expect(poolCache.base).to.equal(ZERO_ADDRESS)
          expect(poolCache.fyToken).to.equal(ZERO_ADDRESS)

          await ethers.provider.send('evm_revert', [snapshotId])
        })

        it('fyToken are counted towards the strategy value', async () => {
          await fyToken1.mint(strategy.address, WAD)
          expect(await strategy.strategyValue()).to.equal(WAD.mul(2))
        })

        it('LP tokens are counted towards the strategy value', async () => {
          await pool1.transfer(strategy.address, WAD)
          expect(await strategy.strategyValue()).to.equal(
            WAD.add(
              (await base.balanceOf(pool1.address))
                .add(await fyToken1.balanceOf(pool1.address))
                .mul(await pool1.balanceOf(strategy.address))
                .div(await pool1.totalSupply())
            )
          )
        })
      })
    })
  }) */
})
