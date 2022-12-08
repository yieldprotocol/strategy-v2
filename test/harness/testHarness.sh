#!/bin/bash
# Loop through the following addresses, and run the StrategyHarness.t.sol tests for each one.
STRATEGIES=(\
  0xe507E8f1366DE968Da91707306756A3DeF9C4d09\ 
  0x91e1e2CD17F0418a6b2079637898397a66026337\ 
  0x7CEde4B5aC739677A0F677F1B0C9884355F2EdCb\ 
)

export RPC="TENDERLY"
export NETWORK="ARBITRUM"
export MOCK=false

for strategy in ${STRATEGIES[@]}; do
  STRATEGY=$strategy forge test --match-path test/harness/RewardsHarness.t.sol
  STRATEGY=$strategy forge test --match-path test/harness/StrategyHarness.t.sol
done