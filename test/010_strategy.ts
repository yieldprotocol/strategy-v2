import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signer-with-address'

import { constants, id } from '@yield-protocol/utils-v2'
const { WAD, MAX256 } = constants
const MAX = MAX256

import VaultMockArtifact from '../artifacts/contracts/mocks/VaultMock.sol/VaultMock.json'

import { SafeERC20Namer } from '../typechain/SafeERC20Namer'
import { YieldMathExtensions } from '../typechain/YieldMathExtensions'
import { YieldMath } from '../typechain/YieldMath'
import { Strategy } from '../typechain/Strategy'
import { Pool } from '../typechain/Pool'
import { VaultMock } from '../typechain/VaultMock'
import { FYTokenMock } from '../typechain/FYTokenMock'
import { ERC20Mock as ERC20, ERC20Mock } from '../typechain/ERC20Mock'

import { BigNumber } from 'ethers'

import { ethers, waffle } from 'hardhat'
import { expect } from 'chai'
const { deployContract } = waffle

function almostEqual(x: BigNumber, y: BigNumber, p: BigNumber) {
  // Check that abs(x - y) < p:
  const diff = x.gt(y) ? BigNumber.from(x).sub(y) : BigNumber.from(y).sub(x) // Not sure why I have to convert x and y to BigNumber
  expect(diff.div(p)).to.eq(0) // Hack to avoid silly conversions. BigNumber truncates decimals off.
}

