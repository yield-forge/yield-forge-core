// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * @title ILiquidityAdapter
 * @author Yield Forge Team
 * @notice Interface for liquidity protocol adapters (Uniswap V4, V3, etc.)
 * @dev Each adapter implements protocol-specific logic for:
 *      - Adding/removing liquidity
 *      - Collecting yield (swap fees, rewards)
 *      - Querying position state
 *
 * ARCHITECTURE OVERVIEW:
 * ----------------------
 * YieldForge uses adapters to abstract away differences between DeFi protocols.
 * This allows the core protocol (Diamond facets) to work with any supported
 * liquidity source without knowing protocol-specific details.
 *
 * Example flow for adding liquidity:
 * 1. User calls LiquidityFacet.addLiquidity(poolId, amount0, amount1)
 * 2. LiquidityFacet looks up the adapter address for this pool
 * 3. LiquidityFacet calls adapter.addLiquidity(encodedParams)
 * 4. Adapter handles protocol-specific logic (e.g., V4 unlock callback)
 * 5. Adapter returns liquidity amount to LiquidityFacet
 * 6. LiquidityFacet mints PT/YT tokens to user
 *
 * PARAMS ENCODING:
 * ----------------
 * Each adapter defines its own params structure. Examples:
 *
 * UniswapV4Adapter params:
 *   abi.encode(PoolKey poolKey, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1)
 *
 * UniswapV3Adapter params:
 *   abi.encode(address pool, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1)
 *
 * SECURITY CONSIDERATIONS:
 * ------------------------
 * - Adapters should only be callable by the Diamond contract
 * - Adapters must validate all input parameters
 * - Adapters should handle slippage protection where applicable
 */
interface ILiquidityAdapter {
    // ============================================================
    //                           EVENTS
    // ============================================================

    /**
     * @notice Emitted when liquidity is added through the adapter
     * @param caller Address that initiated the operation (should be Diamond)
     * @param liquidity Amount of LP units created
     * @param amount0Used Actual amount of token0 used
     * @param amount1Used Actual amount of token1 used
     */
    event LiquidityAdded(address indexed caller, uint128 liquidity, uint256 amount0Used, uint256 amount1Used);

    /**
     * @notice Emitted when liquidity is removed through the adapter
     * @param caller Address that initiated the operation (should be Diamond)
     * @param liquidity Amount of LP units removed
     * @param amount0Received Amount of token0 received
     * @param amount1Received Amount of token1 received
     */
    event LiquidityRemoved(address indexed caller, uint128 liquidity, uint256 amount0Received, uint256 amount1Received);

    /**
     * @notice Emitted when yield (fees/rewards) is collected
     * @param caller Address that initiated the operation (should be Diamond)
     * @param yield0 Amount of token0 collected as yield
     * @param yield1 Amount of token1 collected as yield
     */
    event YieldCollected(address indexed caller, uint256 yield0, uint256 yield1);

    // ============================================================
    //                          ERRORS
    // ============================================================

    /// @notice Caller is not authorized (not the Diamond contract)
    error UnauthorizedCaller();

    /// @notice Invalid parameters provided
    error InvalidParams();

    /// @notice Pool does not exist or is not supported
    error PoolNotSupported();

    /// @notice Slippage tolerance exceeded
    error SlippageExceeded();

    /// @notice Insufficient liquidity for the operation
    error InsufficientLiquidity();

    // ============================================================
    //                    LIQUIDITY OPERATIONS
    // ============================================================

