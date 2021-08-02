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

describe('Strategy', async function () {
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

  let baseId: string
  let series1Id: string
  let series2Id: string

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
    base = await ethers.getContractAt('ERC20Mock', await vault.base(), ownerAcc) as unknown as ERC20Mock
    baseId = await vault.baseId()
    series1Id = await vault.callStatic.addSeries()
    await vault.addSeries()
    fyToken1 = await ethers.getContractAt('FYTokenMock', (await vault.series(series1Id)).fyToken, ownerAcc) as unknown as FYTokenMock
    series2Id = await vault.callStatic.addSeries()
    await vault.addSeries()
    fyToken2 = await ethers.getContractAt('FYTokenMock', (await vault.series(series2Id)).fyToken, ownerAcc) as unknown as FYTokenMock

    // Set up YieldSpace
    pool1 = (await deployContract(ownerAcc, PoolMockArtifact, [base.address, fyToken1.address])) as PoolMock
    pool2 = (await deployContract(ownerAcc, PoolMockArtifact, [base.address, fyToken2.address])) as PoolMock

    strategy = (await deployContract(ownerAcc, StrategyArtifact, ['Strategy Token', 'STR', 18, vault.address, base.address, baseId])) as Strategy

    await strategy.grantRoles([
      id('init(address)'),
      id('setPools(address[],bytes6[])')
    ], owner)
  })

  it('sets up testing environment', async () => {})

  it('inits up', async () => {
    await base.mint(strategy.address, WAD)
    await expect(strategy.init(user1))
      .to.emit(strategy, 'Transfer')
    expect(await strategy.balanceOf(user1)).to.equal(WAD)
  })

  describe('once initialized', async () => {
    beforeEach(async () => {
      await base.mint(strategy.address, WAD)
      await strategy.init(owner)
    })

    it('can\'t initialize again', async () => {
      await base.mint(strategy.address, WAD)
      await expect(strategy.init(user1))
        .to.be.revertedWith('Already initialized')
    })

    it('can\'t set pools with mismatched seriesId', async () => {
      await expect(strategy.setPools(
        [pool1.address, pool2.address],
        [series1Id, series1Id],
      ))
        .to.be.revertedWith('Mismatched seriesId')
    })

    it('sets a pool queue', async () => {
      await expect(strategy.setPools(
        [pool1.address, pool2.address],
        [series1Id, series2Id],
      )).to.emit(strategy, 'PoolsSet')

      expect(await strategy.poolCounter()).to.equal(MAX)
      expect(await strategy.pools(0)).to.equal(pool1.address)
      expect(await strategy.pools(1)).to.equal(pool2.address)
      expect(await strategy.seriesIds(0)).to.equal(series1Id)
      expect(await strategy.seriesIds(1)).to.equal(series2Id)
    })
  })
})