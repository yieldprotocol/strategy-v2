# Introduction
Strategy.sol (Strategy v2) works as a proportional ownership vault for YieldSpace Pool tokens, with a second state in which it holds a given underlying instead.

YieldSpace pools mature and stop producing additional returns. To overcome this, Strategy can `divest` from its current pool and transition to an state where it is a proportional ownership vault for the underlying token. When divested, the Strategy can `invest` in another pool, as long as the pool only has reserves of underlying and the underlying of the new pool matches the underlying of the Strategy.

Users can `mint` Strategy tokens by providing the appropriate pool tokens when invested, or by providing underlying when divested.

Users can `burn` Strategy tokens and obtain pool tokens when invested, or obtain underlying when divested.

## Initialization
To initialize the Strategy, underlying must be provided. An amount of Strategy tokens equal to the underlying provided will be minted. This is a permissioned method to avoid initialization attacks. The Strategy moves to a divested state after initialization.

## Investing
Investing is only possible in pools with no fyToken. We now that YieldSpace pool return a number of pool tokens equal to the underlying provided in this scenario. Investing is permissioned to avoid having the Strategy funds sent to an arbitrary contract by an attacker. The Strategy moves to an invested state after initialization.

## Divesting
When invested, the main way to divest is to wait until the pool matures. In that situation, the pool tokens held by the Strategy are burned, any fyToken received are redeemed, and the Strategy moves to a divested state. This is not a permissioned method.

## Ejecting
When invested, we can also divest before maturity, by ejecting. Ejecting burns all pool tokens and stores the resulting underlying and fyToken in the Strategy. The most common state after ejecting is Ejected, but if no fyToken are obtained, the state achieved would be Divested.

A Strategy in an ejected state will hold fyToken, and will sell them at face value. Buyers of fyToken at face value will incur a loss before maturity, and this is intended as a way to recapitalize the Strategy in the emergency that led to the ejection. Once all fyToken have been sold, the Strategy will transition to a Divested state.

## Draining
In the ejection process there is the chance that the pool would not allow burning tokens, perhaps because of an attack or underlying issue. If the pool token burn reverts, the Strategy will transfer all pool tokens to the caller, so that an external process can solve the situation. The Strategy will remain in a Drained state until `restore` is called, where there is an opportunity to recapitalize the Strategy with underlying. Restoring a Strategy is a permissioned method, and transitions the Strategy to a Divested state.

Leaving the Strategy in a Drained state until is recapitalized avoids users getting diluted while the Strategy has a value of zero.

## StrategyMigration
Strategy inherits from StrategyMigrator, which allows it to pose as a YieldSpace pool and receive all funds from a Strategy v1, sending an equal amount of Strategy v2 tokens to Strategy v1. This allows for a seamless upgrade where tokens of Strategy v1 represent a proportional stake in the Strategy v2 that took the funds.

## State Machine


                                                              ┌───────────┐
                                                              │           │
                                                              │           │
                                       ┌──────────────────────┤  Drained  │◄────┐
                                       │       restore        │           │     │
                                       │                      │           │     │
                                       │                      └───────────┘     │
                                       ▼                                        │
  ┌────────────┐                ┌────────────┐                ┌───────────┐     │
  │            │                │            │                │           │     │
  │            │                │            │                │           │     │
  │  Deployed  ├───────────────►│  Divested  │◄───────────────┤  Ejected  │◄────┤
  │            │     init       │            │   buyFYToken   │           │     │
  │            │                │            │                │           │     │
  └────────────┘                └──┬─────────┘                └───────────┘     │
                                   │      ▲                                     │
                                   │      │                                     │
                                   │      │                                     │
                            invest │      │ divest (after maturity)             │
                                   │      │                                     │
                                   │      │                                     │
                                   ▼      │                                     │
                                ┌─────────┴──┐                                  │
                                │            │                                  │
                                │            ├──────────────────────────────────┘
                                │  Invested  │             eject
                                │            │
                                │            │
                                └────────────┘
