# Security review of Strategy.sol V2 for Yield

[View at source](https://hackmd.io/7YB8QorOSs-nAAaz_f8EbQ)

## Review Summary

From Strategy.sol natspec:

> The Strategy contract allows liquidity providers to provide liquidity in yieldspace pool tokens and receive strategy tokens that represent a stake in a YieldSpace pool contract.
>
>Upon maturity, the strategy can `divest` from the mature pool, becoming a proportional ownership underlying vault. When not invested, the strategy can `invest` into a Pool using all its underlying.

The Strategy.sol contract has a reduced attack surface as most of the external functions are permissiond and/or restricted by current state through the use of a state machine.

The [feat/strategy-pool-only](https://github.com/yieldprotocol/strategy-v2/pull/34) branch of the [strategy-v2](https://github.com/yieldprotocol/strategy-v2) repo was reviewed during the period 28-Nov-22 to 07-Dec-22 by devtooligan for a cumulative total of 35 hours.

**No critical or high impact issues were found. Two (2) medium impact findings, and one (1) low were reported.**


## Scope
The review was based on commit [6bb7c7f](https://github.com/yieldprotocol/strategy-v2/pull/34/commits/6bb7c7f73340537053c6a147b207b91139741c4f) and focused primarily on Strategy.sol, StrategyMigrator.sol and ERC20Rewards.sol.

The goal of the review was to identify potential vulnerabilities in the code. Additionally, code quality improvements, readability, and best practices were considered.

Gas optimizations were **not** a significant part of this review although a couple of basic optimizations are referenced.

## Findings

### Medium impact findings

#### 1. Calling `restart()` without transferring in base can brick the contract (Medium)
If `eject()` is called and there is a revert when calling `burn()` on the pool, all of the strategy's LP tokens are transferred to the caller and the state is transitioned to `DRAINED`.

From the `DRAINED` state, [restart()](https://github.com/yieldprotocol/strategy-v2/pull/34/files#diff-3e804d467472e49fe8afea1899d96f26655f3ecd641555a801abcea4f12af598R280-R288) can be called. This function sets `cached` to the current balance of base found in the contract, and it transitions the state to `DIVESTED`. Some amount of base tokens are expected to be transferred in prior to calling `restart()`, but there is no explicit check for that.

If `restart()` is called when the contract's base balance is 0, then `cached` will be set to 0 and the contract will become unusable. `mintDivested()` and `invest()` will revert because `cached` is zero and the contract will be stuck in the `DRAINED` state, stranding the Strategy tokens like seeds out of soil.

##### Impact
During normal operations `eject()` is not called, and when it is called, it will not always transition to `DRAINED`.  For that reason, and also because `restart()` is permissioned, the impact of this is assessed at **Medium**

##### Recommendation
Add a check to `restart()` to ensure some base is transferred in:
```solidity
    require((cached = baseIn = base.balanceOf(address(this))) > 0);
```


##### Developer response:
[Fixed](https://github.com/yieldprotocol/strategy-v2/pull/35/commits/219d19ef9603b46f26bb19c99a9fa73976ede612).

##### Reviewer response:
Change reviewed. No issues noted.

-----------------------------

#### 2. `invest()` is vulnerable to a DoS attack (Medium)
When `invest()` is called, base is transferred to an initialized pool and LP tokens are minted. There is a [check in the logic](https://github.com/yieldprotocol/strategy-v2/pull/34/files#diff-3e804d467472e49fe8afea1899d96f26655f3ecd641555a801abcea4f12af598R140) that will cause a revert if the pool contract has any fyTokens.

##### Impact
An attacker could front run the call to `invest()` and sell or transfer any amount of fyToken to the pool. This would cause `invest()` to revert and prevent the strategy from investing in the pool. `invest()` is a permissioned function that the developers intend to be preceded by a call to `pool.init()` in a single transaction. As such the impact of this is assessed at **Medium**.

##### Recommendation
Consider having the strategy call `init()` on the pool instead of `mint()`. `Pool.init()` is a permissioned fn (an additional auth role would have to be granted) which cannot be frontrun in this way.

```diff
+++ b/contracts/Strategy.sol
@@ -138,11 +138,11 @@ contract Strategy {
 
         require(base == pool_.base(), "Mismatched base");
-        require(pool_.getFYTokenBalance() - pool_.totalSupply() == 0, "Only with no fyToken in the pool");
 
         // Initialize the pool
         base.safeTransfer(address(pool_), cached_);
-        (,, poolTokensObtained) = pool_.mint(address(this), address(this), 0, type(uint256).max);
+        (,, poolTokensObtained) = pool_.init(address(this));
```

##### Developer response:
[Fixed](https://github.com/yieldprotocol/strategy-v2/pull/35/commits/ec6d66503941834f810f7115afab7aa7d2565182).

##### Reviewer response:
Change reviewed. No issues noted.


-----------------------------
### Low impact findings
#### 3. `RewardsPerToken` can be lost if a new rewards program is set (Low)
If `setRewards()` is called then `rewardsPerToken` values are overwritten. If `_updateRewardsPerToken()` hadn't been called since before the previous rewards program ended, this would result in an understated `_accumulated` value causing a permanent loss of rewards. 

##### Impact
This seems unlikely because that would mean there had been no activity since some time during the previous rewards program.  Furthermore, this could be mitigated if `claim()` was called for any user prior to calling `setRewards()`  As such, the impact is assessed at **low**.

#### Recommendation
Call `_updateRewardsPerToken()` as the first step in `setRewards()`.

##### Developer response:
[Fixed](https://github.com/yieldprotocol/yield-utils-v2/pull/64/commits/4fb7591e14d92af174378ea9f786a908d3b7834d).

##### Reviewer response:
Change reviewed. No issues noted.



-----------------------------

### Informational and Gas Optimization findings


#### 4. Refactor `_transition()` (Informational)
Consider simplifying `_transition()` by eliminating the `pool_` arg from `_transition()` as it is only used by the `INVESTED` state.  This would only require inlining logic in one place. 

Leaving the `delete` logic in this fn seems appropriate and it's helpful to easily see which vars get deleted in each state.

Consider adding a final else that reverts if `target` is not one of the four available target states. This would prevent the contract from ever getting into a bad state in the future. (Since there is no transition to `DEPLOYED`, it does not need to be included here.)

```diff
@@ -69,11 +69,7 @@ contract Strategy {
     function _transition(State target, IPool pool_) internal {
-        if (target == State.INVESTED) {
-            pool = pool_;
-            fyToken = IFYToken(address(pool_.fyToken()));
-            maturity = pool_.maturity();
-        } else if (target == State.DIVESTED) {
+        if (target == State.DIVESTED) {
             delete fyToken;
             delete maturity;
             delete pool;
         } else if (target == State.DRAINED) {
             delete maturity;
             delete pool;
-        }
+        } else if (target != State.INVESTED) {
+            // pool, fyToken, and maturity must be set outside of this fn when transitioning to INVESTED
+            revert("Unknown state");
+        }
         state = target;
     }
```

And in `invest()`:
```diff
@@ -145,6 +145,11 @@ contract Strategy {
         cached = poolTokensObtained;

+        // Update state variables
+        fyToken = fyToken_;
+        maturity = pool_.maturity();
+        pool = pool_;
+
         _transition(State.INVESTED, pool_);
         emit Invested(address(pool_), cached_, poolTokensObtained);
     }
```

##### Developer response:
[Fixed](https://github.com/yieldprotocol/strategy-v2/pull/35/commits/c5dc6d314213259f57d477a7d94c82a136ada6e0).

##### Reviewer response:
Change reviewed. No issues noted.



-----------------------------

#### 5. Refactor and move the mock pool `mint()` function (Informational/Gas Optimization)
[`mint(address, address, uint256, uint256)`](https://github.com/yieldprotocol/strategy-v2/pull/34/files#diff-3e804d467472e49fe8afea1899d96f26655f3ecd641555a801abcea4f12af598R93)

Instead of `mint` calling `this.init()` as an external function, consider making an internal `init` and calling that.  This could also be achieved by making `init()` public so an internal fn is created by the compiler.  Making this change would also require adding the `isState(State.DEPLOYED)` modifier.  Additionally, the return value `fyToken` does not need to be explicitly set to 0 as that is the default, but leaving a comment to that effect would be helpful.


Also consider moving this function to `StrategyMigrator.sol`.  This function is related to the migrator and could also be confused with the `Strategy.mint(address to)` in the main `Strategy.sol` contract.  This could lead to mistakes or introduce bugs in future versions.

Finally, consider adding Natspec explaining that we are intentionally ignoring the arguments and describing the return values.

```diff
@@ -88,22 +88,28 @@ contract Strategy is AccessControl, ERC20Rewards, StrategyMigrator { // TODO: I'
 
     // ----------------------- INVEST & DIVEST --------------------------- //
 
-    /// @dev Mock pool mint hooked up to initialize the strategy and return strategy tokens.
+    /// @notice Mock pool mint called by a strategy when trying to migrate.
+    /// @dev Will initialize the strategy and return strategy tokens.
+    /// It is expected that base has been transferred in, but no fyTokens
+    /// @return baseIn Amount of base tokens found in contract
+    /// @return fyTokenIn This is always returned as 0 since theyh aren't used
+    /// @return minted Amount of strategy tokens minted from base tokens which is the same as baseIn
     function mint(address, address, uint256, uint256)
         external
         override
+        isState(State.DEPLOYED)
         auth
         returns (uint256 baseIn, uint256 fyTokenIn, uint256 minted)
     {
-        baseIn = minted = this.init(msg.sender);
-        fyTokenIn = 0;
+        baseIn = minted = init(msg.sender);
+        // fyTokenIn = 0;  return 0 for fyToken here which is the default value and does not need to be assigned
     }
 
     /// @dev Mint the first strategy tokens, without investing
     /// @param to Recipient for the strategy tokens
     /// @return minted Amount of strategy tokens minted from base tokens
     function init(address to)
-        external
+        public
```

##### Developer response:
[Fixed](https://github.com/yieldprotocol/strategy-v2/pull/35/commits/d67d5a2b585e24c95a00faf908f24060a119efef).

##### Reviewer response:
Change reviewed. Didn't move `mint()` to `StrategyMigrator.sol`, but that's fine. No other issues noted.


-----------------------------
#### 6. State var `cached` used for both base tokens and pool tokens (Informational)
[Context](https://github.com/yieldprotocol/strategy-v2/pull/34/files#diff-3e804d467472e49fe8afea1899d96f26655f3ecd641555a801abcea4f12af598R42)

This could lead to mistakes or introduce bugs in future versions.  Consider using separate variables for `baseCached` and `poolTokensCached`.

##### Developer response:
[Fixed](https://github.com/yieldprotocol/strategy-v2/pull/35/commits/944c6689f81811fea2acf7a165b0ca5c45f47cbe).

##### Reviewer response:
Change reviewed. No issues noted.


-----------------------------


#### 7. Unnecessary deletes in `init()` (Informational/Gas Optimization)

It is unnecessary to delete `maturity` and `pool`
```diff
@@ -145,6 +145,11 @@ contract Strategy {
         // Clear state variables from a potential migration
         delete fyToken;
-        delete maturity;
-        delete pool;
```

##### Developer response:
[Fixed](https://github.com/yieldprotocol/strategy-v2/pull/35/commits/a4899e0c7e190a8af0c9a37750f452f58c9dbf13).

##### Reviewer response:
Change reviewed. No issues noted.


-----------------------------

#### 8. Check return values in `_burnPoolTokens` (Informational)
Consider checking the base and fyToken balances against the return values from `Pool.burn()`. Considering that this function will potentially be called when there is a problem with the pool contract, we cannot be sure the return values are valid.

```diff
@@ -236,8 +238,8 @@ contract Strategy is AccessControl, ERC20Rewards, StrategyMigrator { // TODO: I'
         (, baseReceived, fyTokenReceived) = pool_.burn(address(this), address(this), 0, type(uint256).max);
+        require(base.balanceOf(address(this)) >= baseReceived);
+        require(fyToken.balanceOf(address(this)) >= fyTokenReceived);
```

Also, consider removing the leading undescore in `_burnPoolTokens` as this convention is normally used with internal functions.  Even though in this case it is being used like an internal function, it may cause confusion in the future.

##### Developer response:
[Fixed](https://github.com/yieldprotocol/strategy-v2/pull/35/commits/9e6a33d10de2ed74c9b338037792d65d3af02203).

##### Reviewer response:
Change reviewed. No issues noted.

-----------------------------

#### 9. State vars shadowed by constructor args (Informational)
[Context](https://github.com/yieldprotocol/strategy-v2/pull/34/files#diff-3e804d467472e49fe8afea1899d96f26655f3ecd641555a801abcea4f12af598R45-R46)

Consider changing constructor arg variable names:
```diff
@@ -42,8 +42,8 @@ contract Strategy is AccessControl, ERC20Rewards, StrategyMigrator {
 
-    constructor(string memory name, string memory symbol, IFYToken fyToken_)
-        ERC20Rewards(name, symbol, SafeERC20Namer.tokenDecimals(address(fyToken_)))
+    constructor(string memory name_, string memory symbol_, IFYToken fyToken_)
+        ERC20Rewards(name_, symbol_, SafeERC20Namer.tokenDecimals(address(fyToken_)))
```
##### Developer response:
[Fixed](https://github.com/yieldprotocol/strategy-v2/pull/35/commits/409bece50823f8a48fbe4720ed2770a724dad867).

##### Reviewer response:
Change reviewed. No issues noted.


-----------------------------

#### 10. Typo in NatSpec for `restart()` (Informational)
```
/// @dev If we ejected the pool...
```

This should read "If we drained the strategy..."

##### Developer response:
[Fixed](https://github.com/yieldprotocol/strategy-v2/pull/35/commits/571eb36b2b1d883c88e8c699d924ab375e9a77ec).

##### Reviewer response:
Change reviewed. No issues noted.

