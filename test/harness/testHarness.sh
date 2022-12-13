#!/bin/bash
# Loop through the following addresses, and run the StrategyHarness.t.sol tests for each one.
MAINNET_STRATEGIES=(\
  0xEA7577bE7C29FbD8246FE69408bf4Bc7b6668d2a\ 
  0xCc28081d668677007FCDafbCFfD132B69a44F6f1\ 
  0xa6c77A07786d0F40540bB72059905b357cF81881\ 
  0x7CA19022b0e371BFB545E3e91c0AEa4A3DBB9C91\ 
)

ARBITRUM_STRATEGIES=(\
)

export CI=false
export RPC="HARNESS"
export NETWORK="MAINNET"
export MOCK=false

for STRATEGY_ in ${MAINNET_STRATEGIES[@]}; do
  echo $STRATEGY_
  STRATEGY=$STRATEGY_ forge test --match-path test/harness/OrchestrationHarness.t.sol $1
#  STRATEGY=$STRATEGY_ forge test --match-path test/harness/RewardsHarness.t.sol $1
#  STRATEGY=$STRATEGY_ forge test --match-path test/harness/StrategyHarness.t.sol $1
done