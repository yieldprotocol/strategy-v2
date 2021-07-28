// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.1;

import "@yield-protocol/utils-v2/contracts/access/AccessControl.sol";
import "@yield-protocol/utils-v2/contracts/token/TransferHelper.sol";
import "@yield-protocol/utils-v2/contracts/token/IERC20.sol";
import "@yield-protocol/yieldspace-interfaces/IPool.sol";
import "@yield-protocol/vault-interfaces/DataTypes.sol";
import "./ERC20Rewards.sol";

interface ILadle {
    function joins(bytes6) external view returns (address);
    function cauldron() external view returns (ICauldron);
    function build(bytes6 seriesId, bytes6 ilkId, uint8 salt) external returns (bytes12 vaultId, DataTypes.Vault memory vault);
    function destroy(bytes12 vaultId) external;
    function pour(bytes12 vaultId, address to, int128 ink, int128 art) external;
}

interface ICauldron {
    function assets(bytes6) external view returns (address);
    function series(bytes6) external view returns (DataTypes.Series memory);
    function balances(bytes12) external view returns (DataTypes.Balances memory);
}

/* library CastU256U128 {
    /// @dev Safely cast an uint256 to an uint128
    function u128(uint256 x) internal pure returns (uint128 y) {
        require (x <= type(uint128).max, "Cast overflow");
        y = uint128(x);
    }
} */

library CastU128I128 {
    /// @dev Safely cast an uint128 to an int128
    function i128(uint128 x) internal pure returns (int128 y) {
        require (x <= uint128(type(int128).max), "Cast overflow");
        y = int128(x);
    }
}