describe('Strategy', async function () {
  this.timeout(0)
  let resetChain: number
  let snapshotId: number

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
  let pool1: Pool
  let pool2: Pool
  let badPool: Pool

  let maturity1 = 1672412400
  let maturity2 = 1680271200
  let ts = '14613551152'
  let g1 = '13835058055282163712'
  let g2 = '24595658764946068821'

  let baseId: string
  let series1Id: string
  let series2Id: string

  const ZERO_ADDRESS = '0x' + '0'.repeat(40)
  const ZERO_BYTES6 = '0x' + '0'.repeat(12)
  const ZERO_BYTES12 = '0x' + '0'.repeat(24)

  before(async () => {
    resetChain = await ethers.provider.send('evm_snapshot', [])
    const signers = await ethers.getSigners()
    ownerAcc = signers[0]
    owner = ownerAcc.address
    user1Acc = signers[1]
    user1 = user1Acc.address
    user2Acc = signers[2]
    user2 = user2Acc.address
  })

  after(async () => {
    await ethers.provider.send('evm_revert', [resetChain])
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

    // Set up libraries
    const SafeERC20NamerFactory = await ethers.getContractFactory('SafeERC20Namer')
    const safeERC20Namer = ((await SafeERC20NamerFactory.deploy()) as unknown) as SafeERC20Namer
    await safeERC20Namer.deployed()

    const YieldMathFactory = await ethers.getContractFactory('YieldMath')
    const yieldMath = ((await YieldMathFactory.deploy()) as unknown) as YieldMath
    await yieldMath.deployed()

    const YieldMathExtensionsFactory = await ethers.getContractFactory('YieldMathExtensions', {
      libraries: {
        YieldMath: yieldMath.address,
      },
    })
    const YieldMathExtensionsLibrary = ((await YieldMathExtensionsFactory.deploy()) as unknown) as YieldMathExtensions
    await YieldMathExtensionsLibrary.deployed()

    // Set up YieldSpace
    const poolLibs = {
      YieldMath: yieldMath.address,
    }
    const PoolFactory = await ethers.getContractFactory('Pool', {
      libraries: poolLibs,
    })
    pool1 = ((await PoolFactory.deploy(base.address, fyToken1.address, ts, g1, g2)) as unknown) as Pool
    pool2 = ((await PoolFactory.deploy(base.address, fyToken2.address, ts, g1, g2)) as unknown) as Pool
    badPool = ((await PoolFactory.deploy(safeERC20Namer.address, fyToken2.address, ts, g1, g2)) as unknown) as Pool
    await badPool.deployed()

    await base.mint(pool1.address, WAD.mul(1000000))
    await base.mint(pool2.address, WAD.mul(1000000))
    await pool1.mint(owner, ZERO_ADDRESS, 0, MAX)
    await pool2.mint(owner, ZERO_ADDRESS, 0, MAX)

    const strategyFactory = await ethers.getContractFactory('Strategy', {
      libraries: {
        SafeERC20Namer: safeERC20Namer.address,
        YieldMathExtensions: YieldMathExtensionsLibrary.address,
      },
    })
    strategy = ((await strategyFactory.deploy(
      'Strategy Token',
      'STR',
      vault.address,
      base.address,
      baseId,
      vault.joins(baseId)
    )) as unknown) as Strategy
    await strategy.deployed()

    await strategy.grantRoles(
      [id(strategy.interface, 'setNextPool(address,bytes6)'), id(strategy.interface, 'startPool(uint256,uint256)')],
      owner
    )
  })

  it("can't set a pool with mismatched base", async () => {
    await expect(strategy.setNextPool(badPool.address, series2Id)).to.be.revertedWith('Mismatched base')
  })

  it("can't set a pool with mismatched seriesId", async () => {
    await expect(strategy.setNextPool(pool1.address, series2Id)).to.be.revertedWith('Mismatched seriesId')
  })

  it("can't start with a pool if next pool not set", async () => {
    await expect(strategy.startPool(0, MAX)).to.be.revertedWith('Next pool not set')
  })

  it('sets next pool', async () => {
    await expect(strategy.setNextPool(pool1.address, series1Id)).to.emit(strategy, 'NextPoolSet')

    expect(await strategy.nextPool()).to.equal(pool1.address)
    expect(await strategy.nextSeriesId()).to.equal(series1Id)
  })

  describe('with next pool set', async () => {
    beforeEach(async () => {
      await strategy.setNextPool(pool1.address, series1Id)
    })

    it("can't start with a pool if no funds are present", async () => {
      await expect(strategy.startPool(0, MAX)).to.be.revertedWith('No funds to start with')
    })

    it("can't start with a pool if minimum ratio not met", async () => {
      // Skew the pool
      await fyToken1.mint(pool1.address, WAD.mul(100000))
      await pool1.sync()

      // Mint strategy tokens
      await base.mint(strategy.address, WAD)
      const minRatio = (await base.balanceOf(pool1.address)).mul(WAD).div(await fyToken1.balanceOf(pool1.address))
      await fyToken1.mint(pool1.address, WAD)
      await pool1.sync()
      await expect(strategy.startPool(minRatio, MAX)).to.be.revertedWith('Pool: Reserves ratio changed')
    })

    it("can't start with a pool if maximum ratio exceeded", async () => {
      // Skew the pool
      await fyToken1.mint(pool1.address, WAD.mul(100000))
      await pool1.sync()

      // Mint strategy tokens
      await base.mint(strategy.address, WAD)
      const maxRatio = (await base.balanceOf(pool1.address)).mul(WAD).div(await fyToken1.balanceOf(pool1.address))
      await base.mint(pool1.address, WAD)
      await pool1.sync()
      await expect(strategy.startPool(0, maxRatio)).to.be.revertedWith('Pool: Reserves ratio changed')
    })

    it('starts with next pool - zero fyToken balance', async () => {
      await base.mint(strategy.address, WAD)
      await expect(strategy.startPool(0, MAX)).to.emit(strategy, 'PoolStarted')

      expect(await strategy.pool()).to.equal(pool1.address)
      expect(await strategy.fyToken()).to.equal(fyToken1.address)
      expect(await strategy.seriesId()).to.equal(series1Id)

      expect(await strategy.nextPool()).to.equal(ZERO_ADDRESS)
      expect(await strategy.nextSeriesId()).to.equal(ZERO_BYTES6)
    })

    it('starts with next pool - sets and deletes pool variables', async () => {
      // Skew the pool
      await fyToken1.mint(pool1.address, WAD.mul(100000))
      await pool1.sync()

      // Mint strategy tokens
      await base.mint(strategy.address, WAD)
      await expect(strategy.startPool(0, MAX)).to.emit(strategy, 'PoolStarted')

      expect(await strategy.pool()).to.equal(pool1.address)
      expect(await strategy.fyToken()).to.equal(fyToken1.address)
      expect(await strategy.seriesId()).to.equal(series1Id)

      expect(await strategy.nextPool()).to.equal(ZERO_ADDRESS)
      expect(await strategy.nextSeriesId()).to.equal(ZERO_BYTES6)
    })

    it('starts with next pool - borrows and mints', async () => {
      // Skew the pool
      await fyToken1.mint(pool1.address, WAD.mul(100000))
      await pool1.sync()

      // Mint strategy tokens
      const poolBaseBefore = await base.balanceOf(pool1.address)
      const poolFYTokenBefore = await fyToken1.balanceOf(pool1.address)
      const poolSupplyBefore = await pool1.totalSupply()

      await base.mint(strategy.address, WAD)
      await expect(strategy.startPool(0, MAX)).to.emit(strategy, 'PoolStarted')

      const poolBaseAdded = (await base.balanceOf(pool1.address)).sub(poolBaseBefore)
      const poolFYTokenAdded = (await fyToken1.balanceOf(pool1.address)).sub(poolFYTokenBefore)

      expect(poolBaseAdded.add(poolFYTokenAdded)).to.equal(WAD.sub(1)) // The strategy used all the funds, except one wei for rounding
      expect(await base.balanceOf(strategy.address)).to.equal(1) // The strategy remained with the one wei from rounding

      expect(await pool1.balanceOf(strategy.address)).to.equal((await pool1.totalSupply()).sub(poolSupplyBefore)) // The strategy received the LP tokens

      const poolBaseCached = (await pool1.getCache())[0]
      const poolFYTokenCached = (await pool1.getCache())[1]
      expect(poolBaseCached).to.equal(await pool1.getBaseBalance()) // The pool used all the received funds to mint
      almostEqual(poolFYTokenCached, await pool1.getFYTokenBalance(), BigNumber.from(10)) // The pool used all the received funds to mint (minus rounding in single-digit wei)

      expect(await pool1.balanceOf(strategy.address)).to.equal(await strategy.cached())
      expect(await strategy.balanceOf(owner)).to.equal(await strategy.totalSupply())

      // Sanity check
      expect(await pool1.balanceOf(strategy.address)).not.equal(BigNumber.from(0))
      expect(await strategy.totalSupply()).not.equal(BigNumber.from(0))
    })

    describe('with a pool started', async () => {
      beforeEach(async () => {
        await fyToken1.mint(pool1.address, WAD.mul(100000))
        await fyToken2.mint(pool2.address, WAD.mul(100000))
        await pool1.sync()
        await pool2.sync()

        await base.mint(strategy.address, WAD.mul(1000))
        await strategy.startPool(0, MAX)
      })

      it("can't start another pool if the current is still active", async () => {
        await expect(strategy.startPool(0, MAX)).to.be.revertedWith('Pool selected')
      })

      it('mints strategy tokens', async () => {
        const poolRatio = WAD.mul(await base.balanceOf(pool1.address)).div(await fyToken1.balanceOf(pool1.address))
        const poolSupplyBefore = await pool1.totalSupply()
        const strategyReservesBefore = await pool1.balanceOf(strategy.address)
        const strategySupplyBefore = await strategy.totalSupply()

        // Mint some LP tokens, and leave them in the strategy
        await base.mint(pool1.address, WAD.mul(poolRatio))
        await fyToken1.mint(pool1.address, WAD)
        await pool1.mint(strategy.address, ZERO_ADDRESS, 0, MAX)

        await expect(strategy.mint(user1)).to.emit(strategy, 'Transfer')

        const lpMinted = (await pool1.totalSupply()).sub(poolSupplyBefore)
        const strategyMinted = (await strategy.totalSupply()).sub(strategySupplyBefore)
        expect(await strategy.cached()).to.equal(strategyReservesBefore.add(lpMinted))
        expect(await strategy.balanceOf(user1)).to.equal(strategyMinted)

        expect(WAD.mul(lpMinted).div(strategyReservesBefore)).to.equal(
          WAD.mul(strategyMinted).div(strategySupplyBefore)
        )

        // Sanity check
        expect(lpMinted).not.equal(BigNumber.from(0))
        expect(strategyMinted).not.equal(BigNumber.from(0))
      })

      it('burns strategy tokens', async () => {
        const strategyReservesBefore = await pool1.balanceOf(strategy.address)
        const strategySupplyBefore = await strategy.totalSupply()
        const strategyBalance = await strategy.balanceOf(owner)
        const strategyBurnt = strategyBalance.div(2)

        await strategy.transfer(strategy.address, strategyBurnt)

        await expect(strategy.burn(user1)).to.emit(strategy, 'Transfer')

        const lpObtained = strategyReservesBefore.sub(await pool1.balanceOf(strategy.address))
        expect(await strategy.cached()).to.equal(strategyReservesBefore.sub(lpObtained))
        expect(await pool1.balanceOf(user1)).to.equal(lpObtained)

        expect(WAD.mul(strategyBurnt).div(strategySupplyBefore)).to.equal(
          WAD.mul(lpObtained).div(strategyReservesBefore)
        )

        // Sanity check
        expect(lpObtained).not.equal(BigNumber.from(0))
      })

      it("can't end pool before maturity", async () => {
        await expect(strategy.endPool()).to.be.revertedWith('Only after maturity')
      })

      describe('once the pool reaches maturity', async () => {
        beforeEach(async () => {
          await strategy.setNextPool(pool2.address, series2Id)

          snapshotId = await ethers.provider.send('evm_snapshot', [])
          await ethers.provider.send('evm_mine', [maturity1])
        })

        afterEach(async () => {
          await ethers.provider.send('evm_revert', [snapshotId])
        })

        it('ends the pool - sets and deletes pool variables', async () => {
          await expect(strategy.endPool()).to.emit(strategy, 'PoolEnded')

          // Clear up
          expect(await strategy.pool()).to.equal(ZERO_ADDRESS)
          expect(await strategy.fyToken()).to.equal(ZERO_ADDRESS)
          expect(await strategy.seriesId()).to.equal(ZERO_BYTES6)
          expect(await strategy.cached()).to.equal(0)
        })

        it('ends the pool - redeems fyToken', async () => {
          // Make sure the pool returns more fyToken than it was borrowed
          await fyToken1.mint(pool1.address, WAD.mul(100000))
          await pool1.sync()

          await expect(strategy.endPool()).to.emit(strategy, 'PoolEnded')

          expect(await fyToken1.balanceOf(strategy.address)).to.equal(0)
        })

        it('ends the pool - repays with underlying', async () => {
          // Make sure the pool returns less fyToken than it was borrowed
          await base.mint(pool1.address, WAD.mul(1000000))
          await pool1.sync()

          await expect(strategy.endPool()).to.emit(strategy, 'PoolEnded')
        })

        describe('with no active pools', async () => {
          beforeEach(async () => {
            await strategy.endPool()
          })

          it('burns strategy tokens for base', async () => {
            const strategyReservesBefore = await base.balanceOf(strategy.address)
            const strategySupplyBefore = await strategy.totalSupply()
            const strategyBalance = await strategy.balanceOf(owner)
            const strategyBurnt = strategyBalance.div(2)

            await strategy.transfer(strategy.address, strategyBurnt)

            await expect(strategy.burnForBase(user1)).to.emit(strategy, 'Transfer')

            const baseObtained = strategyReservesBefore.sub(await base.balanceOf(strategy.address))
            expect(await base.balanceOf(user1)).to.equal(baseObtained)

            almostEqual(
              WAD.mul(strategyBurnt).div(strategySupplyBefore),
              WAD.mul(baseObtained).div(strategyReservesBefore),
              BigNumber.from(10)
            )

            // Sanity check
            expect(baseObtained).not.equal(BigNumber.from(0))
          })
        })
      })
    })
  })
})
