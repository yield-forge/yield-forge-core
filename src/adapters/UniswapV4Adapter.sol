// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ILiquidityAdapter} from "../interfaces/ILiquidityAdapter.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";

/**
 * @title UniswapV4Adapter
 * @author Yield Forge Team
 * @notice Adapter for Uniswap V4 liquidity operations
 * @dev Implements ILiquidityAdapter for Uniswap V4 pools
 *
 * ARCHITECTURE:
 * -------------
 * This adapter handles all Uniswap V4-specific logic:
 * - unlock() callback pattern for atomic operations
 * - Full range liquidity positions (MIN_TICK to MAX_TICK)
 * - Fee collection via "poke" mechanism (modifyLiquidity with delta=0)
 *
 * UNISWAP V4 UNLOCK PATTERN:
 * --------------------------
 * V4 uses a "flash accounting" model where all operations must happen
 * inside an unlock() callback. The flow is:
 *
 * 1. Call poolManager.unlock(data)
 * 2. PoolManager calls back unlockCallback(data)
 * 3. Inside callback: modify liquidity, settle/take tokens
 * 4. PoolManager verifies all balances are settled
 * 5. unlock() returns
 *
 * PARAMS ENCODING:
 * ----------------
 * This adapter expects params to be encoded as:
 *   abi.encode(PoolKey poolKey)
 *
 * Where PoolKey contains:
 * - currency0: First token (lower address)
 * - currency1: Second token
 * - fee: Fee tier (e.g., 3000 = 0.3%)
 * - tickSpacing: Tick spacing for the pool
 * - hooks: Hook contract (address(0) for no hooks)
 *
 * FULL RANGE LIQUIDITY:
 * ---------------------
 * All positions use the maximum possible range:
 * - tickLower = MIN_TICK aligned to tickSpacing
 * - tickUpper = MAX_TICK aligned to tickSpacing
 *
 * This ensures all liquidity providers earn the same fee share,
 * making PT/YT tokens fungible across all depositors.
 *
 * SECURITY:
 * ---------
 * - Only the Diamond contract should call this adapter
 * - All token transfers use SafeERC20
 * - Callback validates msg.sender is PoolManager
 */
