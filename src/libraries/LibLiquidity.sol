// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {LibAppStorage} from "./LibAppStorage.sol";
import {LibYieldForgeMarket} from "./LibYieldForgeMarket.sol";
import {TokenNaming} from "./TokenNaming.sol";
import {ILiquidityAdapter} from "../interfaces/ILiquidityAdapter.sol";
import {PrincipalToken} from "../tokens/PrincipalToken.sol";
import {YieldToken} from "../tokens/YieldToken.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title LibLiquidity
 * @author Yield Forge Team
 * @notice Shared logic for liquidity operations across facets
 * @dev Internal library functions are inlined into calling facets at compile time,
 *      sharing the same Diamond storage context via delegatecall.
 *
 * Extracted from LiquidityFacet to enable reuse by LPTokenizeFacet.
 */
library LibLiquidity {
    // ============================================================
    //                          EVENTS
    // ============================================================

    event NewCycleStarted(
        bytes32 indexed poolId,
        uint256 indexed cycleId,
        uint256 startTimestamp,
        uint256 maturityDate,
        address ptToken,
        address ytToken
    );

    event TvlUpdated(
        bytes32 indexed poolId,
        uint256 indexed cycleId,
        uint256 yfTvlAmount0,
        uint256 yfTvlAmount1,
        uint256 yfTvlInQuote,
        uint256 poolTvlAmount0,
        uint256 poolTvlAmount1,
        uint256 poolTvlInQuote
    );

    /// @notice Adapter is deprecated, no new cycles allowed
    error AdapterDeprecated(address adapter);

    // ============================================================
    //                    CYCLE MANAGEMENT
    // ============================================================

    /**
     * @notice Ensure an active cycle exists for the pool
     * @dev Creates new cycle if:
     *      - No cycle exists (cycleId = 0)
     *      - Current cycle has matured
     *
     * @param poolId Pool identifier
     */
    function ensureActiveCycle(bytes32 poolId) internal {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        LibAppStorage.PoolInfo storage pool = s.pools[poolId];
        uint256 cycleId = s.currentCycleId[poolId];

        // Case 1: No cycle yet - create first cycle
        if (cycleId == 0) {
            // Block new cycles on deprecated adapters
            if (s.deprecatedAdapters[pool.adapter]) {
                revert AdapterDeprecated(pool.adapter);
            }
            startNewCycle(poolId);
            return;
        }

        // Case 2: Check if current cycle has matured
        LibAppStorage.CycleInfo storage currentCycle = s.cycles[poolId][cycleId];

        if (block.timestamp >= currentCycle.maturityDate) {
            // Deactivate old cycle
            currentCycle.isActive = false;

            // Block new cycles on deprecated adapters
            if (s.deprecatedAdapters[pool.adapter]) {
                revert AdapterDeprecated(pool.adapter);
            }

            // Start new cycle
            startNewCycle(poolId);
        }
    }

    /**
     * @notice Start a new cycle for a pool
     * @dev Creates new PT/YT tokens with unique names
     *
     * FLOW:
     * 1. Increment cycle ID
     * 2. Calculate maturity date (90 days from now)
     * 3. Generate token names (YF-PT-HASH-DATE)
     * 4. Deploy new PT and YT contracts
     * 5. Store cycle info
     * 6. Update active token mappings
     *
     * @param poolId Pool identifier
     */
    function startNewCycle(bytes32 poolId) internal {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();

        // Increment cycle ID
        uint256 newCycleId = s.currentCycleId[poolId] + 1;

        // Calculate maturity date (90 days from now)
        uint256 maturityDate = TokenNaming.calculateMaturity(block.timestamp);

        // Generate token name components
        string memory hashStr = TokenNaming.poolIdToShortHash(poolId);
        string memory maturityStr = TokenNaming.formatMaturityDate(maturityDate);

        // Create token names
        // Format: YF-PT-A3F2E9-31MAR2025
        string memory ptName = string(abi.encodePacked("YF-PT-", hashStr, "-", maturityStr));
        string memory ytName = string(abi.encodePacked("YF-YT-", hashStr, "-", maturityStr));

        // Deploy new PT token
        PrincipalToken pt = new PrincipalToken(
            ptName, // name
            ptName, // symbol (same as name for clarity)
            address(this), // diamond address (minter)
            poolId, // pool identifier
            newCycleId, // cycle number
            maturityDate // when PT can be redeemed
        );

        // Deploy new YT token
        YieldToken yt = new YieldToken(
            ytName, // name
            ytName, // symbol
            address(this), // diamond address (minter + yield source)
            poolId, // pool identifier
            newCycleId, // cycle number
            maturityDate // when yield stops accruing
        );

        // Store cycle info
        // Note: tickLower/tickUpper are set by Uniswap adapters
        LibAppStorage.CycleInfo storage newCycle = s.cycles[poolId][newCycleId];
        newCycle.cycleId = newCycleId;
        newCycle.startTimestamp = block.timestamp;
        newCycle.maturityDate = maturityDate;
        newCycle.ptToken = address(pt);
        newCycle.ytToken = address(yt);
        newCycle.totalLiquidity = 0;
        newCycle.isActive = true;
        newCycle.tickLower = 0; // Set by adapter if needed
        newCycle.tickUpper = 0; // Set by adapter if needed

        // Update current cycle ID
        s.currentCycleId[poolId] = newCycleId;

        // Update active token mappings
        s.activePT[poolId] = address(pt);
        s.activeYT[poolId] = address(yt);

        // Update reverse mappings (for upgrade/redemption)
        s.ptToPoolId[address(pt)] = poolId;
        s.ptToCycleId[address(pt)] = newCycleId;

        // Initialize secondary market in PENDING status
        // Will become ACTIVE when first LP provides liquidity
        LibAppStorage.YieldForgeMarketInfo storage market = s.yieldForgeMarkets[poolId][newCycleId];
        market.status = LibAppStorage.YieldForgeMarketStatus.PENDING;
        market.ptReserve = 0;
        market.virtualQuoteReserve = 0;
        market.totalLpShares = 0;
        market.accumulatedFeesPT = 0;
        market.accumulatedFeesQuote = 0;
        market.createdAt = block.timestamp;
        market.maturityTargetPriceBps = LibYieldForgeMarket.BPS_DENOMINATOR; // Initialize to 1.0
        market.lastTargetUpdateTime = block.timestamp;

        emit NewCycleStarted(poolId, newCycleId, block.timestamp, maturityDate, address(pt), address(yt));
    }

    // ============================================================
    //                    VALUE CALCULATION
    // ============================================================

    /**
     * @notice Calculate total value of deposited tokens in quote token terms
     * @dev Normalizes the result to 18 decimals for PT/YT minting
     *
     * CALCULATION:
     * 1. Get current price from adapter (sqrtPriceX96)
     * 2. Determine which token is quote token
     * 3. Convert non-quote token amount to quote value using price
     * 4. Normalize result to 18 decimals
     *
     * PRICE INTERPRETATION (Uniswap convention):
     * sqrtPriceX96 = sqrt(token1/token0) * 2^96
     * price = (sqrtPriceX96 / 2^96)^2 = token1 per token0
     *
     * @param amount0Used Amount of token0 deposited
     * @param amount1Used Amount of token1 deposited
     * @param pool Pool information
     * @return valueInQuote Total value in quote token, normalized to 18 decimals
     */
    function calculateValueInQuote(
        uint256 amount0Used,
        uint256 amount1Used,
        LibAppStorage.PoolInfo storage pool
    ) internal view returns (uint256 valueInQuote) {
        // Get current price from adapter
        ILiquidityAdapter adapter = ILiquidityAdapter(pool.adapter);
        (uint160 sqrtPriceX96,) = adapter.getPoolPrice(pool.poolParams);

        // Get token decimals
        uint8 decimals0 = IERC20Metadata(pool.token0).decimals();
        uint8 decimals1 = IERC20Metadata(pool.token1).decimals();

        // Calculate price: token1 per token0
        // price = (sqrtPriceX96 / 2^96)^2
        // To avoid precision loss, we compute: price = sqrtPriceX96^2 / 2^192
        // But we need to be careful with overflow, so we use intermediate scaling

        uint256 sqrtPrice = uint256(sqrtPriceX96);

        if (pool.quoteToken == pool.token1) {
            // Quote token is token1
            // Value = amount1 + amount0 * price (where price = token1/token0)
            // Convert amount0 to quote: amount0 * sqrtPrice^2 / 2^192
            //
            // IMPORTANT: sqrtPriceX96 from Uniswap already represents the price
            // in raw token units (wei). No additional decimal adjustment is needed!
            // price_raw = token1_raw / token0_raw
            // So: amount0_raw * price_raw = amount_in_token1_raw

            uint256 amount0InQuote;
            if (amount0Used > 0) {
                // Use full precision calculation
                // amount0 * sqrtPrice^2 / 2^192
                // Rearrange to avoid overflow: (amount0 * sqrtPrice / 2^96) * (sqrtPrice / 2^96)
                uint256 intermediate = (amount0Used * sqrtPrice) / (1 << 96);
                amount0InQuote = (intermediate * sqrtPrice) / (1 << 96);
                // Result is already in token1 raw units - no decimal adjustment needed!
            }

            uint256 totalInQuoteDecimals = amount1Used + amount0InQuote;

            // Normalize to 18 decimals
            if (decimals1 < 18) {
                valueInQuote = totalInQuoteDecimals * (10 ** (18 - decimals1));
            } else if (decimals1 > 18) {
                valueInQuote = totalInQuoteDecimals / (10 ** (decimals1 - 18));
            } else {
                valueInQuote = totalInQuoteDecimals;
            }
        } else {
            // Quote token is token0
            // Value = amount0 + amount1 / price (where price = token1/token0)
            // Convert amount1 to quote: amount1 * 2^192 / sqrtPrice^2
            //
            // IMPORTANT: sqrtPriceX96 from Uniswap already represents the price
            // in raw token units (wei). No additional decimal adjustment is needed!

            uint256 amount1InQuote;
            if (amount1Used > 0 && sqrtPrice > 0) {
                // amount1 / price = amount1 * 2^192 / sqrtPrice^2
                // Rearrange: (amount1 * 2^96 / sqrtPrice) * (2^96 / sqrtPrice)
                uint256 intermediate = (amount1Used << 96) / sqrtPrice;
                amount1InQuote = (intermediate << 96) / sqrtPrice;
                // Result is already in token0 raw units - no decimal adjustment needed!
            }

            uint256 totalInQuoteDecimals = amount0Used + amount1InQuote;

            // Normalize to 18 decimals
            if (decimals0 < 18) {
                valueInQuote = totalInQuoteDecimals * (10 ** (18 - decimals0));
            } else if (decimals0 > 18) {
                valueInQuote = totalInQuoteDecimals / (10 ** (decimals0 - 18));
            } else {
                valueInQuote = totalInQuoteDecimals;
            }
        }
    }

    // ============================================================
    //                       TVL EVENTS
    // ============================================================

    /**
     * @notice Emit TVL update event
     * @dev Fetches current TVL from adapter and emits TvlUpdated event
     * @param poolId Pool identifier
     * @param cycleId Current cycle
     * @param pool Pool info storage reference
     */
    function emitTvlUpdated(bytes32 poolId, uint256 cycleId, LibAppStorage.PoolInfo storage pool) internal {
        ILiquidityAdapter adapter = ILiquidityAdapter(pool.adapter);

        // Get YieldForge position value
        (uint256 yfAmount0, uint256 yfAmount1) = adapter.getPositionValue(pool.poolParams);

        // Get total pool value
        (uint256 poolAmount0, uint256 poolAmount1) = adapter.getPoolTotalValue(pool.poolParams);

        // Calculate values in quote token (normalized to 18 decimals)
        uint256 yfTvlInQuote = calculateValueInQuote(yfAmount0, yfAmount1, pool);
        uint256 poolTvlInQuote = calculateValueInQuote(poolAmount0, poolAmount1, pool);

        emit TvlUpdated(poolId, cycleId, yfAmount0, yfAmount1, yfTvlInQuote, poolAmount0, poolAmount1, poolTvlInQuote);
    }
}
