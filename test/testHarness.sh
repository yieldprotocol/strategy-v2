#!/bin/bash
# Loop through the following addresses, and run the StrategyHarness.t.sol tests for each one.
STRATEGIES=(\
  "0x8e79F205960da611Fe3cb6D474b3Ec1C1B72Da39"\
  "0xef6Bd5EBf6CBB631d32f7C5b6D60E197afbc9C38"\
  "0x13Ba156CbeE7b9e0FC9AEE8310E8b26DDC93392f")

export NETWORK="ARBITRUM"
export MOCK=false

for strategy in ${STRATEGIES[@]}; do
  STRATEGY=$strategy forge test --match-path test/StrategyHarness.t.sol
#  STRATEGY=$strategy forge test --match-path test/RewardsHarness.t.sol
done