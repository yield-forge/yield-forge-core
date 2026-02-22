// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ILiquidityAdapter} from "../interfaces/ILiquidityAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";

// Note: Uniswap V3 interfaces are defined locally because v3-periphery
// has OpenZeppelin version conflicts (uses OZ 3.x, we use OZ 5.x).

/**
 * @title INonfungiblePositionManager
 * @notice Minimal interface for Uniswap V3 NonfungiblePositionManager
 * @dev Based on @uniswap/v3-periphery but extracted to avoid OZ version conflicts.
 *      See: https://github.com/Uniswap/v3-periphery/blob/main/contracts/interfaces/INonfungiblePositionManager.sol
 */
interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}

/**
 * @title IUniswapV3Pool
 * @notice Minimal interface for Uniswap V3 Pool
 * @dev Extracted from @uniswap/v3-core to avoid importing full interface tree
 */
interface IUniswapV3Pool {
    function token0() external view returns (address);

    function token1() external view returns (address);

    function fee() external view returns (uint24);

    function tickSpacing() external view returns (int24);

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
}

/**
 * @title IUniswapV3Factory
 * @notice Minimal interface for Uniswap V3 Factory
 * @dev Used to verify pool addresses
 */
interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

/**
 * @title UniswapV3Adapter
 * @author Yield Forge Team
 * @notice Adapter for Uniswap V3 liquidity operations
 * @dev Implements ILiquidityAdapter for Uniswap V3 pools
 *
 * ARCHITECTURE:
 * -------------
 * Uniswap V3 uses NFT positions (ERC721) to represent liquidity.
 * This adapter manages a single NFT position per pool for the Diamond.
 *
 * KEY DIFFERENCES FROM V4:
 * - V3 uses NFT positions, V4 uses direct pool state
 * - V3 has separate NonfungiblePositionManager, V4 has PoolManager
 * - V3 positions are ERC721, owned by this adapter
 * - V3 fees are collected via collect(), V4 via poke
 *
 * POSITION MANAGEMENT:
 * --------------------
 * For each pool, we maintain one NFT position:
 * - First addLiquidity() mints a new NFT
 * - Subsequent addLiquidity() increases the same position
 * - removeLiquidity() decreases the position
 * - Position uses full range (MIN_TICK to MAX_TICK)
 *
 * The tokenId is stored in poolParams for future operations.
 *
 * PARAMS ENCODING:
 * ----------------
 * For registration (no existing position):
 *   abi.encode(address pool)
 *
 * For operations (with existing position):
 *   abi.encode(address pool, uint256 tokenId)
 *
 * FULL RANGE POSITIONS:
 * ---------------------
 * All positions use full range ticks aligned to pool's tickSpacing.
 * This makes all LP shares equivalent, enabling fungible PT/YT.
 *
 * MIN_TICK = -887272, MAX_TICK = 887272 (aligned to tickSpacing)
 */
