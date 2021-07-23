import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signer-with-address'

import { constants, id } from '@yield-protocol/utils-v2'
const { WAD, MAX256 } = constants
const MAX = MAX256


import ERC20MockArtifact from '../artifacts/contracts/mocks/ERC20Mock.sol/ERC20Mock.json'
import ERC20RewardsMockArtifact from '../artifacts/contracts/mocks/ERC20RewardsMock.sol/ERC20RewardsMock.json'
import { ERC20Mock as ERC20 } from '../typechain/ERC20Mock'
import { ERC20RewardsMock as ERC20Rewards } from '../typechain/ERC20RewardsMock'

import { BigNumber } from 'ethers'

import { ethers, waffle } from 'hardhat'
import { expect } from 'chai'
const { deployContract, loadFixture } = waffle

function almostEqual(x: BigNumber, y: BigNumber, p: BigNumber) {
  // Check that abs(x - y) < p:
  const diff = x.gt(y) ? BigNumber.from(x).sub(y) : BigNumber.from(y).sub(x) // Not sure why I have to convert x and y to BigNumber
  expect(diff.div(p)).to.eq(0) // Hack to avoid silly conversions. BigNumber truncates decimals off.
}

describe('ERC20Rewards', async function () {
  this.timeout(0)

  let ownerAcc: SignerWithAddress
  let owner: string
  let user1: string
  let user2: string

  let governance: ERC20;
  let rewards: ERC20Rewards;

  async function fixture() { } // For now we just use this to snapshot and revert the state of the blockchain

  before(async () => {
    await loadFixture(fixture) // This snapshots the blockchain as a side effect
    const signers = await ethers.getSigners()
    ownerAcc = signers[0]
    owner = ownerAcc.address
    user1 = signers[1].address
    user2 = signers[2].address
  })

  after(async () => {
    await loadFixture(fixture) // We advance the time to test maturity features, this rolls it back after the tests
  })

  beforeEach(async () => {
    governance = (await deployContract(ownerAcc, ERC20MockArtifact, ["Governance Token", "GOV", 18])) as ERC20
    rewards = (await deployContract(ownerAcc, ERC20RewardsMockArtifact, ["Token with rewards", "REW", 18])) as ERC20Rewards

    await rewards.mint(user1, WAD);

    await rewards.grantRoles(
      [id('setRewards(address,uint32,uint32,uint128,uint128)')],
      owner
    )
  })

  it('sets a rewards token and schedule', async () => {
    expect(await rewards.setRewards(governance.address, 1, 2, 3, 4))
    .to.emit(rewards, 'RewardsSet')
    .withArgs(governance.address, 1, 2, 3, 4)

    expect(await rewards.rewardToken()).to.equal(governance.address)
    const rewardPeriod = await rewards.rewardPeriod()
    expect(rewardPeriod.start).to.equal(1)
    expect(rewardPeriod.end).to.equal(2)

    const rewardEmissions = await rewards.rewardEmissions()
    expect(rewardEmissions.rate).to.equal(3)
    expect(rewardEmissions.available).to.equal(4)
  })

  describe('with a rewards schedule', async () => {
    beforeEach(async () => {
      const { timestamp } = await ethers.provider.getBlock('latest')
      await rewards.setRewards(governance.address, timestamp, timestamp + 2000000, 1, 1000000)
      await ethers.provider.send('evm_mine', [timestamp + 1000000])
    })

    it('calculates the claimable period', async () => {
      almostEqual(BigNumber.from(await rewards.claimablePeriod(user1)), BigNumber.from(1000000), BigNumber.from(10))
    })

    it('calculates the claimable amount', async () => {
      const period = BigNumber.from(await rewards.claimablePeriod(user1))
      expect(await rewards.claimableAmount(user1)).to.equal(period)
    })
  
    it('allows to claim', async () => {
    })

    it('minting doesn\'t increase the claimable', async () => {
      await rewards.mint(user2, WAD)
      let period = await rewards.claimablePeriod(user2)

      const { timestamp } = await ethers.provider.getBlock('latest')
      almostEqual(BigNumber.from(await rewards.claimableAmount(user2)), BigNumber.from(0), BigNumber.from(10))
    })

    it('receiving doesn\'t increase the claimable', async () => {
    })
  })
})
