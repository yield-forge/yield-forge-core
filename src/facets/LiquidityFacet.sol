// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibLiquidity} from "../libraries/LibLiquidity.sol";
import {LibYieldForgeMarket} from "../libraries/LibYieldForgeMarket.sol";
import {LibPause} from "../libraries/LibPause.sol";
import {LibReentrancyGuard} from "../libraries/LibReentrancyGuard.sol";
import {ILiquidityAdapter} from "../interfaces/ILiquidityAdapter.sol";
import {PrincipalToken} from "../tokens/PrincipalToken.sol";
import {YieldToken} from "../tokens/YieldToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title LiquidityFacet
 * @author Yield Forge Team
 * @notice Manages liquidity addition and automatic cycle creation
 * @dev Works with any liquidity adapter (V4, V3, etc.)
 *
 * ARCHITECTURE OVERVIEW:
 * ----------------------
 * This facet handles:
 * 1. Adding liquidity to underlying protocols via adapters
 * 2. Minting PT/YT tokens to users
 * 3. Automatic cycle creation and rotation
 *
 * CYCLE SYSTEM:
 * -------------
 * Each pool has cycles lasting ~90 days:
 *
 * 1. Pool registered (no cycle yet)
 * 2. First addLiquidity() → Creates cycle 1, deploys PT/YT tokens
 * 3. Users add more liquidity → Same cycle, same PT/YT
 * 4. 90 days pass → Cycle 1 matures
 * 5. Next addLiquidity() → Creates cycle 2, new PT/YT tokens
 * 6. Old PT can be redeemed, old YT can claim yield
 *
 * TOKEN NAMING:
 * - PT: YF-PT-[HASH6]-[DDMMMYYYY] (e.g., YF-PT-A3F2E9-31MAR2025)
 * - YT: YF-YT-[HASH6]-[DDMMMYYYY] (e.g., YF-YT-A3F2E9-31MAR2025)
 *
 * FLOW FOR addLiquidity():
 * ------------------------
 * 1. Validate pool exists and is not banned
 * 2. Ensure active cycle (create new if needed)
 * 3. Transfer tokens from user to Diamond
 * 4. Approve tokens to adapter
 * 5. Call adapter.addLiquidity()
 * 6. Mint PT/YT to user (1:1 with liquidity)
 * 7. Return unused tokens to user
 *
 * PROTOCOL FEES:
 * --------------
 * No mint fee - users receive 100% of PT/YT.
 * Protocol fee is only taken from yield (see YieldAccumulatorFacet).
 *
 * SECURITY:
 * ---------
 * - Tokens are transferred to Diamond before adapter call
 * - Unused tokens are returned to user
 * - Only registered, non-banned pools can receive liquidity
 */
