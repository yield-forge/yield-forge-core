// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ILiquidityAdapter} from "../interfaces/ILiquidityAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ICurveStableSwap
 * @notice Interface for Curve StableSwap pools (2 tokens)
 * @dev Curve uses different interfaces for different pool types.
 *      This is for plain/lending pools with 2 tokens.
 */
interface ICurveStableSwap {
    /// @notice Add liquidity to the pool
    /// @param amounts Array of token amounts to add [token0, token1]
    /// @param min_mint_amount Minimum LP tokens to receive
    /// @return LP tokens minted
    function add_liquidity(uint256[2] calldata amounts, uint256 min_mint_amount) external returns (uint256);

    /// @notice Remove liquidity from the pool
    /// @param _amount LP tokens to burn
    /// @param min_amounts Minimum amounts to receive [token0, token1]
    /// @return Amounts received [token0, token1]
    function remove_liquidity(uint256 _amount, uint256[2] calldata min_amounts) external returns (uint256[2] memory);

    /// @notice Get token at index
    function coins(uint256 i) external view returns (address);

    /// @notice Get token balance in pool
    function balances(uint256 i) external view returns (uint256);

    /// @notice Get LP token address (some pools)
    function lp_token() external view returns (address);

    /// @notice Get virtual price of LP token
    function get_virtual_price() external view returns (uint256);

    /// @notice Get fee (in 1e10 format)
    function fee() external view returns (uint256);
}

/**
 * @title ICurveGauge
 * @notice Interface for Curve Gauge (staking for CRV rewards)
 * @dev Gauges are where LP tokens are staked to earn CRV
 */
interface ICurveGauge {
    /// @notice Deposit LP tokens into gauge
    function deposit(uint256 _value) external;

    /// @notice Withdraw LP tokens from gauge
    function withdraw(uint256 _value) external;

    /// @notice Claim pending CRV rewards
    function claim_rewards() external;

    /// @notice Get claimable CRV for user
    function claimable_tokens(address user) external returns (uint256);

    /// @notice Get staked balance
    function balanceOf(address user) external view returns (uint256);

    /// @notice Get reward token at index
    function reward_tokens(uint256 i) external view returns (address);

    /// @notice Get number of reward tokens
    function reward_count() external view returns (uint256);

    /// @notice Get claimable reward for specific token
    function claimable_reward(address user, address token) external view returns (uint256);

    /// @notice LP token address
    function lp_token() external view returns (address);
}

/**
 * @title CurveAdapter
 * @author Yield Forge Team
 * @notice Adapter for Curve StableSwap pools
 * @dev Implements ILiquidityAdapter for Curve 2-token StableSwap pools
 *
 * ARCHITECTURE:
 * -------------
 * Curve has a different model than Uniswap:
 * - Liquidity represented by LP tokens (ERC20), not NFTs or pool state
 * - Yield comes from trading fees (auto-compounded in LP value)
 * - Additional yield from CRV rewards via Gauge staking
 *
 * POOL + GAUGE PATTERN:
 * ---------------------
 * For yield tokenization, we use both:
 * 1. Curve Pool: Where we add/remove liquidity
 * 2. Curve Gauge: Where we stake LP tokens for CRV rewards
 *
 * Flow:
 * - addLiquidity: pool.add_liquidity() → gauge.deposit()
 * - removeLiquidity: gauge.withdraw() → pool.remove_liquidity()
 * - collectYield: gauge.claim_rewards() → convert CRV to pool tokens
 *
 * LIQUIDITY REPRESENTATION:
 * -------------------------
 * Unlike Uniswap where liquidity is a mathematical value, Curve uses
 * LP tokens. We return LP token amount as "liquidity" value.
 *
 * PARAMS ENCODING:
 * ----------------
 * abi.encode(address curvePool, address gauge)
 *
 * YIELD TYPES:
 * ------------
 * 1. Trading fees: Auto-compounded into LP token value (captured on remove)
 * 2. CRV rewards: Collected from gauge via claim_rewards()
 *
 * For simplicity, this adapter:
 * - Returns trading fee yield as increase in LP token value (on redemption)
 * - Returns CRV rewards on collectYield() - caller must handle CRV token
 *
 * STABLESWAP ONLY:
 * ----------------
 * This adapter is designed for 2-token StableSwap pools.
 * CryptoSwap (volatile pairs) and 3+ token pools need different adapters.
 *
 * SECURITY:
 * ---------
 * - Only Diamond can call liquidity operations
 * - LP tokens are staked in gauge (held by this adapter)
 * - CRV rewards sent directly to recipient
 */