    /**
     * @notice Add liquidity to the underlying protocol
     * @dev Called by LiquidityFacet when user adds liquidity
     *
     * IMPORTANT: Before calling this function, the Diamond must:
     * 1. Transfer tokens from user to Diamond
     * 2. Approve tokens for the adapter (or underlying protocol)
     *
     * The adapter is responsible for:
     * 1. Decoding params to get protocol-specific data
     * 2. Calling the underlying protocol to add liquidity
     * 3. Returning unused tokens to the Diamond (for refund to user)
     *
     * @param params Encoded parameters specific to this adapter
     *               See adapter implementation for exact encoding
     * @return liquidity Amount of LP units created (protocol-specific meaning)
     *                   For Uniswap: liquidity in the mathematical sense
     * @return amount0Used Actual amount of token0 deposited into the pool
     * @return amount1Used Actual amount of token1 deposited into the pool
     */
    function addLiquidity(bytes calldata params)
        external
        returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used);

    /**
     * @notice Remove liquidity from the underlying protocol
     * @dev Called by RedemptionFacet when user redeems PT tokens
     *
     * The adapter is responsible for:
     * 1. Removing liquidity from the underlying protocol
     * 2. Transferring received tokens to the Diamond
     *
     * @param liquidity Amount of LP units to remove
     * @param params Additional parameters (e.g., minimum amounts for slippage)
     * @return amount0 Amount of token0 received from the pool
     * @return amount1 Amount of token1 received from the pool
     */
    function removeLiquidity(uint128 liquidity, bytes calldata params)
        external
        returns (uint256 amount0, uint256 amount1);

    /**
     * @notice Collect accumulated yield (fees, rewards) from the position
     * @dev Called by YieldAccumulatorFacet during poke/harvest
     *
     * What counts as "yield" depends on the protocol:
     * - Uniswap V3/V4: Accumulated swap fees
     *
     * @param params Parameters for yield collection (e.g., pool identifier)
     * @return yield0 Amount of token0 collected as yield
     * @return yield1 Amount of token1 collected as yield
     */
    function collectYield(bytes calldata params) external returns (uint256 yield0, uint256 yield1);

    // ============================================================
    //                       VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Get current liquidity amount for a position
     * @dev Used to calculate user's share of the pool
     *
     * @param params Parameters identifying the position
     * @return liquidity Current liquidity amount
     */
    function getPositionLiquidity(bytes calldata params) external view returns (uint128 liquidity);

    /**
     * @notice Get the token addresses for a pool
     * @dev Used during pool registration to store token info
     *
     * Returns (token0, token1) in sorted order (lower address first for Uniswap)
     *
     * @param params Parameters identifying the pool
     * @return token0 First token address (lower address for Uniswap)
     * @return token1 Second token address
     */
    function getPoolTokens(bytes calldata params) external view returns (address token0, address token1);

    /**
     * @notice Preview how much tokens would be received for removing liquidity
     * @dev Used by RedemptionFacet for slippage calculation
     *
     * This function estimates the amount of tokens that would be received
     * when removing the specified amount of liquidity. The actual amounts
     * may differ slightly due to price movements between preview and execution.
     *
     * @param liquidity Amount of LP units to remove
     * @param params Additional parameters (e.g., pool identifier)
     * @return amount0 Estimated amount of token0 to receive
     * @return amount1 Estimated amount of token1 to receive
     */
    function previewRemoveLiquidity(uint128 liquidity, bytes calldata params)
        external
        view
        returns (uint256 amount0, uint256 amount1);

    /**
     * @notice Preview liquidity and token amounts for adding liquidity
     * @dev Used by UI to show expected PT/YT tokens before transaction
     *
     * This function estimates:
     * - How much liquidity will be created
     * - Actual token amounts that will be used (may differ from input)
     *
     * Uses current pool price to calculate optimal amounts
     *
     * @param params Encoded pool parameters + token amounts
     *               Format: abi.encode(poolKey, amount0, amount1) for Uniswap
     * @return liquidity Expected LP units to be created
     * @return amount0Used Actual amount of token0 that will be deposited
     * @return amount1Used Actual amount of token1 that will be deposited
     */
    function previewAddLiquidity(bytes calldata params)
        external
        view
        returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used);

    /**
     * @notice Calculate optimal amount of token1 for given amount of token0
     * @dev Used by UI for auto-sync of input fields based on pool price
     *
     * When user enters amount0, UI calls this to get corresponding amount1.
     * This ensures no tokens are wasted (refunded) during add liquidity.
     *
     * @param amount0 Amount of token0 user wants to deposit
     * @param params Pool parameters
     * @return amount1 Optimal amount of token1 to match the ratio
     */
    function calculateOptimalAmount1(uint256 amount0, bytes calldata params) external view returns (uint256 amount1);

    /**
     * @notice Calculate optimal amount of token0 for given amount of token1
     * @dev Mirror of calculateOptimalAmount1 for reverse calculation
     *
     * @param amount1 Amount of token1 user wants to deposit
     * @param params Pool parameters
     * @return amount0 Optimal amount of token0 to match the ratio
     */
    function calculateOptimalAmount0(uint256 amount1, bytes calldata params) external view returns (uint256 amount0);

    /**
     * @notice Get current pool price information
     * @dev Used by UI to display current price and calculate conversions
     *
     * @param params Pool parameters
     * @return sqrtPriceX96 Current sqrt price in Q96 format (Uniswap style)
     * @return tick Current tick (for Uniswap pools)
     */
    function getPoolPrice(bytes calldata params) external view returns (uint160 sqrtPriceX96, int24 tick);

    /**
     * @notice Get pool fee tier
     * @dev Used by UI to display pool fee
     *
     * @param params Pool parameters
     * @return fee Fee in hundredths of a bip (e.g., 3000 = 0.3%)
     */
    function getPoolFee(bytes calldata params) external view returns (uint24 fee);

    /**
     * @notice Get the protocol identifier string
     * @dev Used in token naming: YF-PT-[PROTOCOL]-[HASH]-[DATE]
     *
     * Standard identifiers:
     * - "V4" for Uniswap V4
     * - "V3" for Uniswap V3
     *
     * @return Protocol identifier string (2-4 characters recommended)
     */
    function protocolId() external pure returns (string memory);

    /**
     * @notice Check if adapter supports a specific pool
     * @dev Used during pool registration to validate the pool
     *
     * @param params Encoded pool parameters
     * @return True if the pool is supported by this adapter
     */
    function supportsPool(bytes calldata params) external view returns (bool);

    /**
     * @notice Get current value of YieldForge position in token amounts
     * @dev Returns how much of each token the current YF position is worth at current prices.
     *      This is used to calculate "Yield Forge TVL" - the value locked through our protocol.
     *
     *      Implementation varies by protocol:
     *      - UniswapV4: Uses getLiquidityForAmounts with current price and our position's liquidity
     *      - UniswapV3: Similar calculation using position's liquidity from NFT
     *
     * @param params Pool parameters (same format as other view functions)
     * @return amount0 Value of our position in token0
     * @return amount1 Value of our position in token1
     */
    function getPositionValue(bytes calldata params) external view returns (uint256 amount0, uint256 amount1);

    /**
     * @notice Get total value locked in the underlying pool
     * @dev Returns the total amounts of tokens in the pool (not just YF position).
     *      This is used to calculate "Pool Total TVL" - the entire pool's liquidity.
     *
     *      Implementation varies by protocol:
     *      - UniswapV4: Pool's total liquidity converted to token amounts
     *      - UniswapV3: Token balances held by the pool contract
     *
     * @param params Pool parameters (same format as other view functions)
     * @return amount0 Total token0 in the pool
     * @return amount1 Total token1 in the pool
     */
    function getPoolTotalValue(bytes calldata params) external view returns (uint256 amount0, uint256 amount1);

    /**
     * @notice Get the address of the underlying protocol's main contract
     * @dev Useful for verification and debugging
     *
     * Examples:
     * - UniswapV4Adapter: PoolManager address
     * - UniswapV3Adapter: NonfungiblePositionManager address
     *
     * @return Address of the main protocol contract
     */
    function protocolAddress() external view returns (address);
}
