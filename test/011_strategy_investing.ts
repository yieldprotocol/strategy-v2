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

    series1Id = await vault.callStatic.addSeries(maturity1)
    await vault.addSeries(maturity1)
    fyToken1 = await ethers.getContractAt('FYTokenMock', (await vault.series(series1Id)).fyToken, ownerAcc) as unknown as FYTokenMock

    series2Id = await vault.callStatic.addSeries(maturity2)
    await vault.addSeries(maturity2)
    fyToken2 = await ethers.getContractAt('FYTokenMock', (await vault.series(series2Id)).fyToken, ownerAcc) as unknown as FYTokenMock

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

    strategy = (await deployContract(ownerAcc, StrategyArtifact, ['Strategy Token', 'STR', 18, vault.address, base.address, baseId])) as Strategy

    await strategy.grantRoles([
      id('init(address)'),
      id('setPools(address[],bytes6[])'),
      id('swap()'),
    ], owner)

    // Init strategy
    await base.mint(strategy.address, WAD)
    await strategy.init(owner)
    await strategy.setPools([pool1.address, pool2.address], [series1Id, series2Id])
    await strategy.swap()
  })

  it('sets up testing environment', async () => {})

  it('mints and burns', async () => {
    await base.mint(strategy.address, WAD)
    await expect(strategy.mint(user1))
      .to.emit(strategy, 'Transfer')

    // WAD base went to the buffer
    expect(await strategy.buffer()).to.equal(WAD.mul(2))

    // The strategy value is equal to its buffer, so the user received as many strategy tokens as base he put in
    almostEqual(await strategy.balanceOf(user1), WAD, BigNumber.from(1000000))

    await strategy.connect(user1Acc).transfer(strategy.address, await strategy.balanceOf(user1))
    await expect(strategy.burn(user1))
      .to.emit(strategy, 'Transfer')

    // The strategy value is equal to its buffer, so the user received as many base tokens as strategy tokens burnt
    almostEqual(await base.balanceOf(user1), WAD, BigNumber.from(1000000))

    // The buffer decreased by the amount given out
    expect((await strategy.buffer()).add(await base.balanceOf(user1))).to.equal(WAD.mul(2))
  })
})
