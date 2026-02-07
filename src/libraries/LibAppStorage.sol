// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * @title LibAppStorage
 * @author Yield Forge Team
 * @notice Central storage library for the Yield Forge protocol
 * @dev Uses EIP-2535 Diamond Storage pattern for upgradeable storage
 *
 * ARCHITECTURE OVERVIEW:
 * ----------------------
 * This library defines ALL state variables shared across Diamond facets.
 * Each facet accesses storage via `LibAppStorage.diamondStorage()`.
 *
 * KEY CONCEPTS:
 * 1. Pools - Registered liquidity pools from various protocols (V4, V3, Curve)
 * 2. Cycles - Time periods (~90 days) with unique PT/YT tokens
 * 3. Adapters - Protocol-specific implementations for liquidity operations
 * 4. Yield - Accumulated fees/rewards distributed to YT holders
 *
 * STORAGE LAYOUT:
 * ---------------
 * All mappings use bytes32 poolId as the primary key.
 * poolId is computed differently per protocol:
 * - Uniswap V4: PoolId from PoolKey
 * - Uniswap V3: keccak256(abi.encode(pool, tickLower, tickUpper))
 * - Curve: keccak256(abi.encode(curvePool, gauge))
 *
 * IMPORTANT: Storage slots are append-only. Never remove or reorder
 * existing fields to maintain upgrade compatibility.
 */
