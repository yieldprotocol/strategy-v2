import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signer-with-address'

import { constants, id } from '@yield-protocol/utils-v2'
const { WAD, MAX256 } = constants
const MAX = MAX256

import StrategyInternalsArtifact from '../artifacts/contracts/mocks/StrategyInternals.sol/StrategyInternals.json'
import VaultMockArtifact from '../artifacts/contracts/mocks/VaultMock.sol/VaultMock.json'
import PoolMockArtifact from '../artifacts/contracts/mocks/PoolMock.sol/PoolMock.json'
import ERC20MockArtifact from '../artifacts/contracts/mocks/ERC20Mock.sol/ERC20Mock.json'

import { ERC20Mock as ERC20, ERC20Mock } from '../typechain/ERC20Mock'
import { StrategyInternals as Strategy } from '../typechain/StrategyInternals'
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

describe('Strategy - Investing', async function () {
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

  let vaultId: string

  const ZERO_ADDRESS = '0x' + '0'.repeat(40)

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
    await base.mint(pool1.address, WAD.mul(900000))
    await base.mint(pool2.address, WAD.mul(900000))
    await fyToken1.mint(pool1.address, WAD.mul(100000))
    await fyToken2.mint(pool2.address, WAD.mul(100000))
    await pool1.mint(owner, true, 0)
    await pool2.mint(owner, true, 0)
    await pool1.sync()
    await pool2.sync()

    strategy = (await deployContract(ownerAcc, StrategyInternalsArtifact, [
      'Strategy Token',
      'STR',
      18,
      vault.address,
      base.address,
      baseId,
    ])) as Strategy

    await strategy.grantRoles(
      [
        id('setPools(address[],bytes6[])'),
        id('setLimits(uint80,uint80,uint80)'),
        id('setPoolDeviationRate(uint256)'),
        id('init(address)'),
        id('swap()'),
      ],
      owner
    )

    // Init strategy
    await base.mint(strategy.address, WAD)
    await strategy.init(owner)
    await strategy.setPools([pool1.address, pool2.address], [series1Id, series2Id])
    await strategy.swap()
    vaultId = await strategy.vaultId()
  })

  it('sets up testing environment', async () => {})

  it('mints and burns', async () => {
    await base.mint(strategy.address, WAD)
    await expect(strategy.mint(user1)).to.emit(strategy, 'Transfer')

    // WAD base went to the buffer
    expect(await strategy.buffer()).to.equal(WAD.mul(2))

    // The strategy value is equal to its buffer, so the user received as many strategy tokens as base he put in
    almostEqual(await strategy.balanceOf(user1), WAD, BigNumber.from(1000000))

    await strategy.connect(user1Acc).transfer(strategy.address, await strategy.balanceOf(user1))
    await expect(strategy.burn(user1)).to.emit(strategy, 'Transfer')

    // The strategy value is equal to its buffer, so the user received as many base tokens as strategy tokens burnt
    almostEqual(await base.balanceOf(user1), WAD, BigNumber.from(1000000))

    // The buffer decreased by the amount given out
    expect((await strategy.buffer()).add(await base.balanceOf(user1))).to.equal(WAD.mul(2))
  })

  it('sets pool deviation rate', async () => {
    await expect(strategy.setPoolDeviationRate(WAD.div(10))) // 10% / s
      .to.emit(strategy, 'PoolDeviationRateSet')

    expect(await strategy.poolDeviationRate()).to.equal(WAD.div(10))
  })

  it('checks pool deviation', async () => {
    expect(await strategy.callStatic.poolDeviated()).to.be.false // The strategy cache is in sync with the pool at init
    let cacheTimestamp = (await strategy.poolCache()).timestamp

    // We are going to slightly increase the fyToken reserves in the pool, increasing the rate
    await fyToken1.mint(pool1.address, WAD.mul(100))
    await base.mint(pool1.address, WAD.mul(10)) // Also increase the base, to check the strategy caches the value
    await pool1.sync()
    expect(await strategy.callStatic.poolDeviated()).to.be.false // Still within limits
    await strategy.poolDeviated() // Update the cache

    expect((await strategy.poolCache()).fyToken).to.equal(WAD.mul(100100))
    expect((await strategy.poolCache()).base).to.equal(WAD.mul(900010))
    expect((await strategy.poolCache()).timestamp).to.not.equal(cacheTimestamp)

    // We are going to double the fyToken reserves in the pool, doubling the rate
    await fyToken1.mint(pool1.address, WAD.mul(100000))
    await pool1.sync()

    expect(await strategy.callStatic.poolDeviated()).to.be.true
  })

  it('sets buffer limits', async () => {
    await expect(strategy.setLimits(WAD.mul(5), WAD.mul(10), WAD.mul(15))).to.emit(strategy, 'LimitsSet')

    expect((await strategy.limits()).low).to.equal(WAD.mul(5))
    expect((await strategy.limits()).mid).to.equal(WAD.mul(10))
    expect((await strategy.limits()).high).to.equal(WAD.mul(15))
  })

  describe('with investing enabled', async () => {
    beforeEach(async () => {
      await base.mint(strategy.address, WAD.mul(99))
      await strategy.mint(owner)
      await strategy.setLimits(WAD.mul(5), WAD.mul(10), WAD.mul(15))
    })

    it('borrows and invests', async () => {
      await expect(strategy.borrowAndInvest(WAD)).to.emit(strategy, 'Invest')

      expect(await base.balanceOf(strategy.address)).to.equal(WAD.mul(99))
      almostEqual((await vault.balances(vaultId)).art, WAD.div(10), BigNumber.from(1000000))
      almostEqual(await pool1.fyTokenReserves(), await fyToken1.balanceOf(pool1.address), BigNumber.from(1000000))
    })

    describe('with an amount invested', async () => {
      beforeEach(async () => {
        await strategy.borrowAndInvest(WAD)
      })

      it('divests and repays', async () => {
        const lpTokens = await pool1.balanceOf(strategy.address)
        await expect(strategy.divestAndRepay(lpTokens)).to.emit(strategy, 'Divest')

        almostEqual(await base.balanceOf(strategy.address), WAD.mul(100), BigNumber.from(1000000))
        almostEqual((await vault.balances(vaultId)).art, BigNumber.from(0), BigNumber.from(1000000))
      })
    })
  })
})