contract LiquidityFacet {
    using SafeERC20 for IERC20;

    // ============================================================
    //                          EVENTS
    // ============================================================

    /**
     * @notice Emitted when liquidity is added to a pool
     * @param poolId Pool identifier
     * @param cycleId Current cycle number
     * @param provider Address that added liquidity
     * @param liquidity LP units added
     * @param ptMinted PT tokens minted to user
     * @param ytMinted YT tokens minted to user
     */
    event LiquidityAdded(
        bytes32 indexed poolId,
        uint256 indexed cycleId,
        address indexed provider,
        uint256 liquidity,
        uint256 ptMinted,
        uint256 ytMinted
    );

    /**
     * @notice Emitted when a new cycle starts
     * @param poolId Pool identifier
     * @param cycleId New cycle number
     * @param startTimestamp When cycle started
     * @param maturityDate When cycle will mature
     * @param ptToken Address of new PT token
     * @param ytToken Address of new YT token
     */
    event NewCycleStarted(
        bytes32 indexed poolId,
        uint256 indexed cycleId,
        uint256 startTimestamp,
        uint256 maturityDate,
        address ptToken,
        address ytToken
    );

    /**
     * @notice Emitted when TVL is updated (after liquidity changes)
     * @dev Used by indexer to track TVL over time
     * @param poolId Pool identifier
     * @param cycleId Current cycle number
     * @param yfTvlAmount0 YieldForge position value in token0
     * @param yfTvlAmount1 YieldForge position value in token1
     * @param yfTvlInQuote YieldForge position value in quote token (18 decimals)
     * @param poolTvlAmount0 Total pool token0
     * @param poolTvlAmount1 Total pool token1
     * @param poolTvlInQuote Total pool value in quote token (18 decimals)
     */
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

    // ============================================================
    //                          ERRORS
    // ============================================================

    /// @notice Pool does not exist
    error PoolDoesNotExist(bytes32 poolId);

    /// @notice Pool is banned
    error PoolBanned(bytes32 poolId);

    /// @notice Zero amount provided
    error ZeroAmount();

    /// @notice Adapter call failed
    error AdapterCallFailed();

    // ============================================================
    //                     MAIN FUNCTIONS
    // ============================================================

    /**
     * @notice Add liquidity to a pool and receive PT/YT tokens
     * @dev Automatically creates new cycle if needed
     *
     * IMPORTANT: User must approve tokens to Diamond before calling!
     *
     * @param poolId Pool identifier (from registerPool)
     * @param amount0 Amount of token0 to add
     * @param amount1 Amount of token1 to add
     * @return liquidity LP units created
     * @return ptAmount PT tokens minted to user
     * @return ytAmount YT tokens minted to user
     *
     * Example:
     *   // Approve tokens first
     *   token0.approve(diamond, amount0);
     *   token1.approve(diamond, amount1);
     *
     *   // Add liquidity
     *   (uint256 liq, uint256 pt, uint256 yt) = liquidityFacet.addLiquidity(
     *       poolId,
     *       1000e18,  // 1000 token0
     *       1000e6    // 1000 token1 (if 6 decimals)
     *   );
     */
    function addLiquidity(bytes32 poolId, uint256 amount0, uint256 amount1)
        external
        returns (uint256 liquidity, uint256 ptAmount, uint256 ytAmount)
    {
        // ===== SECURITY CHECKS =====
        LibPause.requireNotPaused();
        LibReentrancyGuard._nonReentrantBefore();

        // ===== VALIDATION =====

        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        LibAppStorage.PoolInfo storage pool = s.pools[poolId];

        // Check pool exists
        if (!pool.exists) {
            revert PoolDoesNotExist(poolId);
        }

        // Check pool is not banned
        if (pool.isBanned) {
            revert PoolBanned(poolId);
        }

        // Check amounts
        if (amount0 == 0 && amount1 == 0) {
            revert ZeroAmount();
        }

        // ===== ENSURE ACTIVE CYCLE =====

        LibLiquidity.ensureActiveCycle(poolId);

        // ===== TRANSFER TOKENS FROM USER =====

        if (amount0 > 0) {
            IERC20(pool.token0).safeTransferFrom(msg.sender, address(this), amount0);
        }
        if (amount1 > 0) {
            IERC20(pool.token1).safeTransferFrom(msg.sender, address(this), amount1);
        }

        // ===== CALL ADAPTER =====

        ILiquidityAdapter adapter = ILiquidityAdapter(pool.adapter);

        // Approve tokens to adapter
        if (amount0 > 0) {
            IERC20(pool.token0).safeIncreaseAllowance(pool.adapter, amount0);
        }
        if (amount1 > 0) {
            IERC20(pool.token1).safeIncreaseAllowance(pool.adapter, amount1);
        }

        // Add liquidity via adapter
        uint128 liquidityReceived;
        uint256 amount0Used;
        uint256 amount1Used;

        (liquidityReceived, amount0Used, amount1Used) =
            adapter.addLiquidity(pool.poolParams, amount0, amount1);

        liquidity = uint256(liquidityReceived);

        // ===== REFUND UNUSED TOKENS =====

        if (amount0 > amount0Used) {
            IERC20(pool.token0).safeTransfer(msg.sender, amount0 - amount0Used);
        }
        if (amount1 > amount1Used) {
            IERC20(pool.token1).safeTransfer(msg.sender, amount1 - amount1Used);
        }

        // ===== UPDATE CYCLE STATE =====

        uint256 cycleId = s.currentCycleId[poolId];
        LibAppStorage.CycleInfo storage cycle = s.cycles[poolId][cycleId];

        // Update total liquidity
        cycle.totalLiquidity += liquidityReceived;

        // ===== CALCULATE VALUE IN QUOTE TOKEN =====
        // PT/YT are minted based on total value in quote token terms
        // This gives users a meaningful, human-readable token amount
        // Example: deposit 1 WBTC + 90k USDT → receive ~180k PT/YT

        uint256 valueInQuote = LibLiquidity.calculateValueInQuote(amount0Used, amount1Used, pool);

        // ===== MINT TOKENS TO USER =====
        // No mint fee - user receives full amount

        PrincipalToken(cycle.ptToken).mint(msg.sender, valueInQuote);
        YieldToken(cycle.ytToken).mint(msg.sender, valueInQuote);

        ptAmount = valueInQuote;
        ytAmount = valueInQuote;

        emit LiquidityAdded(poolId, cycleId, msg.sender, liquidity, ptAmount, ytAmount);

        // ===== EMIT TVL UPDATE =====
        LibLiquidity.emitTvlUpdated(poolId, cycleId, pool);

        // ===== REFRESH MATURITY TARGET =====
        _refreshMaturityTarget(poolId, cycleId, pool);

        // ===== REENTRANCY GUARD EXIT =====
        LibReentrancyGuard._nonReentrantAfter();
    }

    // ============================================================
    //                 MATURITY TARGET REFRESH
    // ============================================================

    /// @notice Emitted when maturity target price is updated
    event MaturityTargetUpdated(bytes32 indexed poolId, uint256 indexed cycleId, uint256 maturityTargetPriceBps);

    /**
     * @notice Refresh the maturity target price for a pool's current cycle
     * @dev Callable by anyone (keeper pattern). Computes V(t) = currentLpValue / totalPTSupply
     *      and applies rate limiting to prevent MEV manipulation.
     * @param poolId Pool identifier
     */
    function refreshMaturityTarget(bytes32 poolId) external {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        LibAppStorage.PoolInfo storage pool = s.pools[poolId];
        if (pool.adapter == address(0)) revert PoolDoesNotExist(poolId);

        uint256 cycleId = s.currentCycleId[poolId];
        _refreshMaturityTarget(poolId, cycleId, pool);
    }

    /**
     * @notice Internal refresh of maturity target with rate limiting
     */
    function _refreshMaturityTarget(
        bytes32 poolId,
        uint256 cycleId,
        LibAppStorage.PoolInfo storage pool
    ) private {
        if (cycleId == 0) return;

        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        LibAppStorage.CycleInfo storage cycle = s.cycles[poolId][cycleId];
        LibAppStorage.YieldForgeMarketInfo storage market = s.yieldForgeMarkets[poolId][cycleId];

        // Compute fresh V(t)
        ILiquidityAdapter adapter = ILiquidityAdapter(pool.adapter);
        (uint256 amount0, uint256 amount1) = adapter.getPositionValue(pool.poolParams);
        uint256 currentValue = LibLiquidity.calculateValueInQuote(amount0, amount1, pool);

        uint256 ptSupply = PrincipalToken(cycle.ptToken).totalSupply();
        if (ptSupply == 0 || currentValue == 0) return;

        uint256 freshBps = (currentValue * LibYieldForgeMarket.BPS_DENOMINATOR) / ptSupply;

        // Get stored value (with legacy fallback)
        uint256 storedBps = market.maturityTargetPriceBps;
        if (storedBps == 0) storedBps = LibYieldForgeMarket.BPS_DENOMINATOR;

        // Rate-limit the update
        uint256 elapsed = block.timestamp > market.lastTargetUpdateTime
            ? block.timestamp - market.lastTargetUpdateTime
            : 0;

        uint256 newBps = LibYieldForgeMarket.applyTargetRateLimit(storedBps, freshBps, elapsed);

        // Store
        market.maturityTargetPriceBps = newBps;
        market.lastTargetUpdateTime = block.timestamp;

        emit MaturityTargetUpdated(poolId, cycleId, newBps);
    }

    // ============================================================
    //                      VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Check if a pool has an active cycle
     * @param poolId Pool identifier
     * @return True if pool has an active, non-matured cycle
     */
    function hasActiveCycle(bytes32 poolId) external view returns (bool) {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 cycleId = s.currentCycleId[poolId];

        if (cycleId == 0) return false;

        LibAppStorage.CycleInfo storage cycle = s.cycles[poolId][cycleId];
        return cycle.isActive && block.timestamp < cycle.maturityDate;
    }

    /**
     * @notice Get time until current cycle matures
     * @param poolId Pool identifier
     * @return Seconds until maturity (0 if already matured or no cycle)
     */
    function timeToMaturity(bytes32 poolId) external view returns (uint256) {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 cycleId = s.currentCycleId[poolId];

        if (cycleId == 0) return 0;

        LibAppStorage.CycleInfo storage cycle = s.cycles[poolId][cycleId];

        if (block.timestamp >= cycle.maturityDate) return 0;

        return cycle.maturityDate - block.timestamp;
    }

    /**
     * @notice Get total liquidity in current cycle
     * @param poolId Pool identifier
     * @return Total liquidity (0 if no cycle)
     */
    function getTotalLiquidity(bytes32 poolId) external view returns (uint128) {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 cycleId = s.currentCycleId[poolId];

        if (cycleId == 0) return 0;

        return s.cycles[poolId][cycleId].totalLiquidity;
    }

    /**
     * @notice Preview PT/YT tokens for adding liquidity
     * @dev Calls adapter's previewAddLiquidity and calculates value in quote token
     *
     * @param poolId Pool identifier
     * @param amount0 Amount of token0 to deposit
     * @param amount1 Amount of token1 to deposit
     * @return expectedPT Expected PT tokens (value in quote, 18 decimals)
     * @return expectedYT Expected YT tokens (value in quote, 18 decimals)
     * @return amount0Used Actual token0 that will be used
     * @return amount1Used Actual token1 that will be used
     */
    function previewAddLiquidity(bytes32 poolId, uint256 amount0, uint256 amount1)
        external
        view
        returns (uint256 expectedPT, uint256 expectedYT, uint256 amount0Used, uint256 amount1Used)
    {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        LibAppStorage.PoolInfo storage pool = s.pools[poolId];

        if (pool.adapter == address(0)) revert PoolDoesNotExist(poolId);

        ILiquidityAdapter adapter = ILiquidityAdapter(pool.adapter);

        (, uint256 a0Used, uint256 a1Used) = adapter.previewAddLiquidity(pool.poolParams, amount0, amount1);

        amount0Used = a0Used;
        amount1Used = a1Used;

        // Calculate value in quote token (normalized to 18 decimals)
        uint256 valueInQuote = LibLiquidity.calculateValueInQuote(a0Used, a1Used, pool);

        // PT/YT are minted based on quote value
        expectedPT = valueInQuote;
        expectedYT = valueInQuote;
    }

    /**
     * @notice Calculate optimal amount1 for given amount0
     * @dev Used by UI for auto-sync of input fields
     *
     * @param poolId Pool identifier
     * @param amount0 Amount of token0
     * @return amount1 Optimal amount of token1
     */
    function calculateOptimalAmount1(bytes32 poolId, uint256 amount0) external view returns (uint256 amount1) {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        LibAppStorage.PoolInfo storage pool = s.pools[poolId];

        if (pool.adapter == address(0)) revert PoolDoesNotExist(poolId);

        ILiquidityAdapter adapter = ILiquidityAdapter(pool.adapter);
        amount1 = adapter.calculateOptimalAmount1(amount0, pool.poolParams);
    }

    /**
     * @notice Calculate optimal amount0 for given amount1
     * @dev Used by UI for auto-sync of input fields
     *
     * @param poolId Pool identifier
     * @param amount1 Amount of token1
     * @return amount0 Optimal amount of token0
     */
    function calculateOptimalAmount0(bytes32 poolId, uint256 amount1) external view returns (uint256 amount0) {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        LibAppStorage.PoolInfo storage pool = s.pools[poolId];

        if (pool.adapter == address(0)) revert PoolDoesNotExist(poolId);

        ILiquidityAdapter adapter = ILiquidityAdapter(pool.adapter);
        amount0 = adapter.calculateOptimalAmount0(amount1, pool.poolParams);
    }

    // ============================================================
    //                      TVL VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Get YieldForge TVL for a pool
     * @dev Returns the value of YF's position in the underlying pool
     *
     * @param poolId Pool identifier
     * @return amount0 Value in token0
     * @return amount1 Value in token1
     * @return valueInQuote Value in quote token (18 decimals)
     */
    function getTvl(bytes32 poolId) external view returns (uint256 amount0, uint256 amount1, uint256 valueInQuote) {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        LibAppStorage.PoolInfo storage pool = s.pools[poolId];

        if (pool.adapter == address(0)) revert PoolDoesNotExist(poolId);

        ILiquidityAdapter adapter = ILiquidityAdapter(pool.adapter);
        (amount0, amount1) = adapter.getPositionValue(pool.poolParams);
        valueInQuote = LibLiquidity.calculateValueInQuote(amount0, amount1, pool);
    }

    /**
     * @notice Get total pool TVL (entire underlying pool)
     * @dev Returns the total value locked in the underlying DEX pool
     *
     * @param poolId Pool identifier
     * @return amount0 Total token0 in pool
     * @return amount1 Total token1 in pool
     * @return valueInQuote Total value in quote token (18 decimals)
     */
    function getPoolTotalTvl(bytes32 poolId)
        external
        view
        returns (uint256 amount0, uint256 amount1, uint256 valueInQuote)
    {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        LibAppStorage.PoolInfo storage pool = s.pools[poolId];

        if (pool.adapter == address(0)) revert PoolDoesNotExist(poolId);

        ILiquidityAdapter adapter = ILiquidityAdapter(pool.adapter);
        (amount0, amount1) = adapter.getPoolTotalValue(pool.poolParams);
        valueInQuote = LibLiquidity.calculateValueInQuote(amount0, amount1, pool);
    }
}
