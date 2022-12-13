#!/bin/bash
# Loop through the following addresses, and run the StrategyHarness.t.sol tests for each one.
MAINNET_STRATEGIES=(\
  0xF730Ed8cB07925279e6D1807886c690d352FF7B8\
  0xA689fd1999775C16b9a912248187e4a7454a154a\
  0xC468301Fe4395BFc7aDbacfd27c10760DB9B5a3f\
  0xB53c25cbbc21379287e5e31426268958C2c68182\
)

ARBITRUM_STRATEGIES=(\
)

export CI=false
export RPC="TENDERLY"
export NETWORK="MAINNET"
export MOCK=false

for STRATEGY_ in ${MAINNET_STRATEGIES[@]}; do
  echo $STRATEGY_
  STRATEGY=$STRATEGY_ forge test --match-path test/harness/RewardsHarness.t.sol $1
  STRATEGY=$STRATEGY_ forge test --match-path test/harness/StrategyHarness.t.sol $1
done