/// @dev The Pool contract exchanges base for fyToken at a price defined by a specific formula.
contract Strategy is AccessControl, ERC20Rewards {
    using CastU256U128 for uint256; // Inherited from ERC20Rewards
    using CastU128I128 for uint128;

    event YieldSet(ILadle ladle, ICauldron cauldron);
    event TokenJoinReset(address join);
    event TokenIdSet(bytes6 id);
    event LimitsSet(uint80 low, uint80 mid, uint80 high);
    event PoolSwapped(address pool, bytes6 seriesId);

    struct Limits {                              // Buffer limits, in 1e18 units
        uint80 low;                              // If the buffer would drop below this level, it fills to mid 
        uint80 mid;                              // Target buffer level
        uint80 high;                             // If the buffer would drop below this level, it drains to mid
    }

    IERC20 public immutable base;                // Base token for this strategy
    bytes6 public baseId;                        // Identifier for the base token in Yieldv2
    address public baseJoin;                     // Yield v2 Join to deposit token when borrowing
    ILadle public ladle;                         // Gateway to the Yield v2 Collateralized Debt Engine
    ICauldron public cauldron;                   // Accounts in the Yield v2 Collateralized Debt Engine
    Limits public limits;                        // Limits for unallocated funds
    IPool public pool;                           // Pool that this strategy invests in
    IFYToken public fyToken;                     // Current fyToken for this strategy
    uint256 public buffer;                       // Unallocated base token in this strategy
    bytes12 public vaultId;                      // Vault used to borrow fyToken

    constructor(ILadle ladle_, IERC20 base_, bytes6 baseId_)
        ERC20Rewards(
            "Yield LP Strategy",
            "fyLPSTRAT",
            18
        )
    { 
        require(
            ladle_.cauldron().assets(baseId_) == address(base_),
            "Mismatched baseId"
        );
        base = base_;
        baseId = baseId_;
        baseJoin = ladle_.joins(baseId_);

        ladle = ladle_;
        cauldron = ladle_.cauldron();

        limits = Limits({
            low: 0,
            mid: 1,
            high: type(uint80).max
        });
    }

    /// @dev Set a new Ladle and Cauldron
    /// @notice Use with extreme caution, only for Ladle replacements
    function setYield(ILadle ladle_, ICauldron cauldron_)
        public
        auth
    {
        ladle = ladle_;
        cauldron = ladle_.cauldron();
        emit YieldSet(ladle_, cauldron_);
    }

    /// @dev Set a new base token id
    /// @notice Use with extreme caution, only for token reconfigurations in Cauldron
    function setTokenId(bytes6 baseId_)
        public
        auth
    {
        require(
            ladle.cauldron().assets(baseId_) == address(base),
            "Mismatched baseId"
        );
        baseId = baseId_;
        emit TokenIdSet(baseId_);
    }

    /// @dev Reset the base token join
    /// @notice Use with extreme caution, only for Join replacements
    function resetTokenJoin()
        public
        auth
    {
        baseJoin = ladle.joins(baseId);
        emit TokenJoinReset(baseJoin);
    }

    /// @dev Set the buffer limits
    function setLimits(uint80 low_, uint80 mid_, uint80 high_)
        public
        auth
    {
        require (
            low_ <= mid_ && mid_ <= high_,
            "Inconsistent buffer limits"
        );

        limits = Limits({
            low: low_,
            mid: mid_,
            high: high_
        });
        emit LimitsSet(low_, mid_, high_);
    }

    /// @dev Swap funds to a new pool (auth)
    /// @notice First the strategy must be fully divested from the old pool.
    /// @notice First the strategy must repaid all debts from the old series.
    /// TODO: Set an array of upcoming pools, and swap to the next one in the array
    function swap(IPool pool_, bytes6 seriesId_)
        public
        auth
    {
        require (
            fyToken.maturity() >= uint32(block.timestamp),
            "Only after maturity"
        );

        // Divest fully, all debt in the vault should be repaid and collateral withdrawn into the buffer
        // With a bit of extra code, the collateral could be left in the vault
        _divestAndRepayAndRedeem(pool.balanceOf(address(this)), 0, 0);

        // Swap the series (fyToken and pool). 
        DataTypes.Series memory series = cauldron.series(seriesId_);
        require(
            series.fyToken == pool_.fyToken(),
            "Mismatched seriesId"
        );

        // Replace the vault. We could also use tweak.
        if (vaultId != bytes12(0)) ladle.destroy(vaultId); // This will revert unless the vault has been emptied
        (vaultId, ) = ladle.build(seriesId_, baseId, 0);

        pool = pool_;
        fyToken = pool_.fyToken();

        // Invest, leaving the buffer amount
        _borrowAndInvest(buffer - limits.mid, 0);
        emit PoolSwapped(address(pool_), seriesId_);
    }

    /// @dev Value of the strategy in base token terms
    function strategyValue()
        external view
        returns (uint256 strategy)
    {
        strategy = _strategyValue();
    }

    /// @dev Value of the strategy in base token terms
    function _strategyValue()
        internal view
        returns (uint256 strategy)
    {
        //  - Can we use 1 fyToken = 1 base for this purpose? It overvalues the value of the strategy.
        //  - If so lpTokens/lpSupply * (lpReserves + lpFYReserves) + unallocated = value_in_token(strategy)
        strategy = (base.balanceOf(address(pool)) + fyToken.balanceOf(address(pool)) * 
            pool.balanceOf(address(this))) / pool.totalSupply() + buffer;
    }

    /// @dev Mint strategy tokens. The underlying tokens that the user contributes need to have been transferred previously.
    function mint(address to)
        public
        returns (uint256 minted)
    {
        // Find value of strategy
        // Find value of deposit. Straightforward if done in base
        // minted = supply * deposit/strategy
        uint256 deposit = base.balanceOf(address(this)) - buffer;
        minted = _totalSupply - deposit / _strategyValue();
        
        // Invest if the deposit would lead to `buffer` over `limits.high`
        if (buffer + deposit > limits.high) {
            _drainBuffer(deposit, 0); // TODO: Set slippage as a twap
        }
        buffer += deposit;

        _mint(to, minted);
    }

    /// @dev Burn strategy tokens to withdraw funds. Replenish the available funds limits if below levels
    function burn(address to)
        public
        returns (uint256 withdrawal)
    {
        // Find value of strategy
        // Find value of burnt tokens. Straightforward if withdrawal done in base
        // strategy * burnt/supply = withdrawal
        uint256 toBurn = _balanceOf[address(this)];
        withdrawal = _strategyValue() * toBurn / _totalSupply;

        // Divest if the withdrawal would lead to `buffer` below `limits.low`
        if (withdrawal > buffer || buffer - withdrawal < limits.low) {
            _fillBuffer(withdrawal, 0, 0); // TODO: Set slippage as a twap
        }
        buffer -= withdrawal;
        _burn(address(this), toBurn);
        base.transfer(to, withdrawal);
    }

    /// @dev Drain the available funds buffer to the mid point
    function drainBuffer(uint256 min)
        public
        auth
        returns (uint256 tokenInvested)
    {
        tokenInvested = _drainBuffer(0, min);
    }

    /// @dev Fill the available funds buffer to the mid point
    function fillBuffer(uint256 minTokenReceived, uint256 minFYTokenReceived)
        public
        auth
        returns (uint256 tokenDivested, uint256 fyTokenDivested)
    {
        (tokenDivested, fyTokenDivested) = _fillBuffer(0, minTokenReceived, minFYTokenReceived);
    }

    /// @dev Drain the available funds buffer, after an hypothetical deposit
    function _drainBuffer(uint256 deposit, uint256 min)
        internal
        returns (uint256 tokenInvested)
    {
        require(
            buffer + deposit > limits.high,
            "Buffer not high enough"
        );

        // Find out how much of the buffer we need to invest so that buffer + deposit = buffer.mid
        uint256 toInvest = deposit + buffer - limits.mid;
        // Borrow and invest
        tokenInvested = _borrowAndInvest(toInvest, min);
    }

    /// @dev Fill the available funds buffer to the mid point, after an hypothetical withdrawal
    function _fillBuffer(uint256 withdrawal, uint256 minTokenReceived, uint256 minFYTokenReceived)
        internal
        returns (uint256 tokenDivested, uint256 fyTokenDivested)
    {
        require(
            buffer - withdrawal < limits.low,
            "Buffer not low enough"
        );

        // Find out how many lp tokens we need to burn so that buffer - withdrawal = buffer.mid
        uint256 toObtain = limits.mid + withdrawal - buffer;
        // Find value of lp tokens in base terms, scaled up for precision
        uint256 lpValueUp = (1e18 * (base.balanceOf(address(pool)) + fyToken.balanceOf(address(pool)))) / pool.totalSupply();
        uint256 toDivest = (1e18 * toObtain) / lpValueUp;
        // Divest and repay
        (tokenDivested, fyTokenDivested) = _divestAndRepayAndSell(toDivest, minTokenReceived, minFYTokenReceived);
    }

    /// @dev Invest available funds from the strategy into YieldSpace LP - Borrow and mint
    function _borrowAndInvest(uint256 tokenInvested, uint256 min)
        internal
        returns (uint256 minted)
    {
        buffer -= tokenInvested;

        // Find pool proportion p = fyTokenReserves/tokenReserves
        uint256 proportion = 1e18 * fyToken.balanceOf(address(pool)) / base.balanceOf(address(pool));
        // Deposit (investment * p) base to borrow (investment * p) fyToken
        //   (investment * p) fyToken + (investment * (1 - p)) base = investment
        //   (investment * p) / ((investment * p) + (investment * (1 - p))) = p
        //   (investment * (1 - p)) / ((investment * p) + (investment * (1 - p))) = 1 - p
        uint256 fyTokenToPool = tokenInvested * proportion / 1e18;
        uint256 tokenToPool = tokenInvested - fyTokenToPool;

        base.transfer(baseJoin, fyTokenToPool);
        int128 fyTokenToPool_ = fyTokenToPool.u128().i128();
        ladle.pour(vaultId, address(pool), fyTokenToPool_, fyTokenToPool_);

        // Mint LP tokens with (investment * p) fyToken and (investment * (1 - p)) base
        base.transfer(address(pool), tokenToPool);
        (,, minted) = pool.mint(address(this), true, min);
    }

    /// @dev Divest from YieldSpace LP into available funds for the strategy - Burn and repay and sell
    function _divestAndRepayAndSell(uint256 lpBurnt, uint256 minTokenReceived, uint256 minFYTokenReceived)
        internal
        returns (uint256 tokenDivested, uint256 fyTokenDivested)
    {
        // Burn lpTokens
        pool.transfer(address(pool), lpBurnt);
        (, tokenDivested, fyTokenDivested) = pool.burn(address(this), minTokenReceived, minFYTokenReceived);
        
        // Repay with fyToken as much as possible
        uint256 debt = cauldron.balances(vaultId).art;
        uint256 toRepay = (debt >= fyTokenDivested) ? fyTokenDivested : debt;
        
        fyToken.transfer(address(fyToken), toRepay);
        int128 toRepay_ = toRepay.u128().i128();
        ladle.pour(vaultId, address(this), toRepay_, toRepay_);

        // Sell any surplus fyToken (which will fill the buffer again :/ )
        // TODO: Branch out to keep the surplus fyToken into a buffer, which will be redeemed on swapping pools
        uint128 toSell = (fyTokenDivested - toRepay).u128();
        if (toSell > 0) {
            fyToken.transfer(address(pool), toSell);
            buffer += pool.sellFYToken(address(this), 0); // TODO: Set slippage as a twap
        }
        buffer += tokenDivested;  
    }


    /// @dev Divest from YieldSpace LP into available funds for the strategy - Burn and repay and redeem
    function _divestAndRepayAndRedeem(uint256 lpBurnt, uint256 minTokenReceived, uint256 minFYTokenReceived)
        internal
        returns (uint256 tokenDivested, uint256 fyTokenDivested)
    {
        // Burn lpTokens
        pool.transfer(address(pool), lpBurnt);
        (, tokenDivested, fyTokenDivested) = pool.burn(address(this), minTokenReceived, minFYTokenReceived);
        
        // Repay with fyToken as much as possible
        uint256 debt = cauldron.balances(vaultId).art;
        uint256 toRepay = (debt >= fyTokenDivested) ? fyTokenDivested : debt;
        
        fyToken.transfer(address(fyToken), toRepay);
        int128 toRepay_ = toRepay.u128().i128();
        ladle.pour(vaultId, address(this), toRepay_, toRepay_);

        // Sell any surplus fyToken (which will fill the buffer again :/ )
        // TODO: Branch out to keep the surplus fyToken into a buffer, which will be redeemed on swapping pools
        uint128 toRedeem = (fyTokenDivested - toRepay).u128();
        if (toRedeem > 0) {
            fyToken.transfer(address(fyToken), toRedeem);
            buffer += fyToken.redeem(address(this), toRedeem);
        }
        buffer += tokenDivested;  
    }
}