library LibAppStorage {
    /// @notice Storage position for Diamond Storage pattern
    /// @dev Computed as keccak256("yieldforge.app.storage")
    bytes32 constant DIAMOND_STORAGE_POSITION =
        keccak256("yieldforge.app.storage");

    // ============================================================
    //                     STRUCT DEFINITIONS
    // ============================================================

    /**
     * @notice Pool information stored for each registered pool
     * @dev This struct contains protocol-agnostic pool data.
     *      Protocol-specific data is encoded in `poolParams`.
     *
     * LIFECYCLE:
     * 1. Owner calls PoolRegistryFacet.registerPool(adapter, poolParams)
     * 2. PoolInfo is created with adapter address and decoded tokens
     * 3. Pool exists but has no active cycle until first addLiquidity()
     * 4. Pool can be banned/unbanned by PoolGuardian
     *
     * EXAMPLE poolParams encoding:
     * - V4: abi.encode(PoolKey) - contains currency0, currency1, fee, tickSpacing, hooks
     * - V3: abi.encode(poolAddress, tickLower, tickUpper)
     * - Curve: abi.encode(curvePoolAddress, gaugeAddress)
     */
    struct PoolInfo {
        /// @notice Address of the liquidity adapter for this pool
        /// @dev Each adapter implements ILiquidityAdapter interface
        /// Examples: UniswapV4Adapter, UniswapV3Adapter, CurveAdapter
        address adapter;
        /// @notice Protocol-specific pool parameters (encoded)
        /// @dev Decoded by the adapter when performing operations
        /// This allows storing any pool configuration without changing storage
        /// Maximum expected size: ~256 bytes (Uniswap V4 PoolKey)
        bytes poolParams;
        /// @notice First token in the pair (lower address for Uniswap)
        /// @dev Extracted from poolParams during registration for easy access
        address token0;
        /// @notice Second token in the pair
        address token1;
        /// @notice Whether this pool is registered in YieldForge
        /// @dev Set to true on registration, never set to false
        /// Use `isBanned` to disable a pool instead
        bool exists;
        /// @notice Whether this pool is banned from new operations
        /// @dev Banned pools cannot receive new liquidity
        /// Existing positions can still be redeemed and yield claimed
        bool isBanned;
        /// @notice Quote token for secondary market pricing
        /// @dev Auto-selected from whitelist during registration
        /// Must be one of the pool's tokens (token0 or token1)
        /// Used as the pricing currency in PT trading
        address quoteToken;
        /// @notice Decimals of the quote token (cached for gas efficiency)
        /// @dev Set during pool registration from IERC20Metadata(quoteToken).decimals()
        /// Used in YieldForgeMarket to scale virtualQuoteReserve correctly
        /// Example: USDT = 6, WETH = 18
        uint8 quoteDecimals;
    }

    /**
     * @notice Cycle information for a specific time period
     * @dev Each pool has multiple cycles over time. Only one cycle is active.
     *
     * LIFECYCLE (~90 days):
     * 1. First addLiquidity() starts cycle 1
     * 2. Users add liquidity, receive PT/YT tokens
     * 3. Yield accumulates from trading fees
     * 4. After maturityDate, cycle becomes inactive
     * 5. Next addLiquidity() starts cycle 2 with new PT/YT tokens
     * 6. Old PT can be redeemed, old YT can claim remaining yield
     *
     * TOKEN NAMING:
     * - PT: YF-PT-[HASH6]-[DDMMMYYYY] (e.g., YF-PT-A3F2E9-31MAR2025)
     * - YT: YF-YT-[HASH6]-[DDMMMYYYY] (e.g., YF-YT-A3F2E9-31MAR2025)
     *
     * FULL RANGE POSITIONS (Uniswap only):
     * All liquidity uses full range (MIN_TICK to MAX_TICK).
     * This makes PT/YT tokens fungible - all holders get equal yield share.
     */
    struct CycleInfo {
        /// @notice Sequential cycle number (1, 2, 3...)
        /// @dev Cycle 0 means no cycle has started yet
        uint256 cycleId;
        /// @notice Unix timestamp when this cycle began
        /// @dev Set to block.timestamp when cycle is created
        uint256 startTimestamp;
        /// @notice Unix timestamp when this cycle ends
        /// @dev Calculated as startTimestamp + 90 days
        /// After this time, no new liquidity can be added to this cycle
        uint256 maturityDate;
        /// @notice Address of the Principal Token for this cycle
        /// @dev New PT contract deployed for each cycle
        /// PT represents claim on underlying liquidity at maturity
        address ptToken;
        /// @notice Address of the Yield Token for this cycle
        /// @dev New YT contract deployed for each cycle
        /// YT represents claim on accumulated yield (fees/rewards)
        address ytToken;
        /// @notice Total liquidity in this cycle (LP units)
        /// @dev uint128 for compatibility with Uniswap liquidity type
        /// Increases on addLiquidity, decreases on redemption
        uint128 totalLiquidity;
        /// @notice Whether this is the current active cycle
        /// @dev Only one cycle per pool can be active
        /// Set to false when maturityDate passes
        bool isActive;
        /// @notice Lower tick of full range position (Uniswap only)
        /// @dev For Curve pools, this is unused (set to 0)
        int24 tickLower;
        /// @notice Upper tick of full range position (Uniswap only)
        /// @dev For Curve pools, this is unused (set to 0)
        int24 tickUpper;
    }

    /**
     * @notice Yield state tracking for a specific cycle
     * @dev Tracks accumulated fees/rewards and their distribution to YT holders
     *
     * YIELD DISTRIBUTION MECHANISM:
     * 1. Trading fees/rewards accumulate in the LP position
     * 2. Anyone calls harvestYield() to collect fees to the protocol
     * 3. Collected fees are distributed proportionally to YT holders
     * 4. Users call claimYield() to receive their share
     *
     * PRECISION:
     * yieldPerShare is scaled by 1e30 for precision.
     * Example: 100 tokens distributed to 1000 YT supply
     *   yieldPerShare = (100 * 1e30) / 1000 = 1e29
     *   User with 50 YT claims: (50 * 1e29) / 1e30 = 5 tokens
     *
     * TWO-TOKEN YIELD:
     * Uniswap pools earn fees in both tokens (token0 and token1).
     * We track each separately - no automatic conversion.
     * User receives both tokens when claiming.
     */
    struct CycleYieldState {
        /// @notice Accumulated yield per YT share for token0
        /// @dev Scaled by PRECISION (1e30)
        /// Increases each time harvestYield() is called
        uint256 yieldPerShare0;
        /// @notice Accumulated yield per YT share for token1
        /// @dev Scaled by PRECISION (1e30)
        uint256 yieldPerShare1;
        /// @notice Total yield accumulated for token0 (for analytics)
        /// @dev Raw amount, not scaled
        uint256 totalYieldAccumulated0;
        /// @notice Total yield accumulated for token1 (for analytics)
        uint256 totalYieldAccumulated1;
        /// @notice YT supply snapshot at last harvest
        /// @dev Used to calculate yieldPerShare
        uint256 totalYTSupply;
        /// @notice Protocol fees accumulated for token0 (not yet withdrawn)
        /// @dev Protocol takes a % of yield before distribution
        uint256 protocolFee0;
        /// @notice Protocol fees accumulated for token1 (not yet withdrawn)
        uint256 protocolFee1;
        /// @notice Timestamp of last harvestYield() call
        /// @dev For monitoring harvest frequency
        uint256 lastHarvestTime;
    }

    /**
     * @notice User's checkpoint for yield claiming
     * @dev Prevents users from claiming yield that accumulated before they got YT
     *
     * HOW IT WORKS:
     * When a user receives YT (mint or transfer), their checkpoint is set
     * to the current yieldPerShare. When claiming, they only receive yield
     * accumulated AFTER their checkpoint.
     *
     * Example:
     * 1. yieldPerShare0 = 100 (accumulated before user arrived)
     * 2. User receives 50 YT, checkpoint set to 100
     * 3. More yield: yieldPerShare0 = 150
     * 4. User claims: (150 - 100) * 50 / 1e30 = their share of new yield
     */
    struct UserYieldCheckpoint {
        /// @notice Last yieldPerShare0 when user claimed or received YT
        uint256 lastClaimedPerShare0;
        /// @notice Last yieldPerShare1 when user claimed or received YT
        uint256 lastClaimedPerShare1;
    }

    // ============================================================
    //              SECONDARY MARKET DEFINITIONS
    // ============================================================

    /**
     * @notice Status of a secondary market for PT trading
     * @dev Lifecycle: PENDING → ACTIVE → EXPIRED (or BANNED at any point)
     */
    enum YieldForgeMarketStatus {
        /// @notice Market created but no liquidity yet
        /// @dev First LP will set initial price via discount
        PENDING,
        /// @notice Trading is enabled
        /// @dev Has active liquidity, swaps allowed
        ACTIVE,
        /// @notice Cycle has matured
        /// @dev PT can be redeemed at par, no more trading needed
        EXPIRED,
        /// @notice Admin banned this market
        /// @dev Emergency measure, LP can still withdraw
        BANNED
    }

    /**
     * @notice Secondary market state for PT trading
     * @dev Each cycle has its own secondary market
     *
     * PRICING MODEL:
     * Uses single-sided (PT-only) liquidity with virtual quote reserves.
     * - LPs deposit PT tokens only
     * - Virtual quote reserve is calculated from PT price at deposit time
     * - Constant product formula: ptReserve * virtualQuoteReserve = k
     *
     * EXAMPLE:
     * 1. First LP deposits 1000 PT at 5% discount → implies 950 quote value
     * 2. ptReserve = 1000, virtualQuoteReserve = 950
     * 3. Swap 100 quote for PT: new reserves maintain x*y=k
     *
     * FEE STRUCTURE:
     * - Dynamic fee based on time to maturity (0.01% - 0.5%)
     * - 80% of fees go to LPs
     * - 20% of fees go to protocol
     */
    struct YieldForgeMarketInfo {
        /// @notice Current market status
        YieldForgeMarketStatus status;
        /// @notice Total PT tokens in the pool
        /// @dev Actual PT deposited by LPs + accumulated from sell swaps
        uint256 ptReserve;
        /// @notice Virtual quote token reserve
        /// @dev Used for AMM pricing (constant product formula)
        /// Calculated as: ptReserve * (1 - discountBps / 10000)
        uint256 virtualQuoteReserve;
        /// @notice Real quote tokens held in the contract
        /// @dev Actual quote tokens received from buy swaps (Quote → PT)
        /// LPs can withdraw their proportional share of this
        uint256 realQuoteReserve;
        /// @notice Total LP shares outstanding
        /// @dev Minted to liquidity providers
        uint256 totalLpShares;
        /// @notice Accumulated trading fees in PT (for LPs)
        /// @dev Distributed proportionally to LPs on withdrawal
        uint256 accumulatedFeesPT;
        /// @notice Accumulated trading fees in quoteToken (for LPs)
        /// @dev Distributed proportionally to LPs on withdrawal
        uint256 accumulatedFeesQuote;
        /// @notice Timestamp when market was created
        uint256 createdAt;
    }

    // ============================================================
    //                    YT ORDERBOOK STRUCTS
    // ============================================================

    /**
     * @notice Order in the YT orderbook
     * @dev Used for peer-to-peer YT trading
     *
     * ORDER TYPES:
     * - Sell Order: Maker sells YT for quote (YT NOT escrowed)
     * - Buy Order: Maker buys YT with quote (quote IS escrowed)
     */
    struct YTOrder {
        /// @notice Unique order ID
        uint256 id;
        /// @notice Address that created the order
        address maker;
        /// @notice Pool the YT belongs to
        bytes32 poolId;
        /// @notice Cycle the YT belongs to
        uint256 cycleId;
        /// @notice Total YT amount in order
        uint256 ytAmount;
        /// @notice Amount already filled
        uint256 filledAmount;
        /// @notice Price per YT in quote token (in quote token's native decimals)
        /// @dev Example: 0.05 USDT (6 decimals) = 50000
        uint256 pricePerYt;
        /// @notice True if selling YT, false if buying
        bool isSellOrder;
        /// @notice Timestamp when order was created
        uint256 createdAt;
        /// @notice Timestamp when order expires
        uint256 expiresAt;
        /// @notice True if order can still be filled/cancelled
        bool isActive;
    }

    /**
     * @notice Main application storage
     * @dev This struct holds ALL protocol state shared across facets
     *
     * STORAGE ORGANIZATION:
     * The struct is organized into logical sections:
     * 1. Pool Data - Information about registered pools
     * 2. Cycle Data - Cycle state for each pool
     * 3. Token Mappings - Quick access to active PT/YT
     * 4. Reverse Mappings - PT address → pool/cycle lookup
     * 5. Yield System - Yield tracking and distribution
     * 6. Access Control - Guardian and fee recipient
     * 7. Protocol Configuration - Oracle, fee settings
     *
     * UPGRADE SAFETY:
     * - Never remove fields
     * - Never reorder fields
     * - Only append new fields at the end
     * - Use reserved slots for future features if needed
     */
    struct AppStorage {
        // ============================================================
        //                       POOL DATA
        // ============================================================

        /// @notice Maps pool ID to pool information
        /// @dev poolId is protocol-specific:
        ///      V4: PoolId.unwrap(poolKey.toId())
        ///      V3: keccak256(abi.encode(pool, tickLower, tickUpper))
        ///      Curve: keccak256(abi.encode(pool, gauge))
        mapping(bytes32 => PoolInfo) pools;
        // ============================================================
        //                       CYCLE DATA
        // ============================================================

        /// @notice Current active cycle ID for each pool
        /// @dev poolId → current cycle number (1, 2, 3...)
        /// Returns 0 if no cycle has started yet
        mapping(bytes32 => uint256) currentCycleId;
        /// @notice All cycle data for each pool
        /// @dev poolId → cycleId → cycle information
        /// Cycles are never deleted, allowing historical data access
        mapping(bytes32 => mapping(uint256 => CycleInfo)) cycles;
        // ============================================================
        //                    ACTIVE TOKEN MAPPINGS
        // ============================================================

        /// @notice Current active PT token for each pool
        /// @dev poolId → current PT address
        /// Updated when new cycle starts
        /// Returns address(0) if no cycle started
        mapping(bytes32 => address) activePT;
        /// @notice Current active YT token for each pool
        /// @dev poolId → current YT address
        /// Updated when new cycle starts
        mapping(bytes32 => address) activeYT;
        // ============================================================
        //                     REVERSE MAPPINGS
        // ============================================================

        /// @notice Get pool ID from PT token address
        /// @dev Used by upgrade functions to find pool from old PT
        mapping(address => bytes32) ptToPoolId;
        /// @notice Get cycle ID from PT token address
        /// @dev Used to determine if PT belongs to current or past cycle
        mapping(address => uint256) ptToCycleId;
        // ============================================================
        //                       YIELD SYSTEM
        // ============================================================

        /// @notice Yield state for each cycle
        /// @dev poolId → cycleId → yield state
        mapping(bytes32 => mapping(uint256 => CycleYieldState)) cycleYieldStates;
        /// @notice User yield checkpoints
        /// @dev poolId → cycleId → user → checkpoint
        mapping(bytes32 => mapping(uint256 => mapping(address => UserYieldCheckpoint))) userYieldCheckpoints;
        // ============================================================
        //                    SECONDARY MARKET
        // ============================================================

        /// @notice Secondary market info for each cycle
        /// @dev poolId → cycleId → market info
        /// Created when cycle starts, status transitions:
        /// PENDING → ACTIVE (first LP) → EXPIRED (maturity)
        mapping(bytes32 => mapping(uint256 => YieldForgeMarketInfo)) yieldForgeMarkets;
        /// @notice LP share balances in secondary markets
        /// @dev poolId → cycleId → user → LP balance
        /// Used for proportional fee distribution on withdrawal
        mapping(bytes32 => mapping(uint256 => mapping(address => uint256))) yieldForgeLpBalances;
        // ============================================================
        //                      ACCESS CONTROL
        // ============================================================

        /// @notice Address that receives protocol fees
        /// @dev Can be a treasury multisig or fee distributor contract
        address protocolFeeRecipient;
        /// @notice Address that can ban/unban pools
        /// @dev Separate from owner for faster emergency response
        /// Can be set/changed only by owner
        address poolGuardian;
        // Note: Pool ban status is stored in PoolInfo.isBanned
        // Single source of truth for pool banning in the struct itself
        // ============================================================
        //                   PROTOCOL CONFIGURATION
        // ============================================================

        // Note: Protocol fees (mint fee, yield fee) are defined as constants
        // in ProtocolFees.sol library, not in storage.
        // This ensures fees can only be changed via contract redeploy.

        /// @notice Mapping of approved adapters
        /// @dev adapter address → isApproved
        /// Only approved adapters can be used for pool registration
        mapping(address => bool) approvedAdapters;
        /// @notice Mapping of approved quote tokens for secondary markets
        /// @dev token address → isApproved
        /// Whitelist: USDC, WETH, DAI etc.
        /// At least one pool token must be whitelisted for registration
        mapping(address => bool) approvedQuoteTokens;
        /// @notice Flag indicating if protocol is initialized
        /// @dev Set to true after first successful initialize() call
        bool initialized;
        // ============================================================
        //                  YT ORDERBOOK STORAGE
        // ============================================================

        /// @notice All YT orders by ID
        /// @dev orderId → YTOrder
        mapping(uint256 => YTOrder) ytOrders;
        /// @notice Next order ID (auto-incrementing)
        uint256 ytOrderbookNextId;
        /// @notice Escrow for buy orders (quote tokens locked)
        /// @dev orderId → escrowed quote amount
        mapping(uint256 => uint256) ytOrderEscrow;
        /// @notice Orders by pool (for getActiveOrders view)
        /// @dev poolId → array of order IDs
        mapping(bytes32 => uint256[]) ytOrdersByPool;
        // ============================================================
        //                     RESERVED SLOTS
        // ============================================================

        /// @notice Reserved slots for future upgrades
        /// @dev Add new fields BEFORE this gap, decrease gap size accordingly
        /// Reduced from 50 to 46 after adding YT orderbook fields
        uint256[46] __gap;
    }

    // ============================================================
    //                      STORAGE ACCESS
    // ============================================================

    /**
     * @notice Get the application storage pointer
     * @dev Uses EIP-2535 Diamond Storage pattern
     *
     * HOW IT WORKS:
     * Diamond Storage uses a unique storage slot (computed from a string)
     * to store a struct. This avoids storage collisions between facets.
     *
     * The slot is computed as: keccak256("yieldforge.app.storage")
     * This produces a random-looking 32-byte value that's used as the
     * storage position for the AppStorage struct.
     *
     * @return ds Storage pointer to AppStorage struct
     *
     * USAGE:
     * ```solidity
     * LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
     * s.pools[poolId].exists = true;
     * ```
     */
    function diamondStorage() internal pure returns (AppStorage storage ds) {
        bytes32 position = DIAMOND_STORAGE_POSITION;
        // Use assembly to set the storage slot for the struct
        // This is the standard pattern for Diamond Storage
        assembly {
            ds.slot := position
        }
    }
}