contract UniswapV4Adapter is ILiquidityAdapter, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    // ============================================================
    //                        CONSTANTS
    // ============================================================

    /// @notice Protocol identifier for token naming
    string private constant PROTOCOL_ID = "V4";

    // ============================================================
    //                     STATE VARIABLES
    // ============================================================

    /// @notice Uniswap V4 PoolManager contract
    /// @dev Set in constructor, immutable
    IPoolManager public immutable poolManager;

    /// @notice Diamond contract that can call this adapter
    /// @dev Only this address can invoke liquidity operations
    address public immutable diamond;

    // ============================================================
    //                   CALLBACK DATA TYPES
    // ============================================================

    /// @notice Type of operation for unlock callback
    enum CallbackType {
        ADD_LIQUIDITY,
        REMOVE_LIQUIDITY,
        COLLECT_YIELD
    }

    /// @notice Data passed to unlock callback
    struct CallbackData {
        CallbackType callbackType;
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0;
        uint256 amount1;
        uint128 liquidity;
        address recipient;
    }

    // ============================================================
    //                         ERRORS
    // ============================================================

    /// @notice Callback caller is not PoolManager
    error UnauthorizedCallback();

    /// @notice Invalid pool key provided
    error InvalidPoolKey();

    // ============================================================
    //                        EVENTS
    // ============================================================

    event V4LiquidityAdded(
        PoolId indexed poolId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );

    event V4LiquidityRemoved(
        PoolId indexed poolId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );

    event V4YieldCollected(
        PoolId indexed poolId,
        uint256 yield0,
        uint256 yield1
    );

    // ============================================================
    //                       CONSTRUCTOR
    // ============================================================

    /**
     * @notice Initialize the adapter with PoolManager and Diamond addresses
     * @param _poolManager Uniswap V4 PoolManager contract
     * @param _diamond YieldForge Diamond contract
     */
    constructor(address _poolManager, address _diamond) {
        require(_poolManager != address(0), "Zero pool manager");
        require(_diamond != address(0), "Zero diamond");

        poolManager = IPoolManager(_poolManager);
        diamond = _diamond;
    }

    // ============================================================
    //                        MODIFIERS
    // ============================================================

    /// @notice Restrict access to Diamond contract only
    modifier onlyDiamond() {
        if (msg.sender != diamond) revert UnauthorizedCaller();
        _;
    }

    // ============================================================
    //                   LIQUIDITY OPERATIONS
    // ============================================================

    /**
     * @notice Add liquidity to a Uniswap V4 pool
     * @dev Uses full range position (MIN_TICK to MAX_TICK)
     *
     * FLOW:
     * 1. Decode params to get PoolKey
     * 2. Transfer tokens from Diamond to this adapter
     * 3. Calculate full range ticks
     * 4. Call poolManager.unlock() with callback data
     * 5. In callback: modifyLiquidity, settle tokens
     * 6. Return liquidity amount and actual token usage
     *
     * IMPORTANT: Diamond must approve tokens to this adapter before calling
     *
     * @param params Encoded PoolKey and token amounts
     *               abi.encode(PoolKey poolKey, uint256 amount0, uint256 amount1)
     * @return liquidity Amount of LP units created
     * @return amount0Used Actual token0 deposited
     * @return amount1Used Actual token1 deposited
     */
    function addLiquidity(
        bytes calldata params
    )
        external
        override
        onlyDiamond
        returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
    {
        // Decode parameters
        (PoolKey memory poolKey, uint256 amount0, uint256 amount1) = abi.decode(
            params,
            (PoolKey, uint256, uint256)
        );

        // Transfer tokens from Diamond to this adapter
        // Diamond has already approved these tokens to this adapter
        if (amount0 > 0) {
            IERC20(Currency.unwrap(poolKey.currency0)).safeTransferFrom(
                diamond,
                address(this),
                amount0
            );
        }
        if (amount1 > 0) {
            IERC20(Currency.unwrap(poolKey.currency1)).safeTransferFrom(
                diamond,
                address(this),
                amount1
            );
        }

        // Calculate full range ticks aligned to tickSpacing
        int24 tickLower = (TickMath.MIN_TICK / poolKey.tickSpacing) *
            poolKey.tickSpacing;
        int24 tickUpper = (TickMath.MAX_TICK / poolKey.tickSpacing) *
            poolKey.tickSpacing;

        // Prepare callback data
        CallbackData memory data = CallbackData({
            callbackType: CallbackType.ADD_LIQUIDITY,
            poolKey: poolKey,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0: amount0,
            amount1: amount1,
            liquidity: 0, // Will be calculated in callback
            recipient: diamond // Unused tokens returned here
        });

        // Execute via unlock pattern
        bytes memory result = poolManager.unlock(abi.encode(data));

        // Decode results
        (liquidity, amount0Used, amount1Used) = abi.decode(
            result,
            (uint128, uint256, uint256)
        );

        emit V4LiquidityAdded(
            poolKey.toId(),
            liquidity,
            amount0Used,
            amount1Used
        );
        emit LiquidityAdded(diamond, liquidity, amount0Used, amount1Used);
    }

    /**
     * @notice Remove liquidity from a Uniswap V4 pool
     * @dev Removes specified liquidity amount and returns tokens
     *
     * @param liquidity Amount of LP units to remove
     * @param params Encoded PoolKey
     * @return amount0 Token0 received from pool
     * @return amount1 Token1 received from pool
     */
    function removeLiquidity(
        uint128 liquidity,
        bytes calldata params
    ) external override onlyDiamond returns (uint256 amount0, uint256 amount1) {
        // Decode pool key
        PoolKey memory poolKey = abi.decode(params, (PoolKey));

        // Calculate full range ticks
        int24 tickLower = (TickMath.MIN_TICK / poolKey.tickSpacing) *
            poolKey.tickSpacing;
        int24 tickUpper = (TickMath.MAX_TICK / poolKey.tickSpacing) *
            poolKey.tickSpacing;

        // Prepare callback data
        CallbackData memory data = CallbackData({
            callbackType: CallbackType.REMOVE_LIQUIDITY,
            poolKey: poolKey,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0: 0,
            amount1: 0,
            liquidity: liquidity,
            recipient: diamond
        });

        // Execute via unlock pattern
        bytes memory result = poolManager.unlock(abi.encode(data));

        // Decode results
        (amount0, amount1) = abi.decode(result, (uint256, uint256));

        emit V4LiquidityRemoved(poolKey.toId(), liquidity, amount0, amount1);
        emit LiquidityRemoved(diamond, liquidity, amount0, amount1);
    }

    /**
     * @notice Collect accumulated yield (swap fees) from position
     * @dev Uses "poke" technique: modifyLiquidity with delta=0
     *
     * HOW POKE WORKS:
     * When you call modifyLiquidity with liquidityDelta=0, Uniswap V4
     * doesn't change your position but DOES return any accumulated
     * fees as the BalanceDelta. This is how we harvest yield.
     *
     * @param params Encoded PoolKey
     * @return yield0 Fees collected in token0
     * @return yield1 Fees collected in token1
     */
    function collectYield(
        bytes calldata params
    ) external override onlyDiamond returns (uint256 yield0, uint256 yield1) {
        // Decode pool key
        PoolKey memory poolKey = abi.decode(params, (PoolKey));

        // Calculate full range ticks
        int24 tickLower = (TickMath.MIN_TICK / poolKey.tickSpacing) *
            poolKey.tickSpacing;
        int24 tickUpper = (TickMath.MAX_TICK / poolKey.tickSpacing) *
            poolKey.tickSpacing;

        // Prepare callback data
        CallbackData memory data = CallbackData({
            callbackType: CallbackType.COLLECT_YIELD,
            poolKey: poolKey,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0: 0,
            amount1: 0,
            liquidity: 0, // Zero delta = poke
            recipient: diamond
        });

        // Execute via unlock pattern
        bytes memory result = poolManager.unlock(abi.encode(data));

        // Decode results
        (yield0, yield1) = abi.decode(result, (uint256, uint256));

        emit V4YieldCollected(poolKey.toId(), yield0, yield1);
        emit YieldCollected(diamond, yield0, yield1);
    }

    // ============================================================
    //                     UNLOCK CALLBACK
    // ============================================================

    /**
     * @notice Callback from PoolManager during unlock()
     * @dev This is where actual pool operations happen
     *
     * IMPORTANT: Only PoolManager can call this function.
     * The callback type determines which operation to perform.
     *
     * @param data Encoded CallbackData struct
     * @return Result data (varies by operation type)
     */
    function unlockCallback(
        bytes calldata data
    ) external override returns (bytes memory) {
        // Verify caller is PoolManager
        if (msg.sender != address(poolManager)) revert UnauthorizedCallback();

        // Decode callback data
        CallbackData memory cbData = abi.decode(data, (CallbackData));

        // Route to appropriate handler
        if (cbData.callbackType == CallbackType.ADD_LIQUIDITY) {
            return _handleAddLiquidity(cbData);
        } else if (cbData.callbackType == CallbackType.REMOVE_LIQUIDITY) {
            return _handleRemoveLiquidity(cbData);
        } else {
            return _handleCollectYield(cbData);
        }
    }

    /**
     * @notice Handle add liquidity inside unlock callback
     * @dev Calculates liquidity from amounts, adds to pool, settles tokens
     */
    function _handleAddLiquidity(
        CallbackData memory data
    ) internal returns (bytes memory) {
        // Get current pool price
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(
            data.poolKey.toId()
        );

        // Calculate liquidity from token amounts
        // LiquidityAmounts.getLiquidityForAmounts determines how much "liquidity"
        // can be minted given the token amounts and current price
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(data.tickLower),
            TickMath.getSqrtPriceAtTick(data.tickUpper),
            data.amount0,
            data.amount1
        );

        // Add liquidity to pool
        // modifyLiquidity returns the delta (tokens owed to/from pool)
        (BalanceDelta delta, ) = poolManager.modifyLiquidity(
            data.poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: data.tickLower,
                tickUpper: data.tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );

        // Settle negative deltas (tokens we owe to pool)
        // delta.amount0() < 0 means we need to pay token0
        uint256 amount0Used = 0;
        uint256 amount1Used = 0;

        if (delta.amount0() < 0) {
            amount0Used = uint256(uint128(-delta.amount0()));
            _settleToken(data.poolKey.currency0, amount0Used);
        }
        if (delta.amount1() < 0) {
            amount1Used = uint256(uint128(-delta.amount1()));
            _settleToken(data.poolKey.currency1, amount1Used);
        }

        // Take positive deltas (fees from existing position, rare on add)
        if (delta.amount0() > 0) {
            poolManager.take(
                data.poolKey.currency0,
                data.recipient,
                uint256(uint128(delta.amount0()))
            );
        }
        if (delta.amount1() > 0) {
            poolManager.take(
                data.poolKey.currency1,
                data.recipient,
                uint256(uint128(delta.amount1()))
            );
        }

        // Return unused tokens to recipient
        if (data.amount0 > amount0Used) {
            IERC20(Currency.unwrap(data.poolKey.currency0)).safeTransfer(
                data.recipient,
                data.amount0 - amount0Used
            );
        }
        if (data.amount1 > amount1Used) {
            IERC20(Currency.unwrap(data.poolKey.currency1)).safeTransfer(
                data.recipient,
                data.amount1 - amount1Used
            );
        }

        return abi.encode(liquidity, amount0Used, amount1Used);
    }

    /**
     * @notice Handle remove liquidity inside unlock callback
     * @dev Removes liquidity from pool, takes tokens
     */
    function _handleRemoveLiquidity(
        CallbackData memory data
    ) internal returns (bytes memory) {
        // Remove liquidity (negative liquidityDelta)
        (BalanceDelta delta, ) = poolManager.modifyLiquidity(
            data.poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: data.tickLower,
                tickUpper: data.tickUpper,
                liquidityDelta: -int256(uint256(data.liquidity)),
                salt: bytes32(0)
            }),
            ""
        );

        // Take positive deltas (tokens we receive from pool)
        uint256 amount0 = 0;
        uint256 amount1 = 0;

        if (delta.amount0() > 0) {
            amount0 = uint256(uint128(delta.amount0()));
            poolManager.take(data.poolKey.currency0, data.recipient, amount0);
        }
        if (delta.amount1() > 0) {
            amount1 = uint256(uint128(delta.amount1()));
            poolManager.take(data.poolKey.currency1, data.recipient, amount1);
        }

        return abi.encode(amount0, amount1);
    }

    /**
     * @notice Handle yield collection inside unlock callback
     * @dev Uses poke (delta=0) to collect accumulated fees
     */
    function _handleCollectYield(
        CallbackData memory data
    ) internal returns (bytes memory) {
        // "Poke" the position: modifyLiquidity with 0 delta
        // This triggers fee collection without changing position size
        (BalanceDelta delta, ) = poolManager.modifyLiquidity(
            data.poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: data.tickLower,
                tickUpper: data.tickUpper,
                liquidityDelta: 0, // Zero = poke
                salt: bytes32(0)
            }),
            ""
        );

        // Take positive deltas (accumulated fees)
        uint256 yield0 = 0;
        uint256 yield1 = 0;

        if (delta.amount0() > 0) {
            yield0 = uint256(uint128(delta.amount0()));
            poolManager.take(data.poolKey.currency0, data.recipient, yield0);
        }
        if (delta.amount1() > 0) {
            yield1 = uint256(uint128(delta.amount1()));
            poolManager.take(data.poolKey.currency1, data.recipient, yield1);
        }

        return abi.encode(yield0, yield1);
    }

    /**
     * @notice Settle token payment to PoolManager
     * @dev sync() + transfer() + settle() pattern
     */
    function _settleToken(Currency currency, uint256 amount) internal {
        // sync() prepares the pool manager to receive tokens
        poolManager.sync(currency);

        // Transfer tokens to pool manager
        IERC20(Currency.unwrap(currency)).safeTransfer(
            address(poolManager),
            amount
        );

        // settle() confirms the payment
        poolManager.settle();
    }

    // ============================================================
    //                      VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Get current liquidity in a position
     * @param params Encoded PoolKey
     * @return liquidity Current position liquidity
     */
    function getPositionLiquidity(
        bytes calldata params
    ) external view override returns (uint128 liquidity) {
        PoolKey memory poolKey = abi.decode(params, (PoolKey));

        int24 tickLower = (TickMath.MIN_TICK / poolKey.tickSpacing) *
            poolKey.tickSpacing;
        int24 tickUpper = (TickMath.MAX_TICK / poolKey.tickSpacing) *
            poolKey.tickSpacing;

        // Get position info from pool manager
        // Position ID is hash of (owner, tickLower, tickUpper, salt)
        bytes32 positionKey = keccak256(
            abi.encodePacked(address(this), tickLower, tickUpper, bytes32(0))
        );

        (liquidity, , ) = poolManager.getPositionInfo(
            poolKey.toId(),
            positionKey
        );
    }

    /**
     * @notice Get pool tokens from PoolKey
     * @param params Encoded PoolKey
     * @return token0 First token address
     * @return token1 Second token address
     */
    function getPoolTokens(
        bytes calldata params
    ) external pure override returns (address token0, address token1) {
        PoolKey memory poolKey = abi.decode(params, (PoolKey));
        token0 = Currency.unwrap(poolKey.currency0);
        token1 = Currency.unwrap(poolKey.currency1);
    }

    /**
     * @notice Preview token amounts for removing liquidity
     * @dev Uses LiquidityAmounts to calculate expected amounts
     *
     * @param liquidity Amount of LP units to remove
     * @param params Encoded PoolKey
     * @return amount0 Estimated token0 to receive
     * @return amount1 Estimated token1 to receive
     */
    function previewRemoveLiquidity(
        uint128 liquidity,
        bytes calldata params
    ) external view override returns (uint256 amount0, uint256 amount1) {
        PoolKey memory poolKey = abi.decode(params, (PoolKey));

        // Get current pool price
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolKey.toId());

        // Calculate full range ticks
        int24 tickLower = (TickMath.MIN_TICK / poolKey.tickSpacing) *
            poolKey.tickSpacing;
        int24 tickUpper = (TickMath.MAX_TICK / poolKey.tickSpacing) *
            poolKey.tickSpacing;

        // Calculate amounts from liquidity using SqrtPriceMath
        uint160 sqrtPriceA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceB = TickMath.getSqrtPriceAtTick(tickUpper);

        // For full range, we calculate based on current price position
        // Using signed liquidity (negative = remove)
        int128 negativeLiquidity = -int128(liquidity);

        if (sqrtPriceX96 <= sqrtPriceA) {
            // All token0: price below range
            int256 delta0 = SqrtPriceMath.getAmount0Delta(
                sqrtPriceA,
                sqrtPriceB,
                negativeLiquidity
            );
            amount0 = delta0 > 0 ? uint256(delta0) : uint256(-delta0);
            amount1 = 0;
        } else if (sqrtPriceX96 >= sqrtPriceB) {
            // All token1: price above range
            int256 delta1 = SqrtPriceMath.getAmount1Delta(
                sqrtPriceA,
                sqrtPriceB,
                negativeLiquidity
            );
            amount0 = 0;
            amount1 = delta1 > 0 ? uint256(delta1) : uint256(-delta1);
        } else {
            // Both tokens: price in range
            int256 delta0 = SqrtPriceMath.getAmount0Delta(
                sqrtPriceX96,
                sqrtPriceB,
                negativeLiquidity
            );
            int256 delta1 = SqrtPriceMath.getAmount1Delta(
                sqrtPriceA,
                sqrtPriceX96,
                negativeLiquidity
            );
            amount0 = delta0 > 0 ? uint256(delta0) : uint256(-delta0);
            amount1 = delta1 > 0 ? uint256(delta1) : uint256(-delta1);
        }
    }

    /// @notice Returns "V4" for Uniswap V4
    function protocolId() external pure override returns (string memory) {
        return PROTOCOL_ID;
    }

    /**
     * @notice Check if pool is supported
     * @dev Validates PoolKey and checks if pool is initialized
     */
    function supportsPool(
        bytes calldata params
    ) external view override returns (bool) {
        try this.decodeAndCheckPool(params) returns (bool result) {
            return result;
        } catch {
            return false;
        }
    }

    /// @notice Helper to decode and check pool (used by supportsPool)
    function decodeAndCheckPool(
        bytes calldata params
    ) external view returns (bool) {
        PoolKey memory poolKey = abi.decode(params, (PoolKey));

        // Check if pool is initialized by getting slot0
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolKey.toId());

        // sqrtPriceX96 = 0 means pool is not initialized
        return sqrtPriceX96 != 0;
    }

    /// @notice Returns PoolManager address
    function protocolAddress() external view override returns (address) {
        return address(poolManager);
    }

    // ============================================================
    //                  PREVIEW VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Preview liquidity and amounts for adding liquidity
     * @dev Calculates expected liquidity and actual token usage
     * @param params Encoded (PoolKey, amount0, amount1)
     */
    function previewAddLiquidity(
        bytes calldata params
    )
        external
        view
        override
        returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
    {
        (PoolKey memory poolKey, uint256 amount0, uint256 amount1) = abi.decode(
            params,
            (PoolKey, uint256, uint256)
        );

        // Get current pool price
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolKey.toId());

        // Calculate full range ticks
        int24 tickLower = (TickMath.MIN_TICK / poolKey.tickSpacing) *
            poolKey.tickSpacing;
        int24 tickUpper = (TickMath.MAX_TICK / poolKey.tickSpacing) *
            poolKey.tickSpacing;

        uint160 sqrtPriceA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceB = TickMath.getSqrtPriceAtTick(tickUpper);

        // Calculate liquidity from amounts
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtPriceA,
            sqrtPriceB,
            amount0,
            amount1
        );

        // Calculate actual amounts that will be used using SqrtPriceMath
        // (LiquidityAmounts.getAmountsForLiquidity is not available in v4-periphery)
        (amount0Used, amount1Used) = _getAmountsForLiquidity(
            sqrtPriceX96,
            sqrtPriceA,
            sqrtPriceB,
            liquidity
        );
    }

    /**
     * @notice Calculate token amounts for given liquidity
     * @dev Helper function since LiquidityAmounts.getAmountsForLiquidity is not available
     */
    function _getAmountsForLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceA,
        uint160 sqrtPriceB,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtPriceX96 <= sqrtPriceA) {
            // All token0: price below range
            int256 delta0 = SqrtPriceMath.getAmount0Delta(
                sqrtPriceA,
                sqrtPriceB,
                int128(liquidity)
            );
            amount0 = delta0 > 0 ? uint256(delta0) : uint256(-delta0);
        } else if (sqrtPriceX96 >= sqrtPriceB) {
            // All token1: price above range
            int256 delta1 = SqrtPriceMath.getAmount1Delta(
                sqrtPriceA,
                sqrtPriceB,
                int128(liquidity)
            );
            amount1 = delta1 > 0 ? uint256(delta1) : uint256(-delta1);
        } else {
            // Both tokens: price in range
            int256 delta0 = SqrtPriceMath.getAmount0Delta(
                sqrtPriceX96,
                sqrtPriceB,
                int128(liquidity)
            );
            int256 delta1 = SqrtPriceMath.getAmount1Delta(
                sqrtPriceA,
                sqrtPriceX96,
                int128(liquidity)
            );
            amount0 = delta0 > 0 ? uint256(delta0) : uint256(-delta0);
            amount1 = delta1 > 0 ? uint256(delta1) : uint256(-delta1);
        }
    }

    /**
     * @notice Calculate optimal amount1 for given amount0
     * @dev Uses current pool price to calculate matching amount
     */
    function calculateOptimalAmount1(
        uint256 amount0,
        bytes calldata params
    ) external view override returns (uint256 amount1) {
        PoolKey memory poolKey = abi.decode(params, (PoolKey));

        // Get current pool price
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolKey.toId());

        // Calculate full range ticks
        int24 tickLower = (TickMath.MIN_TICK / poolKey.tickSpacing) *
            poolKey.tickSpacing;
        int24 tickUpper = (TickMath.MAX_TICK / poolKey.tickSpacing) *
            poolKey.tickSpacing;

        uint160 sqrtPriceA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceB = TickMath.getSqrtPriceAtTick(tickUpper);

        // Get liquidity for amount0 only
        uint128 liquidity0 = LiquidityAmounts.getLiquidityForAmount0(
            sqrtPriceX96,
            sqrtPriceB,
            amount0
        );

        // Calculate corresponding amount1
        (, amount1) = _getAmountsForLiquidity(
            sqrtPriceX96,
            sqrtPriceA,
            sqrtPriceB,
            liquidity0
        );
    }

    /**
     * @notice Calculate optimal amount0 for given amount1
     * @dev Uses current pool price to calculate matching amount
     */
    function calculateOptimalAmount0(
        uint256 amount1,
        bytes calldata params
    ) external view override returns (uint256 amount0) {
        PoolKey memory poolKey = abi.decode(params, (PoolKey));

        // Get current pool price
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolKey.toId());

        // Calculate full range ticks
        int24 tickLower = (TickMath.MIN_TICK / poolKey.tickSpacing) *
            poolKey.tickSpacing;
        int24 tickUpper = (TickMath.MAX_TICK / poolKey.tickSpacing) *
            poolKey.tickSpacing;

        uint160 sqrtPriceA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceB = TickMath.getSqrtPriceAtTick(tickUpper);

        // Get liquidity for amount1 only
        uint128 liquidity1 = LiquidityAmounts.getLiquidityForAmount1(
            sqrtPriceA,
            sqrtPriceX96,
            amount1
        );

        // Calculate corresponding amount0
        (amount0, ) = _getAmountsForLiquidity(
            sqrtPriceX96,
            sqrtPriceA,
            sqrtPriceB,
            liquidity1
        );
    }

    /**
     * @notice Get current pool price
     * @return sqrtPriceX96 Current sqrt price in Q96 format
     * @return tick Current tick
     */
    function getPoolPrice(
        bytes calldata params
    ) external view override returns (uint160 sqrtPriceX96, int24 tick) {
        PoolKey memory poolKey = abi.decode(params, (PoolKey));
        (sqrtPriceX96, tick, , ) = poolManager.getSlot0(poolKey.toId());
    }

    /**
     * @notice Get pool fee tier
     * @return fee Fee in hundredths of a bip
     */
    function getPoolFee(
        bytes calldata params
    ) external view override returns (uint24 fee) {
        PoolKey memory poolKey = abi.decode(params, (PoolKey));
        fee = poolKey.fee;
    }

    // ============================================================
    //                     TVL VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Get current value of YieldForge position in token amounts
     * @dev Calculates how much of each token our position is worth at current price
     *
     * @param params Encoded PoolKey
     * @return amount0 Value of our position in token0
     * @return amount1 Value of our position in token1
     */
    function getPositionValue(
        bytes calldata params
    ) external view override returns (uint256 amount0, uint256 amount1) {
        PoolKey memory poolKey = abi.decode(params, (PoolKey));

        // Get our position's liquidity
        int24 tickLower = (TickMath.MIN_TICK / poolKey.tickSpacing) *
            poolKey.tickSpacing;
        int24 tickUpper = (TickMath.MAX_TICK / poolKey.tickSpacing) *
            poolKey.tickSpacing;

        bytes32 positionKey = keccak256(
            abi.encodePacked(address(this), tickLower, tickUpper, bytes32(0))
        );

        (uint128 liquidity, , ) = poolManager.getPositionInfo(
            poolKey.toId(),
            positionKey
        );

        if (liquidity == 0) return (0, 0);

        // Get current pool price
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolKey.toId());

        uint160 sqrtPriceA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceB = TickMath.getSqrtPriceAtTick(tickUpper);

        // Calculate token amounts for our liquidity
        (amount0, amount1) = _getAmountsForLiquidity(
            sqrtPriceX96,
            sqrtPriceA,
            sqrtPriceB,
            liquidity
        );
    }

    /**
     * @notice Get total value locked in the underlying pool
     * @dev Returns total amounts of tokens in the V4 pool
     *
     * Note: V4 pools don't hold tokens directly like V3. Instead, PoolManager
     * holds all tokens. We return the amounts that would be obtained if
     * the pool's total liquidity were removed.
     *
     * @param params Encoded PoolKey
     * @return amount0 Total token0 in the pool
     * @return amount1 Total token1 in the pool
     */
    function getPoolTotalValue(
        bytes calldata params
    ) external view override returns (uint256 amount0, uint256 amount1) {
        PoolKey memory poolKey = abi.decode(params, (PoolKey));

        // Get current pool price and total liquidity
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolKey.toId());
        uint128 totalLiquidity = poolManager.getLiquidity(poolKey.toId());

        if (totalLiquidity == 0) return (0, 0);

        // Calculate full range ticks
        int24 tickLower = (TickMath.MIN_TICK / poolKey.tickSpacing) *
            poolKey.tickSpacing;
        int24 tickUpper = (TickMath.MAX_TICK / poolKey.tickSpacing) *
            poolKey.tickSpacing;

        uint160 sqrtPriceA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceB = TickMath.getSqrtPriceAtTick(tickUpper);

        // Calculate token amounts for total liquidity
        (amount0, amount1) = _getAmountsForLiquidity(
            sqrtPriceX96,
            sqrtPriceA,
            sqrtPriceB,
            totalLiquidity
        );
    }
}
