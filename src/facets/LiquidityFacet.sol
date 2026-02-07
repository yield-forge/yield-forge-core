// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibPause} from "../libraries/LibPause.sol";
import {LibReentrancyGuard} from "../libraries/LibReentrancyGuard.sol";
import {TokenNaming} from "../libraries/TokenNaming.sol";
import {ILiquidityAdapter} from "../interfaces/ILiquidityAdapter.sol";
import {PrincipalToken} from "../tokens/PrincipalToken.sol";
import {YieldToken} from "../tokens/YieldToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title LiquidityFacet
 * @author Yield Forge Team
 * @notice Manages liquidity addition and automatic cycle creation
 * @dev Works with any liquidity adapter (V4, V3, Curve, etc.)
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

        _ensureActiveCycle(poolId);

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

        // NOTE: adapterParams encoding handled by _encodeAdapterParams()

        // Add liquidity via adapter
        uint128 liquidityReceived;
        uint256 amount0Used;
        uint256 amount1Used;

        (liquidityReceived, amount0Used, amount1Used) =
            adapter.addLiquidity(_encodeAdapterParams(pool.poolParams, amount0, amount1));

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

        uint256 valueInQuote = _calculateValueInQuote(amount0Used, amount1Used, pool);

        // ===== MINT TOKENS TO USER =====
        // No mint fee - user receives full amount

        PrincipalToken(cycle.ptToken).mint(msg.sender, valueInQuote);
        YieldToken(cycle.ytToken).mint(msg.sender, valueInQuote);

        ptAmount = valueInQuote;
        ytAmount = valueInQuote;

        emit LiquidityAdded(poolId, cycleId, msg.sender, liquidity, ptAmount, ytAmount);

        // ===== EMIT TVL UPDATE =====
        _emitTvlUpdated(poolId, cycleId, pool);

        // ===== REENTRANCY GUARD EXIT =====
        LibReentrancyGuard._nonReentrantAfter();
    }

    // ============================================================
    //                   INTERNAL FUNCTIONS
    // ============================================================

    /**
     * @notice Ensure an active cycle exists for the pool
     * @dev Creates new cycle if:
     *      - No cycle exists (cycleId = 0)
     *      - Current cycle has matured
     *
     * @param poolId Pool identifier
     */
    function _ensureActiveCycle(bytes32 poolId) internal {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 cycleId = s.currentCycleId[poolId];

        // Case 1: No cycle yet - create first cycle
        if (cycleId == 0) {
            _startNewCycle(poolId);
            return;
        }

        // Case 2: Check if current cycle has matured
        LibAppStorage.CycleInfo storage currentCycle = s.cycles[poolId][cycleId];

        if (block.timestamp >= currentCycle.maturityDate) {
            // Deactivate old cycle
            currentCycle.isActive = false;

            // Start new cycle
            _startNewCycle(poolId);
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
    function _startNewCycle(bytes32 poolId) internal {
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
        // Note: tickLower/tickUpper are only used by Uniswap adapters
        // For Curve, they remain 0
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

        emit NewCycleStarted(poolId, newCycleId, block.timestamp, maturityDate, address(pt), address(yt));
    }

    /**
     * @notice Encode parameters for adapter call
     * @dev Different adapters expect different param formats
     *
     * This function decodes the stored poolParams and re-encodes
     * with the amount values for the addLiquidity call.
     *
     * @param poolParams Stored pool parameters
     * @param amount0 Token0 amount
     * @param amount1 Token1 amount
     * @return Encoded params for adapter
     */
    function _encodeAdapterParams(bytes memory poolParams, uint256 amount0, uint256 amount1)
        internal
        pure
        returns (bytes memory)
    {
        // Concatenate poolParams with encoded amounts
        // This produces the format adapters expect:
        // - V4: (PoolKey, uint256, uint256)
        // - V3: (address, uint256, uint256)
        // - Curve: (address, address, uint256, uint256)
        return bytes.concat(poolParams, abi.encode(amount0, amount1));
    }

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
    function _calculateValueInQuote(uint256 amount0Used, uint256 amount1Used, LibAppStorage.PoolInfo storage pool)
        internal
        view
        returns (uint256 valueInQuote)
    {
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
        bytes memory adapterParams = _encodeAdapterPreviewParams(pool.poolParams, amount0, amount1);

        (, uint256 a0Used, uint256 a1Used) = adapter.previewAddLiquidity(adapterParams);

        amount0Used = a0Used;
        amount1Used = a1Used;

        // Calculate value in quote token (normalized to 18 decimals)
        uint256 valueInQuote = _calculateValueInQuote(a0Used, a1Used, pool);

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

    /**
     * @notice Encode adapter params for preview
     * @dev Same encoding as _encodeAdapterParams
     */
    function _encodeAdapterPreviewParams(bytes memory poolParams, uint256 amount0, uint256 amount1)
        internal
        pure
        returns (bytes memory)
    {
        return bytes.concat(poolParams, abi.encode(amount0, amount1));
    }

    /**
     * @notice Emit TVL update event
     * @dev Fetches current TVL from adapter and emits TvlUpdated event
     * @param poolId Pool identifier
     * @param cycleId Current cycle
     * @param pool Pool info storage reference
     */
    function _emitTvlUpdated(bytes32 poolId, uint256 cycleId, LibAppStorage.PoolInfo storage pool) internal {
        ILiquidityAdapter adapter = ILiquidityAdapter(pool.adapter);

        // Get YieldForge position value
        (uint256 yfAmount0, uint256 yfAmount1) = adapter.getPositionValue(pool.poolParams);

        // Get total pool value
        (uint256 poolAmount0, uint256 poolAmount1) = adapter.getPoolTotalValue(pool.poolParams);

        // Calculate values in quote token (normalized to 18 decimals)
        uint256 yfTvlInQuote = _calculateValueInQuote(yfAmount0, yfAmount1, pool);
        uint256 poolTvlInQuote = _calculateValueInQuote(poolAmount0, poolAmount1, pool);

        emit TvlUpdated(poolId, cycleId, yfAmount0, yfAmount1, yfTvlInQuote, poolAmount0, poolAmount1, poolTvlInQuote);
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
        valueInQuote = _calculateValueInQuote(amount0, amount1, pool);
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
        valueInQuote = _calculateValueInQuote(amount0, amount1, pool);
    }
}