contract UniswapV3Adapter is ILiquidityAdapter {
    using SafeERC20 for IERC20;

    // ============================================================
    //                        CONSTANTS
    // ============================================================

    /// @notice Protocol identifier for token naming
    string private constant PROTOCOL_ID = "V3";

    /// @notice Uniswap V3 tick bounds
    int24 private constant MIN_TICK = -887272;
    int24 private constant MAX_TICK = 887272;

    /// @notice Maximum uint128 for collecting all fees
    uint128 private constant MAX_UINT128 = type(uint128).max;

    // ============================================================
    //                     STATE VARIABLES
    // ============================================================

    /// @notice Uniswap V3 NonfungiblePositionManager
    INonfungiblePositionManager public immutable positionManager;

    /// @notice Uniswap V3 Factory
    IUniswapV3Factory public immutable factory;

    /// @notice Diamond contract that can call this adapter
    address public immutable diamond;

    /// @notice Mapping from pool address to NFT token ID
    /// @dev Each pool has one position managed by this adapter
    mapping(address => uint256) public poolToTokenId;

    // ============================================================
    //                         ERRORS
    // ============================================================

    /// @notice Position NFT not found for this pool
    error PositionNotFound();

    // ============================================================
    //                        EVENTS
    // ============================================================

    event V3PositionCreated(address indexed pool, uint256 indexed tokenId, uint128 liquidity);

    event V3LiquidityAdded(
        address indexed pool, uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1
    );

    event V3LiquidityRemoved(
        address indexed pool, uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1
    );

    event V3YieldCollected(address indexed pool, uint256 indexed tokenId, uint256 yield0, uint256 yield1);

    // ============================================================
    //                       CONSTRUCTOR
    // ============================================================

    /**
     * @notice Initialize adapter with V3 contracts
     * @param _positionManager Uniswap V3 NonfungiblePositionManager address
     * @param _factory Uniswap V3 Factory address
     * @param _diamond YieldForge Diamond address
     */
    constructor(address _positionManager, address _factory, address _diamond) {
        require(_positionManager != address(0), "Zero position manager");
        require(_factory != address(0), "Zero factory");
        require(_diamond != address(0), "Zero diamond");

        positionManager = INonfungiblePositionManager(_positionManager);
        factory = IUniswapV3Factory(_factory);
        diamond = _diamond;
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
     * @notice Add liquidity to a Uniswap V3 pool
     * @dev Creates new position if none exists, otherwise increases existing
     *
     * FLOW:
     * 1. Decode params to get pool address (and optionally tokenId)
     * 2. Get pool info (tokens, fee, tickSpacing)
     * 3. If no position exists: mint new NFT
     * 4. If position exists: increase liquidity
     * 5. Return results
     *
     * IMPORTANT: Diamond must:
     * 1. Transfer tokens to this adapter before calling
     * 2. This adapter must have approved positionManager for tokens
     *
     * @param poolParams Encoded pool address: abi.encode(address pool)
     * @param amount0 Amount of token0 to deposit
     * @param amount1 Amount of token1 to deposit
     * @return liquidity LP units created
     * @return amount0Used Actual token0 used
     * @return amount1Used Actual token1 used
     */
    function addLiquidity(bytes calldata poolParams, uint256 amount0, uint256 amount1)
        external
        override
        onlyDiamond
        returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
    {
        // Decode parameters
        address pool = abi.decode(poolParams, (address));

        // Get pool info
        IUniswapV3Pool v3Pool = IUniswapV3Pool(pool);
        address token0 = v3Pool.token0();
        address token1 = v3Pool.token1();
        uint24 fee = v3Pool.fee();
        int24 tickSpacing = v3Pool.tickSpacing();

        // Calculate full range ticks
        int24 tickLower = (MIN_TICK / tickSpacing) * tickSpacing;
        int24 tickUpper = (MAX_TICK / tickSpacing) * tickSpacing;

        // Transfer tokens from Diamond to this adapter
        if (amount0 > 0) {
            IERC20(token0).safeTransferFrom(diamond, address(this), amount0);
        }
        if (amount1 > 0) {
            IERC20(token1).safeTransferFrom(diamond, address(this), amount1);
        }

        // Approve tokens to position manager
        IERC20(token0).safeIncreaseAllowance(address(positionManager), amount0);
        IERC20(token1).safeIncreaseAllowance(address(positionManager), amount1);

        uint256 tokenId = poolToTokenId[pool];

        if (tokenId == 0) {
            // No existing position - mint new NFT
            (tokenId, liquidity, amount0Used, amount1Used) =
                _mintPosition(token0, token1, fee, tickLower, tickUpper, amount0, amount1);

            // Store token ID for future operations
            poolToTokenId[pool] = tokenId;

            emit V3PositionCreated(pool, tokenId, liquidity);
        } else {
            // Existing position - increase liquidity
            (liquidity, amount0Used, amount1Used) = _increaseLiquidity(tokenId, amount0, amount1);
        }

        // Return unused tokens to diamond
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        if (balance0 > 0) {
            IERC20(token0).safeTransfer(diamond, balance0);
        }
        if (balance1 > 0) {
            IERC20(token1).safeTransfer(diamond, balance1);
        }

        emit V3LiquidityAdded(pool, tokenId, liquidity, amount0Used, amount1Used);
        emit LiquidityAdded(diamond, liquidity, amount0Used, amount1Used);
    }

    /**
     * @notice Remove liquidity from V3 position
     * @dev Decreases liquidity and collects tokens
     *
     * @param liquidity Amount of LP units to remove
     * @param params Encoded pool address
     * @return amount0 Token0 received
     * @return amount1 Token1 received
     */
    function removeLiquidity(uint128 liquidity, bytes calldata params)
        external
        override
        onlyDiamond
        returns (uint256 amount0, uint256 amount1)
    {
        address pool = abi.decode(params, (address));
        uint256 tokenId = poolToTokenId[pool];

        if (tokenId == 0) revert PositionNotFound();

        // Decrease liquidity — returns amounts owed (not yet withdrawn)
        (uint256 decreased0, uint256 decreased1) = positionManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: 0, // No slippage protection in adapter (handled by facet)
                amount1Min: 0,
                deadline: block.timestamp
            })
        );

        // Collect only the decreased amounts (NOT accumulated fees — those belong to YT holders)
        (amount0, amount1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: diamond,
                amount0Max: uint128(decreased0),
                amount1Max: uint128(decreased1)
            })
        );

        emit V3LiquidityRemoved(pool, tokenId, liquidity, amount0, amount1);
        emit LiquidityRemoved(diamond, liquidity, amount0, amount1);
    }

    /**
     * @notice Collect accumulated trading fees
     * @dev Calls collect() on the position to get pending fees
     *
     * HOW V3 FEE COLLECTION WORKS:
     * V3 accumulates fees in the position. collect() withdraws them.
     * We call with MAX_UINT128 to collect all available fees.
     *
     * @param params Encoded pool address
     * @return yield0 Fees collected in token0
     * @return yield1 Fees collected in token1
     */
    function collectYield(bytes calldata params)
        external
        override
        onlyDiamond
        returns (uint256 yield0, uint256 yield1)
    {
        address pool = abi.decode(params, (address));
        uint256 tokenId = poolToTokenId[pool];

        if (tokenId == 0) revert PositionNotFound();

        // Collect all accumulated fees
        (yield0, yield1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId, recipient: diamond, amount0Max: MAX_UINT128, amount1Max: MAX_UINT128
            })
        );

        emit V3YieldCollected(pool, tokenId, yield0, yield1);
        emit YieldCollected(diamond, yield0, yield1);
    }

    // ============================================================
    //                    INTERNAL FUNCTIONS
    // ============================================================

    /**
     * @notice Mint a new V3 position NFT
     * @dev Called on first addLiquidity for a pool
     */
    function _mintPosition(
        address token0,
        address token1,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) internal returns (uint256 tokenId, uint128 liquidity, uint256 amount0Used, uint256 amount1Used) {
        (tokenId, liquidity, amount0Used, amount1Used) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: fee,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0, // No slippage protection in adapter
                amount1Min: 0,
                recipient: address(this), // Adapter owns the NFT
                deadline: block.timestamp
            })
        );
    }

    /**
     * @notice Increase liquidity in existing position
     * @dev Called on subsequent addLiquidity calls
     */
    function _increaseLiquidity(uint256 tokenId, uint256 amount0, uint256 amount1)
        internal
        returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
    {
        (liquidity, amount0Used, amount1Used) = positionManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
    }

    // ============================================================
    //                      VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Get current liquidity in position
     * @param params Encoded pool address
     * @return liquidity Current position liquidity
     */
    function getPositionLiquidity(bytes calldata params) external view override returns (uint128 liquidity) {
        address pool = abi.decode(params, (address));
        uint256 tokenId = poolToTokenId[pool];

        if (tokenId == 0) return 0;

        // Get position info from NFT
        (,,,,,,, liquidity,,,,) = positionManager.positions(tokenId);
    }

    /**
     * @notice Get pool tokens
     * @param params Encoded pool address
     * @return token0 First token
     * @return token1 Second token
     */
    function getPoolTokens(bytes calldata params) external view override returns (address token0, address token1) {
        address pool = abi.decode(params, (address));
        IUniswapV3Pool v3Pool = IUniswapV3Pool(pool);
        token0 = v3Pool.token0();
        token1 = v3Pool.token1();
    }

    /// @notice Returns "V3" for Uniswap V3
    function protocolId() external pure override returns (string memory) {
        return PROTOCOL_ID;
    }

    /**
     * @notice Preview token amounts for removing liquidity
     * @dev Uses LiquidityAmounts to calculate amounts based on current price and full range ticks
     *
     * @param liquidity Amount of LP units to remove
     * @param params Encoded pool address
     * @return amount0 Estimated token0 to receive
     * @return amount1 Estimated token1 to receive
     */
    function previewRemoveLiquidity(uint128 liquidity, bytes calldata params)
        external
        view
        override
        returns (uint256 amount0, uint256 amount1)
    {
        address pool = abi.decode(params, (address));
        uint256 tokenId = poolToTokenId[pool];

        if (tokenId == 0) return (0, 0);

        IUniswapV3Pool v3Pool = IUniswapV3Pool(pool);
        (uint160 sqrtPriceX96,,,,,,) = v3Pool.slot0();
        int24 tickSpacing = v3Pool.tickSpacing();

        int24 tickLower = (MIN_TICK / tickSpacing) * tickSpacing;
        int24 tickUpper = (MAX_TICK / tickSpacing) * tickSpacing;

        uint160 sqrtPriceA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceB = TickMath.getSqrtPriceAtTick(tickUpper);

        (amount0, amount1) = _getAmountsForLiquidity(sqrtPriceX96, sqrtPriceA, sqrtPriceB, liquidity);
    }

    /**
     * @notice Check if pool is supported
     * @dev Validates pool exists in factory
     */
    function supportsPool(bytes calldata params) external view override returns (bool) {
        address pool = abi.decode(params, (address));

        // Verify it's a valid V3 pool by checking factory
        try IUniswapV3Pool(pool).token0() returns (address token0) {
            try IUniswapV3Pool(pool).token1() returns (address token1) {
                try IUniswapV3Pool(pool).fee() returns (uint24 fee) {
                    // Verify pool is from factory
                    address factoryPool = factory.getPool(token0, token1, fee);
                    return factoryPool == pool;
                } catch {
                    return false;
                }
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }

    /// @notice Returns NonfungiblePositionManager address
    function protocolAddress() external view override returns (address) {
        return address(positionManager);
    }

    /**
     * @notice Get token ID for a pool
     * @dev Returns 0 if no position exists
     */
    function getTokenId(address pool) external view returns (uint256) {
        return poolToTokenId[pool];
    }

    // ============================================================
    //                  PREVIEW VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Preview liquidity and amounts for adding liquidity
     * @dev Uses LiquidityAmounts to calculate exact liquidity and token usage
     * @param poolParams Encoded pool address: abi.encode(address pool)
     * @param amount0 Amount of token0 to deposit
     * @param amount1 Amount of token1 to deposit
     */
    function previewAddLiquidity(bytes calldata poolParams, uint256 amount0, uint256 amount1)
        external
        view
        override
        returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
    {
        address pool = abi.decode(poolParams, (address));

        IUniswapV3Pool v3Pool = IUniswapV3Pool(pool);
        (uint160 sqrtPriceX96,,,,,,) = v3Pool.slot0();
        int24 tickSpacing = v3Pool.tickSpacing();

        int24 tickLower = (MIN_TICK / tickSpacing) * tickSpacing;
        int24 tickUpper = (MAX_TICK / tickSpacing) * tickSpacing;

        uint160 sqrtPriceA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceB = TickMath.getSqrtPriceAtTick(tickUpper);

        liquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtPriceA, sqrtPriceB, amount0, amount1);
        (amount0Used, amount1Used) =
            _getAmountsForLiquidity(sqrtPriceX96, sqrtPriceA, sqrtPriceB, liquidity);
    }

    /**
     * @notice Calculate optimal amount1 for given amount0
     * @dev Uses current pool price via LiquidityAmounts
     */
    function calculateOptimalAmount1(uint256 amount0, bytes calldata params)
        external
        view
        override
        returns (uint256 amount1)
    {
        address pool = abi.decode(params, (address));
        IUniswapV3Pool v3Pool = IUniswapV3Pool(pool);
        (uint160 sqrtPriceX96,,,,,,) = v3Pool.slot0();
        int24 tickSpacing = v3Pool.tickSpacing();

        int24 tickLower = (MIN_TICK / tickSpacing) * tickSpacing;
        int24 tickUpper = (MAX_TICK / tickSpacing) * tickSpacing;

        uint160 sqrtPriceA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceB = TickMath.getSqrtPriceAtTick(tickUpper);

        // Get liquidity for amount0 only, then derive matching amount1
        uint128 liquidity0 = LiquidityAmounts.getLiquidityForAmount0(sqrtPriceX96, sqrtPriceB, amount0);
        (, amount1) = _getAmountsForLiquidity(sqrtPriceX96, sqrtPriceA, sqrtPriceB, liquidity0);
    }

    /**
     * @notice Calculate optimal amount0 for given amount1
     * @dev Uses current pool price via LiquidityAmounts
     */
    function calculateOptimalAmount0(uint256 amount1, bytes calldata params)
        external
        view
        override
        returns (uint256 amount0)
    {
        address pool = abi.decode(params, (address));
        IUniswapV3Pool v3Pool = IUniswapV3Pool(pool);
        (uint160 sqrtPriceX96,,,,,,) = v3Pool.slot0();
        int24 tickSpacing = v3Pool.tickSpacing();

        int24 tickLower = (MIN_TICK / tickSpacing) * tickSpacing;
        int24 tickUpper = (MAX_TICK / tickSpacing) * tickSpacing;

        uint160 sqrtPriceA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceB = TickMath.getSqrtPriceAtTick(tickUpper);

        // Get liquidity for amount1 only, then derive matching amount0
        uint128 liquidity1 = LiquidityAmounts.getLiquidityForAmount1(sqrtPriceA, sqrtPriceX96, amount1);
        (amount0,) = _getAmountsForLiquidity(sqrtPriceX96, sqrtPriceA, sqrtPriceB, liquidity1);
    }

    /**
     * @notice Get current pool price
     * @dev Reads sqrtPriceX96 and tick from V3 pool's slot0
     */
    function getPoolPrice(bytes calldata params) external view override returns (uint160 sqrtPriceX96, int24 tick) {
        address pool = abi.decode(params, (address));
        (sqrtPriceX96, tick,,,,,) = IUniswapV3Pool(pool).slot0();
    }

    /**
     * @notice Get pool fee tier
     */
    function getPoolFee(bytes calldata params) external view override returns (uint24 fee) {
        address pool = abi.decode(params, (address));
        fee = IUniswapV3Pool(pool).fee();
    }

    // ============================================================
    //                     TVL VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Get current value of YieldForge position in token amounts
     * @dev Uses LiquidityAmounts to calculate exact amounts based on current price
     *
     * @param params Encoded pool address
     * @return amount0 Value of our position in token0
     * @return amount1 Value of our position in token1
     */
    function getPositionValue(bytes calldata params) external view override returns (uint256 amount0, uint256 amount1) {
        address pool = abi.decode(params, (address));
        uint256 tokenId = poolToTokenId[pool];

        if (tokenId == 0) return (0, 0);

        (,,,,,,, uint128 positionLiquidity,,,,) = positionManager.positions(tokenId);

        if (positionLiquidity == 0) return (0, 0);

        IUniswapV3Pool v3Pool = IUniswapV3Pool(pool);
        (uint160 sqrtPriceX96,,,,,,) = v3Pool.slot0();
        int24 tickSpacing = v3Pool.tickSpacing();

        int24 tickLower = (MIN_TICK / tickSpacing) * tickSpacing;
        int24 tickUpper = (MAX_TICK / tickSpacing) * tickSpacing;

        uint160 sqrtPriceA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceB = TickMath.getSqrtPriceAtTick(tickUpper);

        (amount0, amount1) = _getAmountsForLiquidity(
            sqrtPriceX96, sqrtPriceA, sqrtPriceB, positionLiquidity
        );
    }

    /**
     * @notice Get total value locked in the underlying pool
     * @dev Returns total token balances held by the V3 pool contract
     *
     * @param params Encoded pool address
     * @return amount0 Total token0 in the pool
     * @return amount1 Total token1 in the pool
     */
    function getPoolTotalValue(bytes calldata params)
        external
        view
        override
        returns (uint256 amount0, uint256 amount1)
    {
        address pool = abi.decode(params, (address));
        IUniswapV3Pool v3Pool = IUniswapV3Pool(pool);

        // V3 pools hold tokens directly, so balanceOf gives us TVL
        amount0 = IERC20(v3Pool.token0()).balanceOf(pool);
        amount1 = IERC20(v3Pool.token1()).balanceOf(pool);
    }

    // ============================================================
    //                    INTERNAL FUNCTIONS
    // ============================================================

    /**
     * @notice Calculate token amounts for given liquidity
     * @dev Uses SqrtPriceMath (same math as V4 adapter)
     */
    function _getAmountsForLiquidity(uint160 sqrtPriceX96, uint160 sqrtPriceA, uint160 sqrtPriceB, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (sqrtPriceX96 <= sqrtPriceA) {
            int256 delta0 = SqrtPriceMath.getAmount0Delta(sqrtPriceA, sqrtPriceB, int128(liquidity));
            amount0 = delta0 > 0 ? uint256(delta0) : uint256(-delta0);
        } else if (sqrtPriceX96 >= sqrtPriceB) {
            int256 delta1 = SqrtPriceMath.getAmount1Delta(sqrtPriceA, sqrtPriceB, int128(liquidity));
            amount1 = delta1 > 0 ? uint256(delta1) : uint256(-delta1);
        } else {
            int256 delta0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtPriceB, int128(liquidity));
            int256 delta1 = SqrtPriceMath.getAmount1Delta(sqrtPriceA, sqrtPriceX96, int128(liquidity));
            amount0 = delta0 > 0 ? uint256(delta0) : uint256(-delta0);
            amount1 = delta1 > 0 ? uint256(delta1) : uint256(-delta1);
        }
    }
}
