# Strategy for YieldSpace Pools

#### DISCLAIMER: Please do not use in production without taking the appropriate steps to ensure maximum security. This code is provided as-is, with no guarantees of any kind.

---

Strategy.sol (Strategy v2) works as a proportional ownership vault for YieldSpace Pool tokens, with a second state in which it holds a given underlying instead.

YieldSpace pools mature and stop producing additional returns. To overcome this, Strategy can `divest` from its current pool and transition to an state where it is a proportional ownership vault for the underlying token. When divested, the Strategy can `invest` in another pool, as long as the pool only has reserves of underlying and the underlying of the new pool matches the underlying of the Strategy.

This repo uses the [Foundry development tool](https://github.com/gakonst/foundry) ecosystem. Tests are written in Solidity and use Foundry [cheatcodes](https://github.com/gakonst/foundry/tree/master/forge#cheat-codes).

This repo includes:

- the [latest ABDK Math64x64 library](https://github.com/abdk-consulting/abdk-libraries-solidity/blob/master/ABDKMath64x64.sol), useful for managing large numbers with high precision in a gas optimized way
- custom math libraries ([YieldMath.sol](https://github.com/yieldprotocol/yieldspace-tv/blob/update-yieldmath/src/YieldMath.sol) and [Exp64x64.sol](https://github.com/yieldprotocol/yieldspace-tv/blob/update-yieldmath/src/Exp64x64.sol)) originally written by ABDK for Yield which have now been adapted for the new math
- Strategy.sol contract based on the original but now incorporating ejection features
- StrategyMigrator.sol contract to migrate users from Strategy v1 to Strategy v2
- Foundry unit tests

Additional notes:

As this repo is still under development, these smart contracts have not yet been deployed.

Detailed documentation can be found in the [Yield docs](docs.yieldprotocol.com).

## Install

### Pre Requisites

Before running any command, [be sure Foundry is installed](https://github.com/gakonst/foundry#installation).

### Setup

```
git clone git@github.com:yieldprotocol/strategy-v2.git
cd strategy-v2
forge update
```

### Test

Compile and test the smart contracts with Forge:

```
forge test
```

## Security

TODO: Update this with audit details.

In developing the code in this repository we have set the highest bar possible for security. `yieldspace-tv` has been audited by [ABDK Consulting](https://www.abdk.consulting/) and the report can be found [here](https://github.com/yieldprotocol/yieldspace-tv/blob/main/audit/ABDK_Yield_yieldspace_tv_v_1_0.pdf).

We have also used fuzzing tests for the Pool and YieldMath contracts, allowing us to find edge cases and vulnerabilities that we would have missed otherwise.

## Bug Bounty

Note: Not valid until audit.

Yield is offering bounties for bugs disclosed through [Immunefi](https://immunefi.com/bounty/yieldprotocol). The bounty reward is up to $500,000, depending on severity. Please include full details of the vulnerability and steps/code to reproduce. We ask that you permit us time to review and remediate any findings before public disclosure.

## Contributing

If you have a contribution to make, please reach us out on Discord and we will consider it for a future release or product.
