#!/bin/bash
# Loop through the following addresses, and run the StrategyHarness.t.sol tests for each one.
MAINNET_STRATEGIES=(\
  0xb268E2C85861B74ec75fe728Ae40D9A2308AD9Bb\ 
  0x9ca2a34ea52bc1264D399aCa042c0e83091FEECe\ 
  0x5dd6DcAE25dFfa0D46A04C9d99b4875044289fB2\ 
  0x4B010fA49E8b673D0682CDeFCF7834328076748C\ 
  0x428e229aC5BC52a2e07c379B2F486fefeFd674b1\ 
  0xF708005ceE17b2c5Fe1a01591E32ad6183A12EaE\ 
  0x6aD806aEE38dE9E17c5Fd549543979E97d8EF5D6\ 
  0xC9Eda8086680514D0F5d7982CA4393DdcBa63dFD\ 
  0x30E8f93467eC752356245347DCB8063891A2e933\ 
  0xC21977a5f119952091F6D05dEd5C961Ea7b7d569\ 
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
  STRATEGY=$STRATEGY_ forge test --match-path test/harness/RewardsHarness.t.sol $1
  STRATEGY=$STRATEGY_ forge test --match-path test/harness/StrategyHarness.t.sol $1
done