contract CurveAdapter is ILiquidityAdapter {
    using SafeERC20 for IERC20;

    // ============================================================
    //                        CONSTANTS
    // ============================================================

    /// @notice Protocol identifier for token naming
    string private constant PROTOCOL_ID = "CRV";

    // ============================================================
    //                     STATE VARIABLES
    // ============================================================

    /// @notice Diamond contract that can call this adapter
    address public immutable diamond;

    /// @notice CRV token address (for reward handling)
    address public immutable crvToken;

    // ============================================================
    //                         ERRORS
    // ============================================================

    /// @notice Gauge address is zero (no gauge configured)
    error NoGaugeConfigured();

    // ============================================================
    //                        EVENTS
    // ============================================================

    event CurveLiquidityAdded(
        address indexed pool, address indexed gauge, uint256 lpTokens, uint256 amount0, uint256 amount1
    );

    event CurveLiquidityRemoved(
        address indexed pool, address indexed gauge, uint256 lpTokens, uint256 amount0, uint256 amount1
    );

    event CurveYieldCollected(address indexed pool, address indexed gauge, uint256 crvAmount);

    // ============================================================
    //                       CONSTRUCTOR
    // ============================================================

    /**
     * @notice Initialize adapter
     * @param _diamond YieldForge Diamond address
     * @param _crvToken CRV token address
     */
    constructor(address _diamond, address _crvToken) {
        require(_diamond != address(0), "Zero diamond");
        require(_crvToken != address(0), "Zero CRV token");

        diamond = _diamond;
        crvToken = _crvToken;
    }

    // ============================================================
    //                        MODIFIERS
    // ============================================================

    modifier onlyDiamond() {
        if (msg.sender != diamond) revert UnauthorizedCaller();
        _;
    }

    // ============================================================
    //                   LIQUIDITY OPERATIONS
    // ============================================================

    /**
     * @notice Add liquidity to a Curve pool and stake LP in gauge
     * @dev Flow: approve → add_liquidity → approve LP → gauge.deposit
     *
     * IMPORTANT: Diamond must transfer tokens to this adapter before calling
     *
     * @param params Encoded as abi.encode(
     *                 address curvePool,
     *                 address gauge,
     *                 uint256 amount0,
     *                 uint256 amount1
     *               )
     * @return liquidity LP tokens received (used as liquidity measure)
     * @return amount0Used Actual token0 used
     * @return amount1Used Actual token1 used
     */
    function addLiquidity(bytes calldata params)
        external
        override
        onlyDiamond
        returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
    {
        // Decode parameters
        (address curvePool, address gauge, uint256 amount0, uint256 amount1) =
            abi.decode(params, (address, address, uint256, uint256));

        ICurveStableSwap pool = ICurveStableSwap(curvePool);
        ICurveGauge curveGauge = ICurveGauge(gauge);

        // Get tokens
        address token0 = pool.coins(0);
        address token1 = pool.coins(1);

        // Get LP token address from gauge
        address lpToken = curveGauge.lp_token();

        // Approve tokens to pool
        IERC20(token0).safeIncreaseAllowance(curvePool, amount0);
        IERC20(token1).safeIncreaseAllowance(curvePool, amount1);

        // Get balance before to calculate actual usage
        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));

        // Add liquidity to Curve pool
        // Returns LP tokens minted
        uint256 lpReceived = pool.add_liquidity(
            [amount0, amount1],
            0 // min_mint_amount = 0 (slippage handled by facet)
        );

        // Calculate actual amounts used
        amount0Used = balance0Before - IERC20(token0).balanceOf(address(this));
        amount1Used = balance1Before - IERC20(token1).balanceOf(address(this));

        // Stake LP tokens in gauge for CRV rewards
        IERC20(lpToken).safeIncreaseAllowance(gauge, lpReceived);
        curveGauge.deposit(lpReceived);

        // Return unused tokens to diamond
        uint256 remaining0 = IERC20(token0).balanceOf(address(this));
        uint256 remaining1 = IERC20(token1).balanceOf(address(this));

        if (remaining0 > 0) {
            IERC20(token0).safeTransfer(diamond, remaining0);
        }
        if (remaining1 > 0) {
            IERC20(token1).safeTransfer(diamond, remaining1);
        }

        // Use LP token amount as liquidity (fits in uint128 for reasonable amounts)
        liquidity = uint128(lpReceived);

        emit CurveLiquidityAdded(curvePool, gauge, lpReceived, amount0Used, amount1Used);
        emit LiquidityAdded(diamond, liquidity, amount0Used, amount1Used);
    }

    /**
     * @notice Remove liquidity from Curve pool
     * @dev Flow: gauge.withdraw → remove_liquidity → transfer tokens
     *
     * @param liquidity LP tokens to remove (matches addLiquidity return)
     * @param params Encoded pool and gauge addresses
     * @return amount0 Token0 received
     * @return amount1 Token1 received
     */
    function removeLiquidity(uint128 liquidity, bytes calldata params)
        external
        override
        onlyDiamond
        returns (uint256 amount0, uint256 amount1)
    {
        // Decode parameters
        (address curvePool, address gauge) = abi.decode(params, (address, address));

        ICurveStableSwap pool = ICurveStableSwap(curvePool);
        ICurveGauge curveGauge = ICurveGauge(gauge);

        // Withdraw LP tokens from gauge
        curveGauge.withdraw(uint256(liquidity));

        // Get LP token
        address lpToken = curveGauge.lp_token();

        // Approve LP tokens to pool (for removal)
        IERC20(lpToken).safeIncreaseAllowance(curvePool, uint256(liquidity));

        // Remove liquidity from Curve pool
        uint256[2] memory amounts = pool.remove_liquidity(
            uint256(liquidity),
            [uint256(0), uint256(0)] // min_amounts = 0 (slippage handled by facet)
        );

        amount0 = amounts[0];
        amount1 = amounts[1];

        // Transfer tokens to diamond
        address token0 = pool.coins(0);
        address token1 = pool.coins(1);

        if (amount0 > 0) {
            IERC20(token0).safeTransfer(diamond, amount0);
        }
        if (amount1 > 0) {
            IERC20(token1).safeTransfer(diamond, amount1);
        }

        emit CurveLiquidityRemoved(curvePool, gauge, uint256(liquidity), amount0, amount1);
        emit LiquidityRemoved(diamond, liquidity, amount0, amount1);
    }

    /**
     * @notice Collect CRV rewards from gauge
     * @dev Claims CRV and other reward tokens, sends to diamond
     *
     * NOTE: This only collects CRV rewards. Trading fees are auto-compounded
     * into LP token value and captured on remove_liquidity.
     *
     * For multi-reward gauges, this collects all reward tokens.
     * Caller must handle conversion of non-base tokens.
     *
     * @param params Encoded pool and gauge addresses
     * @return yield0 CRV tokens collected (returned as yield0)
     * @return yield1 Always 0 (Curve rewards are single-token)
     */
    function collectYield(bytes calldata params)
        external
        override
        onlyDiamond
        returns (uint256 yield0, uint256 yield1)
    {
        // Decode parameters
        (, address gauge) = abi.decode(params, (address, address));

        ICurveGauge curveGauge = ICurveGauge(gauge);

        // Get CRV balance before claim
        uint256 crvBefore = IERC20(crvToken).balanceOf(address(this));

        // Claim all rewards from gauge
        curveGauge.claim_rewards();

        // Calculate CRV received
        uint256 crvReceived = IERC20(crvToken).balanceOf(address(this)) - crvBefore;

        // Transfer CRV to diamond
        if (crvReceived > 0) {
            IERC20(crvToken).safeTransfer(diamond, crvReceived);
        }

        // Also collect any other reward tokens
        // Loop through reward tokens and transfer to diamond
        uint256 rewardCount = curveGauge.reward_count();
        for (uint256 i = 0; i < rewardCount; i++) {
            address rewardToken = curveGauge.reward_tokens(i);
            if (rewardToken != address(0) && rewardToken != crvToken) {
                uint256 balance = IERC20(rewardToken).balanceOf(address(this));
                if (balance > 0) {
                    IERC20(rewardToken).safeTransfer(diamond, balance);
                }
            }
        }

        // Return CRV as yield0, 0 as yield1
        // Caller must handle CRV → base token conversion if needed
        yield0 = crvReceived;
        yield1 = 0;

        emit CurveYieldCollected(address(0), gauge, crvReceived);
        emit YieldCollected(diamond, yield0, yield1);
    }

    // ============================================================
    //                      VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Get staked LP token balance (our position)
     * @param params Encoded pool and gauge addresses
     * @return liquidity Staked LP tokens
     */
    function getPositionLiquidity(bytes calldata params) external view override returns (uint128 liquidity) {
        (, address gauge) = abi.decode(params, (address, address));
        ICurveGauge curveGauge = ICurveGauge(gauge);

        uint256 staked = curveGauge.balanceOf(address(this));
        liquidity = uint128(staked);
    }

    /**
     * @notice Get pool tokens
     * @param params Encoded pool address
     * @return token0 First token
     * @return token1 Second token
     */
    function getPoolTokens(bytes calldata params) external view override returns (address token0, address token1) {
        (address curvePool,) = abi.decode(params, (address, address));
        ICurveStableSwap pool = ICurveStableSwap(curvePool);

        token0 = pool.coins(0);
        token1 = pool.coins(1);
    }

    /// @notice Returns "CRV" for Curve
    function protocolId() external pure override returns (string memory) {
        return PROTOCOL_ID;
    }

    /**
     * @notice Preview token amounts for removing liquidity
     * @dev Calculates proportional share based on LP token balance and pool reserves
     *
     * @param liquidity LP tokens to remove
     * @param params Encoded pool and gauge addresses
     * @return amount0 Estimated token0 to receive
     * @return amount1 Estimated token1 to receive
     */
    function previewRemoveLiquidity(uint128 liquidity, bytes calldata params)
        external
        view
        override
        returns (uint256 amount0, uint256 amount1)
    {
        (address curvePool, address gauge) = abi.decode(params, (address, address));

        ICurveStableSwap pool = ICurveStableSwap(curvePool);
        ICurveGauge curveGauge = ICurveGauge(gauge);

        // Get total LP supply
        address lpToken = curveGauge.lp_token();
        uint256 totalLpSupply = IERC20(lpToken).totalSupply();

        if (totalLpSupply == 0) return (0, 0);

        // Get pool reserves
        uint256 reserve0 = pool.balances(0);
        uint256 reserve1 = pool.balances(1);

        // Calculate proportional share
        amount0 = (reserve0 * uint256(liquidity)) / totalLpSupply;
        amount1 = (reserve1 * uint256(liquidity)) / totalLpSupply;
    }

    /**
     * @notice Check if pool is supported
     * @dev Validates pool has 2 tokens and gauge is valid
     */
    function supportsPool(bytes calldata params) external view override returns (bool) {
        try this.validatePool(params) returns (bool result) {
            return result;
        } catch {
            return false;
        }
    }

    /// @notice Helper to validate pool (used by supportsPool)
    function validatePool(bytes calldata params) external view returns (bool) {
        (address curvePool, address gauge) = abi.decode(params, (address, address));

        // Check pool has 2 tokens
        ICurveStableSwap pool = ICurveStableSwap(curvePool);
        address token0 = pool.coins(0);
        address token1 = pool.coins(1);

        if (token0 == address(0) || token1 == address(0)) {
            return false;
        }

        // Check gauge points to correct LP token
        ICurveGauge curveGauge = ICurveGauge(gauge);
        address gaugeLpToken = curveGauge.lp_token();

        // Get LP token from pool (method varies by pool type)
        // For now, just verify gauge has valid LP token
        if (gaugeLpToken == address(0)) {
            return false;
        }

        return true;
    }

    /// @notice Returns CRV token address as "protocol address"
    /// @dev For Curve, we return CRV token since there's no single main contract
    function protocolAddress() external view override returns (address) {
        return crvToken;
    }

    // ============================================================
    //                  PREVIEW VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Preview liquidity and amounts for adding liquidity
     * @dev Calculates based on pool proportions
     * @param params Encoded (curvePool, gauge, amount0, amount1)
     */
    function previewAddLiquidity(bytes calldata params)
        external
        view
        override
        returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
    {
        (address curvePool, address gauge, uint256 amount0, uint256 amount1) =
            abi.decode(params, (address, address, uint256, uint256));

        ICurveStableSwap pool = ICurveStableSwap(curvePool);
        ICurveGauge curveGauge = ICurveGauge(gauge);

        // Get LP token total supply
        address lpToken = curveGauge.lp_token();
        uint256 totalLpSupply = IERC20(lpToken).totalSupply();

        // Get pool reserves
        uint256 reserve0 = pool.balances(0);
        uint256 reserve1 = pool.balances(1);

        if (totalLpSupply == 0 || reserve0 == 0 || reserve1 == 0) {
            // First liquidity - use amounts as-is
            amount0Used = amount0;
            amount1Used = amount1;
            // Simple estimation: geometric mean as liquidity proxy
            liquidity = uint128(_sqrt(amount0 * amount1));
        } else {
            // Calculate proportional amounts based on pool reserves
            uint256 amount1Optimal = (amount0 * reserve1) / reserve0;

            if (amount1Optimal <= amount1) {
                // amount0 is the limiting factor
                amount0Used = amount0;
                amount1Used = amount1Optimal;
            } else {
                // amount1 is the limiting factor
                uint256 amount0Optimal = (amount1 * reserve0) / reserve1;
                amount0Used = amount0Optimal;
                amount1Used = amount1;
            }

            // Estimate LP tokens based on proportion of pool
            // LP_received ≈ (amount0Used / reserve0) * totalLpSupply
            liquidity = uint128((amount0Used * totalLpSupply) / reserve0);
        }
    }

    /**
     * @notice Calculate optimal amount1 for given amount0
     * @dev Uses pool reserves ratio
     */
    function calculateOptimalAmount1(uint256 amount0, bytes calldata params)
        external
        view
        override
        returns (uint256 amount1)
    {
        (address curvePool,) = abi.decode(params, (address, address));
        ICurveStableSwap pool = ICurveStableSwap(curvePool);

        uint256 reserve0 = pool.balances(0);
        uint256 reserve1 = pool.balances(1);

        if (reserve0 == 0) return 0;

        amount1 = (amount0 * reserve1) / reserve0;
    }

    /**
     * @notice Calculate optimal amount0 for given amount1
     * @dev Uses pool reserves ratio
     */
    function calculateOptimalAmount0(uint256 amount1, bytes calldata params)
        external
        view
        override
        returns (uint256 amount0)
    {
        (address curvePool,) = abi.decode(params, (address, address));
        ICurveStableSwap pool = ICurveStableSwap(curvePool);

        uint256 reserve0 = pool.balances(0);
        uint256 reserve1 = pool.balances(1);

        if (reserve1 == 0) return 0;

        amount0 = (amount1 * reserve0) / reserve1;
    }

    /**
     * @notice Get current pool price
     * @dev Curve doesn't use sqrtPriceX96, returns 0 for both values
     */
    function getPoolPrice(bytes calldata params) external pure override returns (uint160 sqrtPriceX96, int24 tick) {
        // Curve doesn't use Uniswap-style pricing
        params; // silence unused warning
        return (0, 0);
    }

    /**
     * @notice Get pool fee tier
     * @dev Returns Curve fee in 1e10 format, converted to basis points
     */
    function getPoolFee(bytes calldata params) external view override returns (uint24 fee) {
        (address curvePool,) = abi.decode(params, (address, address));
        ICurveStableSwap pool = ICurveStableSwap(curvePool);

        // Curve fee is in 1e10 format (e.g., 4000000 = 0.04% = 4 bps)
        // Convert to hundredths of a bip (same as Uniswap)
        uint256 curveFee = pool.fee();
        // curveFee * 100 / 1e10 = curveFee / 1e8
        fee = uint24(curveFee / 1e8);
    }

    // ============================================================
    //                     TVL VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Get current value of YieldForge position in token amounts
     * @dev Calculates how much of each token our staked LP position is worth
     *
     * For Curve, we calculate: (our_staked_lp / total_lp_supply) * pool_balances
     *
     * @param params Encoded pool and gauge addresses
     * @return amount0 Value of our position in token0
     * @return amount1 Value of our position in token1
     */
    function getPositionValue(bytes calldata params) external view override returns (uint256 amount0, uint256 amount1) {
        (address curvePool, address gauge) = abi.decode(params, (address, address));

        ICurveStableSwap pool = ICurveStableSwap(curvePool);
        ICurveGauge curveGauge = ICurveGauge(gauge);

        // Get our staked LP balance
        uint256 stakedLp = curveGauge.balanceOf(address(this));

        if (stakedLp == 0) return (0, 0);

        // Get LP token total supply
        address lpToken = curveGauge.lp_token();
        uint256 totalLpSupply = IERC20(lpToken).totalSupply();

        if (totalLpSupply == 0) return (0, 0);

        // Get pool reserves
        uint256 reserve0 = pool.balances(0);
        uint256 reserve1 = pool.balances(1);

        // Calculate our proportional share
        amount0 = (reserve0 * stakedLp) / totalLpSupply;
        amount1 = (reserve1 * stakedLp) / totalLpSupply;
    }

    /**
     * @notice Get total value locked in the underlying Curve pool
     * @dev Returns total token balances in the pool
     *
     * @param params Encoded pool and gauge addresses
     * @return amount0 Total token0 in the pool
     * @return amount1 Total token1 in the pool
     */
    function getPoolTotalValue(bytes calldata params)
        external
        view
        override
        returns (uint256 amount0, uint256 amount1)
    {
        (address curvePool,) = abi.decode(params, (address, address));

        ICurveStableSwap pool = ICurveStableSwap(curvePool);

        // Curve pools store token balances directly
        amount0 = pool.balances(0);
        amount1 = pool.balances(1);
    }

    /**
     * @notice Integer square root (Babylonian method)
     * @dev Used for liquidity estimation
     */
    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
