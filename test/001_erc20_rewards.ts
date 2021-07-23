import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signer-with-address'

import { constants, id } from '@yield-protocol/utils-v2'
const { WAD, MAX256 } = constants
const MAX = MAX256


import ERC20MockArtifact from '../artifacts/contracts/mocks/ERC20Mock.sol/ERC20Mock.json'
import ERC20RewardsArtifact from '../artifacts/contracts/ERC20Rewards.sol/ERC20Rewards.json'
import { ERC20Mock } from '../typechain/ERC20Mock'
import { ERC20Rewards } from '../typechain/ERC20Rewards'

import { BigNumber } from 'ethers'

import { ethers, waffle } from 'hardhat'
import { expect } from 'chai'
const { deployContract } = waffle

describe('ERC20Rewards', async function () {
  this.timeout(0)

  let ownerAcc: SignerWithAddress
  let owner: string

  let governance: ERC20Mock;
  let rewards: ERC20Rewards;

  before(async () => {
    const signers = await ethers.getSigners()
    ownerAcc = signers[0]
    owner = ownerAcc.address
  })

  beforeEach(async () => {
    governance = (await deployContract(ownerAcc, ERC20MockArtifact, ["Governance Token", "GOV", 18])) as ERC20Mock
    rewards = (await deployContract(ownerAcc, ERC20RewardsArtifact, ["Token with rewards", "REW", 18])) as ERC20Rewards

    await rewards.grantRoles(
      [id('setRewards(address,uint192,uint32,uint32)')],
      owner
    )
  })

  it('sets a rewards token and schedule', async () => {
    expect(await rewards.setRewards(governance.address, 1, 2, 3))
    .to.emit(rewards, 'RewardsSet')
    .withArgs(governance.address, 1, 2, 3)
    const schedule = await rewards.schedule()
    expect(await rewards.reward()).to.equal(governance.address)
    expect(schedule.rate).to.equal(1)
    expect(schedule.start).to.equal(2)
    expect(schedule.end).to.equal(3)
  })

  describe('with a rewards schedule', async () => {
    beforeEach(async () => {
      
    })

    it('calculates the claimable period', async () => {
    })

    it('calculates the claimable amount', async () => {
    })
  
    it('allows to claim', async () => {
    })

    it('minting doesn\'t increase the claimable', async () => {
    })

    it('receiving doesn\'t increase the claimable', async () => {
    })
  })
})
