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
  let user1Acc: SignerWithAddress
  let user2: string

  let governance: ERC20;
  let rewards: ERC20Rewards;

  async function fixture() { } // For now we just use this to snapshot and revert the state of the blockchain

  before(async () => {
    await loadFixture(fixture) // This snapshots the blockchain as a side effect
    const signers = await ethers.getSigners()
    ownerAcc = signers[0]
    owner = ownerAcc.address
    user1Acc = signers[1]
    user1 = user1Acc.address
    user2 = signers[2].address
  })

  after(async () => {
    await loadFixture(fixture) // We advance the time to test maturity features, this rolls it back after the tests
  })

  beforeEach(async () => {
    governance = (await deployContract(ownerAcc, ERC20MockArtifact, ["Governance Token", "GOV", 18])) as ERC20
    rewards = (await deployContract(ownerAcc, ERC20RewardsMockArtifact, ["Token with rewards", "REW", 18])) as ERC20Rewards

    await rewards.grantRoles(
      [
        id('setRewards(address,uint32,uint32,uint96)'),
        id('activateRewards(uint32)')
      ],
      owner
    )
  })

  it('sets a rewards token and schedule', async () => {
    const start = 1;
    const end = 2;
    const rate = 3;
    const scheme = start
    expect(await rewards.setRewards(governance.address, start, end, rate))
    .to.emit(rewards, 'RewardsSet')
    .withArgs(governance.address, start, end, rate)

    expect(await rewards.rewardsToken(scheme)).to.equal(governance.address)
    const rewardsPeriod = await rewards.rewardsPeriod(scheme)
    expect(rewardsPeriod.start).to.equal(start)
    expect(rewardsPeriod.end).to.equal(end)
    expect((await rewards.rewardsPerToken(scheme)).rate).to.equal(rate)
  })

  describe('with a rewards schedule', async () => {
    let snapshotId: string
    let timestamp: number
    let start: number
    let scheme: number
    let length: number
    let mid: number
    let end: number
    let rate: BigNumber
    
    before(async () => {
      ({ timestamp } = await ethers.provider.getBlock('latest'))
      start = timestamp + 1000000
      length = 2000000
      mid = start + length / 2
      end = start + length
      rate = WAD.div(length)
      scheme = start
    })
    
    beforeEach(async () => {
      await rewards.setRewards(governance.address, start, end, rate)
      await governance.mint(rewards.address, WAD)
      await rewards.mint(user1, WAD) // So that total supply is not zero
      await rewards.activateRewards(scheme)
    })

    /* describe('before the schedule', async () => {
      it('calculates the claimable period', async () => {
        almostEqual(BigNumber.from(await rewards.claimablePeriod(user1)), BigNumber.from(0), BigNumber.from(10))
      })
    }) */

    describe('during the schedule', async () => {
      beforeEach(async () => {
        snapshotId = await ethers.provider.send('evm_snapshot', []);
        await ethers.provider.send('evm_mine', [mid])
      })

      afterEach(async () => {
        await ethers.provider.send('evm_revert', [snapshotId])
      })

      it('updates rewards per token on mint', async () => {
        ({ timestamp } = await ethers.provider.getBlock('latest'))
        await rewards.mint(user1, WAD)
        almostEqual(
          (await rewards.rewardsPerToken(0)).accumulated,
          BigNumber.from(timestamp - start).mul(rate), //  ... * 1e18 / totalSupply = ... * WAD / WAD
          BigNumber.from(timestamp - start).mul(rate).div(100000)
        )
      })

      it('updates user rewards on mint', async () => {
        ({ timestamp } = await ethers.provider.getBlock('latest'))
        await rewards.mint(user1, WAD)
        const rewardsPerToken = (await rewards.rewardsPerToken(0)).accumulated
        almostEqual(
          (await rewards.rewards(user1, 0)).accumulated,
          rewardsPerToken, //  (... - paidRewardPerToken[user]) * userBalance / 1e18 = (... - 0) * WAD / WAD
          rewardsPerToken.div(100000)
        )
      })

      /* it('minting doesn\'t change the claimable', async () => {
        await rewards.mint(user2, WAD)
        almostEqual(BigNumber.from(await rewards.claimableAmount(user2)), BigNumber.from(0), BigNumber.from(10))
      })

      it('receiving doesn\'t increase the claimable', async () => {
        await rewards.connect(user1Acc).transfer(user2, WAD)
        const period = BigNumber.from(await rewards.claimablePeriod(user2))
        almostEqual(BigNumber.from(await rewards.claimableAmount(user2)), BigNumber.from(0), BigNumber.from(10))
      })

      it('supply increase doesn\'t change the claimable', async () => {
        await rewards.mint(user2, WAD)
        const period = BigNumber.from(await rewards.claimablePeriod(user1))
        almostEqual(BigNumber.from(await rewards.claimableAmount(user1)), BigNumber.from(period), BigNumber.from(10))
      })

      it('allows to claim', async () => {
        let period = BigNumber.from(await rewards.claimablePeriod(user1))
        expect(await rewards.connect(user1Acc).claim(user1))
          .to.emit(rewards, 'Claimed')
          .withArgs(user1, await governance.balanceOf(user1))
        
        // Claims an amount, in this case since rate is 1 the claimed amount is equal to the claimable period
        almostEqual(BigNumber.from(await governance.balanceOf(user1)), BigNumber.from(period), BigNumber.from(10))

        // After claiming, the claimable amount is deducted
        period = BigNumber.from(await rewards.claimablePeriod(user1))
        almostEqual(BigNumber.from(await rewards.claimableAmount(user2)), BigNumber.from(0), BigNumber.from(10))
      }) */
    })

    /* describe('after the schedule', async () => {
      beforeEach(async () => {
        snapshotId = await ethers.provider.send('evm_snapshot', []);
        await ethers.provider.send('evm_mine', [end + 10])
      })

      afterEach(async () => {
        await ethers.provider.send('evm_revert', [snapshotId])
      })

      it('calculates the claimable period', async () => {
        expect(await rewards.claimablePeriod(user1)).to.equal(length)
      })
    }) */
  })
})
