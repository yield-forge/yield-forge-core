// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibPause} from "../libraries/LibPause.sol";
import {LibReentrancyGuard} from "../libraries/LibReentrancyGuard.sol";
import {ProtocolFees} from "../libraries/ProtocolFees.sol";
import {YieldToken} from "../tokens/YieldToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title YTOrderbookFacet
 * @author Yield Forge Team
 * @notice Peer-to-peer orderbook for trading Yield Tokens (YT)
 * @dev Implements a simple orderbook model instead of AMM for YT trading.
 *
 * WHY ORDERBOOK INSTEAD OF AMM?
 * -----------------------------
 * AMM for YT has a critical problem: when YT is held by the pool,
 * accumulated fees get "stuck" in the pool rather than going to the LP.
 * With an orderbook:
 * - YT stays with the MAKER until order is filled
 * - Maker continues earning fees until sale
 * - Only at fill: claim fees → transfer YT → transfer quote
 *
 * ORDER TYPES:
 * ------------
 * - SELL ORDER: Maker wants to sell YT for quote tokens
 *   - YT stays with maker (not escrowed)
 *   - Quote locked by taker at fill time
 *
 * - BUY ORDER: Maker wants to buy YT with quote tokens
 *   - Quote tokens escrowed in contract
 *   - YT transferred from taker at fill time
 *
 * ORDER LIFECYCLE:
 * ----------------
 * 1. Maker places order (placeSellOrder / placeBuyOrder)
 * 2. Order visible in orderbook (getOrders)
 * 3. Taker fills order (fillOrder)
 *    - For sell: taker pays quote, receives YT
 *    - For buy: taker sends YT, receives quote
 * 4. Or maker cancels order (cancelOrder)
 *
 * FEES:
 * -----
 * - Taker pays protocol fee on fill (via ProtocolFees.sol)
 * - Fee taken from quote token side
 *
 * TTL (TIME-TO-LIVE):
 * -------------------
 * Orders have expiration set at creation:
 * - Default: 7 days
 * - After expiration, order can only be cancelled
 *
 * PARTIAL FILLS:
 * --------------
 * Orders support partial fills:
 * - filledAmount tracks how much has been filled
 * - Remaining amount available for additional fills
 */
contract YTOrderbookFacet {
    using SafeERC20 for IERC20;

    // ============================================================
    //                        CONSTANTS
    // ============================================================

    /// @notice Default order TTL (7 days)
    uint256 public constant DEFAULT_ORDER_TTL = 7 days;

    /// @notice Minimum order amount (prevents dust orders)
    uint256 public constant MIN_ORDER_AMOUNT = 1e15; // 0.001 tokens

    /// @notice Basis points denominator
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice Taker fee in basis points (0.3%)
    uint256 public constant TAKER_FEE_BPS = 30;

    /// @notice Maximum orders to sweep in a single market order
    /// @dev Prevents unbounded gas consumption in marketBuy/marketSell
    uint256 public constant MAX_MARKET_ORDER_SWEEPS = 50;

    // ============================================================
    //                         STRUCTS
    // ============================================================

    /**
     * @notice Order data structure
     * @param id          Unique order ID
     * @param maker       Address that created the order
     * @param poolId      Pool the YT belongs to
     * @param cycleId     Cycle the YT belongs to
     * @param ytAmount    Total YT amount in order
     * @param filledAmount YT amount already filled
     * @param pricePerYt Price per YT in quote token (native decimals)
     * @param isSellOrder True if selling YT, false if buying
     * @param createdAt   Timestamp when order was created
     * @param expiresAt   Timestamp when order expires
     * @param isActive    True if order can be filled/cancelled
     */
    struct Order {
        uint256 id;
        address maker;
        bytes32 poolId;
        uint256 cycleId;
        uint256 ytAmount;
        uint256 filledAmount;
        uint256 pricePerYt;
        bool isSellOrder;
        uint256 createdAt;
        uint256 expiresAt;
        bool isActive;
    }

    // ============================================================
    //                          EVENTS
    // ============================================================

    /// @notice Emitted when order is placed
    event OrderPlaced(
        uint256 indexed orderId,
        address indexed maker,
        bytes32 indexed poolId,
        uint256 cycleId,
        uint256 ytAmount,
        uint256 pricePerYt,
        bool isSellOrder,
        uint256 expiresAt
    );

    /// @notice Emitted when order is filled (fully or partially)
    event OrderFilled(
        uint256 indexed orderId,
        address indexed taker,
        bytes32 indexed poolId,
        uint256 cycleId,
        address maker,
        uint256 ytAmountFilled,
        uint256 quoteAmountPaid,
        uint256 protocolFee
    );

    /// @notice Emitted when order is cancelled
    event OrderCancelled(uint256 indexed orderId, address indexed maker);

    // ============================================================
    //                          ERRORS
    // ============================================================

    /// @notice Order not found
    error OrderNotFound(uint256 orderId);

    /// @notice Order is not active
    error OrderNotActive(uint256 orderId);

    /// @notice Order has expired
    error OrderExpired(uint256 orderId);

    /// @notice Not authorized to cancel order
    error NotOrderMaker(uint256 orderId, address caller);

    /// @notice Amount too small
    error AmountTooSmall(uint256 amount, uint256 minimum);

    /// @notice Invalid price
    error InvalidPrice(uint256 pricePerYt);

    /// @notice Insufficient YT balance
    error InsufficientYTBalance(uint256 required, uint256 available);

    /// @notice Insufficient quote balance
    error InsufficientQuoteBalance(uint256 required, uint256 available);

    /// @notice Fill amount exceeds remaining
    error FillExceedsRemaining(uint256 requested, uint256 remaining);

    /// @notice Invalid cycle
    error InvalidCycle(bytes32 poolId, uint256 cycleId);

    /// @notice Pool not found
    error PoolNotFound(bytes32 poolId);

    /// @notice Cannot fill own order (prevents wash trading)
    error CannotFillOwnOrder(uint256 orderId);

    /// @notice Quote amount too small after calculation
    error QuoteAmountTooSmall(uint256 ytAmount, uint256 pricePerYt);

    /// @notice Cycle has matured, YT trading not allowed
    error CycleMatured(bytes32 poolId, uint256 cycleId);

    // ============================================================
    //                     ORDER PLACEMENT
    // ============================================================

    /**
     * @notice Place a sell order for YT
     * @dev YT stays with maker until order is filled. Maker continues earning fees.
     *
     * IMPORTANT: Maker must have approved this contract for YT transfer.
     * YT is NOT escrowed - it stays with maker earning fees until fill.
     *
     * @param poolId           Pool the YT belongs to
     * @param ytAmount         Amount of YT to sell
     * @param pricePerYt       Asking price per YT in quote token (native decimals)
     * @param ttlSeconds       Order validity in seconds (0 = use default 7 days)
     * @return orderId         ID of created order
     *
     * @custom:example
     * // Sell 100 YT at 0.02 USDT each (6 decimals = 20000)
     * placeSellOrder(poolId, 100e18, 20000, 0);
     */
    function placeSellOrder(bytes32 poolId, uint256 ytAmount, uint256 pricePerYt, uint256 ttlSeconds)
        external
        returns (uint256 orderId)
    {
        LibPause.requireNotPaused();
        LibReentrancyGuard._nonReentrantBefore();

        // Validate inputs
        if (ytAmount < MIN_ORDER_AMOUNT) {
            revert AmountTooSmall(ytAmount, MIN_ORDER_AMOUNT);
        }
        if (pricePerYt == 0) {
            revert InvalidPrice(pricePerYt);
        }

        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();

        // Validate pool exists
        if (!s.pools[poolId].exists) {
            revert PoolNotFound(poolId);
        }

        uint256 cycleId = s.currentCycleId[poolId];
        LibAppStorage.CycleInfo storage cycle = s.cycles[poolId][cycleId];

        // Validate cycle exists and has YT
        if (cycle.ytToken == address(0)) {
            revert InvalidCycle(poolId, cycleId);
        }

        // Verify maker has enough YT (but don't transfer - YT stays with maker)
        uint256 makerBalance = IERC20(cycle.ytToken).balanceOf(msg.sender);
        if (makerBalance < ytAmount) {
            revert InsufficientYTBalance(ytAmount, makerBalance);
        }

        // Create order
        orderId = ++s.ytOrderbookNextId;
        uint256 expiresAt = block.timestamp + (ttlSeconds > 0 ? ttlSeconds : DEFAULT_ORDER_TTL);

        s.ytOrders[orderId] = LibAppStorage.YTOrder({
            id: orderId,
            maker: msg.sender,
            poolId: poolId,
            cycleId: cycleId,
            ytAmount: ytAmount,
            filledAmount: 0,
            pricePerYt: pricePerYt,
            isSellOrder: true,
            createdAt: block.timestamp,
            expiresAt: expiresAt,
            isActive: true
        });

        // Track in pool's order list
        s.ytOrdersByPool[poolId].push(orderId);

        emit OrderPlaced(orderId, msg.sender, poolId, cycleId, ytAmount, pricePerYt, true, expiresAt);

        LibReentrancyGuard._nonReentrantAfter();
    }

    /**
     * @notice Place a buy order for YT
     * @dev Quote tokens are escrowed in the contract until fill or cancel.
     *
     * IMPORTANT: Maker must have approved this contract for quote token transfer.
     *
     * @param poolId           Pool the YT belongs to
     * @param ytAmount         Amount of YT to buy
     * @param pricePerYt       Max price per YT in quote token (native decimals)
     * @param ttlSeconds       Order validity in seconds (0 = use default 7 days)
     * @return orderId         ID of created order
     *
     * @custom:example
     * // Buy 100 YT at max 0.03 USDT each (6 decimals = 30000)
     * placeBuyOrder(poolId, 100e18, 30000, 0);
     */
    function placeBuyOrder(bytes32 poolId, uint256 ytAmount, uint256 pricePerYt, uint256 ttlSeconds)
        external
        returns (uint256 orderId)
    {
        LibPause.requireNotPaused();
        LibReentrancyGuard._nonReentrantBefore();

        // Validate inputs
        if (ytAmount < MIN_ORDER_AMOUNT) {
            revert AmountTooSmall(ytAmount, MIN_ORDER_AMOUNT);
        }
        if (pricePerYt == 0) {
            revert InvalidPrice(pricePerYt);
        }

        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        LibAppStorage.PoolInfo storage pool = s.pools[poolId];

        if (!pool.exists) {
            revert PoolNotFound(poolId);
        }

        uint256 cycleId = s.currentCycleId[poolId];
        LibAppStorage.CycleInfo storage cycle = s.cycles[poolId][cycleId];

        if (cycle.ytToken == address(0)) {
            revert InvalidCycle(poolId, cycleId);
        }

        // Calculate quote amount to escrow
        // quoteAmount = ytAmount × pricePerYt / 1e18 (YT has 18 decimals)
        uint256 quoteAmount = (ytAmount * pricePerYt) / 1e18;

        // Transfer quote tokens to escrow
        IERC20(pool.quoteToken).safeTransferFrom(msg.sender, address(this), quoteAmount);

        // Create order
        orderId = ++s.ytOrderbookNextId;
        uint256 expiresAt = block.timestamp + (ttlSeconds > 0 ? ttlSeconds : DEFAULT_ORDER_TTL);

        s.ytOrders[orderId] = LibAppStorage.YTOrder({
            id: orderId,
            maker: msg.sender,
            poolId: poolId,
            cycleId: cycleId,
            ytAmount: ytAmount,
            filledAmount: 0,
            pricePerYt: pricePerYt,
            isSellOrder: false,
            createdAt: block.timestamp,
            expiresAt: expiresAt,
            isActive: true
        });

        // Track escrow
        s.ytOrderEscrow[orderId] = quoteAmount;
        s.ytOrdersByPool[poolId].push(orderId);

        emit OrderPlaced(orderId, msg.sender, poolId, cycleId, ytAmount, pricePerYt, false, expiresAt);

        LibReentrancyGuard._nonReentrantAfter();
    }

    // ============================================================
    //                      ORDER FILLING
    // ============================================================

    /**
     * @notice Fill a sell order (taker buys YT)
     * @dev
     * 1. Calculates quote cost for requested amount
     * 2. Transfers quote from taker to maker
     * 3. Claims any pending yield for maker's YT
     * 4. Transfers YT from maker to taker
     * 5. Takes protocol fee from quote
     *
     * @param orderId    Order to fill
     * @param fillAmount Amount of YT to buy (can be partial)
     *
     * @custom:example
     * fillSellOrder(123, 50e18); // Buy 50 YT from order 123
     */
    function fillSellOrder(uint256 orderId, uint256 fillAmount) external returns (uint256 quotePaid) {
        LibPause.requireNotPaused();
        LibReentrancyGuard._nonReentrantBefore();

        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        LibAppStorage.YTOrder storage order = s.ytOrders[orderId];

        // Validate order
        _validateOrderForFill(order, orderId, true);

        // Prevent self-trading (wash trading prevention)
        if (order.maker == msg.sender) {
            revert CannotFillOwnOrder(orderId);
        }

        // Calculate remaining and validate fill amount
        uint256 remaining = order.ytAmount - order.filledAmount;
        if (fillAmount > remaining) {
            revert FillExceedsRemaining(fillAmount, remaining);
        }

        // Calculate quote cost
        // quoteAmount = fillAmount × pricePerYt / 1e18 (YT has 18 decimals)
        uint256 quoteAmount = (fillAmount * order.pricePerYt) / 1e18;

        // Prevent zero-cost fills
        if (quoteAmount == 0) {
            revert QuoteAmountTooSmall(fillAmount, order.pricePerYt);
        }

        // Calculate and deduct taker fee
        uint256 takerFee = (quoteAmount * TAKER_FEE_BPS) / BPS_DENOMINATOR;
        uint256 makerReceives = quoteAmount - takerFee;

        LibAppStorage.PoolInfo storage pool = s.pools[order.poolId];
        LibAppStorage.CycleInfo storage cycle = s.cycles[order.poolId][order.cycleId];

        // Transfer quote from taker
        IERC20(pool.quoteToken).safeTransferFrom(msg.sender, address(this), quoteAmount);

        // Pay maker
        IERC20(pool.quoteToken).safeTransfer(order.maker, makerReceives);

        // Send fee to protocol
        if (takerFee > 0) {
            IERC20(pool.quoteToken).safeTransfer(s.protocolFeeRecipient, takerFee);
        }

        // Transfer YT from maker to taker
        IERC20(cycle.ytToken).safeTransferFrom(order.maker, msg.sender, fillAmount);

        // Update order state
        order.filledAmount += fillAmount;
        if (order.filledAmount == order.ytAmount) {
            order.isActive = false;
        }

        emit OrderFilled(
            orderId, msg.sender, order.poolId, order.cycleId, order.maker, fillAmount, quoteAmount, takerFee
        );

        LibReentrancyGuard._nonReentrantAfter();
        return quoteAmount;
    }

    /**
     * @notice Fill a buy order (taker sells YT)
     * @dev
     * 1. Transfers YT from taker to maker
     * 2. Releases escrowed quote to taker (minus fee)
     * 3. Takes protocol fee
     *
     * @param orderId    Order to fill
     * @param fillAmount Amount of YT to sell (can be partial)
     *
     * @custom:example
     * fillBuyOrder(456, 50e18); // Sell 50 YT to order 456
     */
    function fillBuyOrder(uint256 orderId, uint256 fillAmount) external returns (uint256 quoteReceived) {
        LibPause.requireNotPaused();
        LibReentrancyGuard._nonReentrantBefore();

        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        LibAppStorage.YTOrder storage order = s.ytOrders[orderId];

        // Validate order
        _validateOrderForFill(order, orderId, false);

        // Prevent self-trading (wash trading prevention)
        if (order.maker == msg.sender) {
            revert CannotFillOwnOrder(orderId);
        }

        // Calculate remaining and validate fill amount
        uint256 remaining = order.ytAmount - order.filledAmount;
        if (fillAmount > remaining) {
            revert FillExceedsRemaining(fillAmount, remaining);
        }

        // Calculate quote amount from escrow
        // quoteAmount = fillAmount × pricePerYt / 1e18 (YT has 18 decimals)
        uint256 quoteAmount = (fillAmount * order.pricePerYt) / 1e18;

        // Prevent zero-cost fills
        if (quoteAmount == 0) {
            revert QuoteAmountTooSmall(fillAmount, order.pricePerYt);
        }

        // Calculate taker fee (taker is selling YT, receives quote)
        uint256 takerFee = (quoteAmount * TAKER_FEE_BPS) / BPS_DENOMINATOR;
        uint256 takerReceives = quoteAmount - takerFee;

        LibAppStorage.PoolInfo storage pool = s.pools[order.poolId];
        LibAppStorage.CycleInfo storage cycle = s.cycles[order.poolId][order.cycleId];

        // Transfer YT from taker to maker
        IERC20(cycle.ytToken).safeTransferFrom(msg.sender, order.maker, fillAmount);

        // Release escrowed quote to taker
        IERC20(pool.quoteToken).safeTransfer(msg.sender, takerReceives);

        // Send fee to protocol
        if (takerFee > 0) {
            IERC20(pool.quoteToken).safeTransfer(s.protocolFeeRecipient, takerFee);
        }

        // Update order state and escrow
        order.filledAmount += fillAmount;
        s.ytOrderEscrow[orderId] -= quoteAmount;

        if (order.filledAmount == order.ytAmount) {
            order.isActive = false;
        }

        emit OrderFilled(
            orderId, msg.sender, order.poolId, order.cycleId, order.maker, fillAmount, quoteAmount, takerFee
        );

        LibReentrancyGuard._nonReentrantAfter();
        return takerReceives;
    }

    // ============================================================
    //                     ORDER CANCELLATION
    // ============================================================

    /**
     * @notice Cancel an order
     * @dev Only order maker can cancel. For buy orders, escrow is returned.
     *
     * @param orderId Order to cancel
     *
     * @custom:example
     * cancelOrder(123);
     */
    function cancelOrder(uint256 orderId) external {
        LibReentrancyGuard._nonReentrantBefore();

        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        LibAppStorage.YTOrder storage order = s.ytOrders[orderId];

        // Validate order exists and belongs to caller
        if (order.id == 0) {
            revert OrderNotFound(orderId);
        }
        if (order.maker != msg.sender) {
            revert NotOrderMaker(orderId, msg.sender);
        }
        if (!order.isActive) {
            revert OrderNotActive(orderId);
        }

        // Mark order as cancelled
        order.isActive = false;

        // Return escrow for buy orders
        if (!order.isSellOrder) {
            uint256 escrowedAmount = s.ytOrderEscrow[orderId];
            if (escrowedAmount > 0) {
                LibAppStorage.PoolInfo storage pool = s.pools[order.poolId];
                IERC20(pool.quoteToken).safeTransfer(msg.sender, escrowedAmount);
                s.ytOrderEscrow[orderId] = 0;
            }
        }

        emit OrderCancelled(orderId, msg.sender);

        LibReentrancyGuard._nonReentrantAfter();
    }

    // ============================================================
    //                     ORDER CLEANUP
    // ============================================================

    /// @notice Emitted when dead orders are cleaned up
    event OrdersCleanedUp(bytes32 indexed poolId, uint256 removedCount);

    /**
     * @notice Remove inactive/expired/filled orders from the pool's order list
     * @dev Permissionless — anyone can call to keep the orderbook healthy.
     *      Compacts the ytOrdersByPool array by removing dead entries.
     *
     * @param poolId Pool identifier
     * @param maxIterations Maximum entries to scan (0 = scan all)
     * @return removedCount Number of dead entries removed
     */
    function cleanupOrders(bytes32 poolId, uint256 maxIterations) external returns (uint256 removedCount) {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        uint256[] storage orderIds = s.ytOrdersByPool[poolId];

        uint256 len = orderIds.length;
        uint256 iterations = maxIterations == 0 ? len : (maxIterations < len ? maxIterations : len);

        uint256 writeIdx = 0;
        uint256 readIdx = 0;

        // Compact array: copy live entries forward, skip dead ones
        for (; readIdx < iterations; readIdx++) {
            LibAppStorage.YTOrder storage order = s.ytOrders[orderIds[readIdx]];
            bool isDead = !order.isActive || order.filledAmount >= order.ytAmount || block.timestamp >= order.expiresAt;

            if (!isDead) {
                if (writeIdx != readIdx) {
                    orderIds[writeIdx] = orderIds[readIdx];
                }
                writeIdx++;
            }
        }

        // If we didn't scan the full array, copy remaining entries as-is
        for (; readIdx < len; readIdx++) {
            if (writeIdx != readIdx) {
                orderIds[writeIdx] = orderIds[readIdx];
            }
            writeIdx++;
        }

        // Remove trailing entries
        removedCount = len - writeIdx;
        if (removedCount > 0) {
            for (uint256 i = 0; i < removedCount; i++) {
                orderIds.pop();
            }
            emit OrdersCleanedUp(poolId, removedCount);
        }
    }

    // ============================================================
    //                      MARKET ORDERS
    // ============================================================

    /// @notice Insufficient liquidity for market order
    error InsufficientLiquidity(uint256 requested, uint256 available);

    /// @notice Slippage exceeded
    error SlippageExceeded(uint256 quoteAmount, uint256 maxQuote);

    /// @notice Slippage too low
    error SlippageTooLow(uint256 quoteAmount, uint256 minQuote);

    /**
     * @notice Market buy - sweep sell orders from best price
     * @dev Fills multiple sell orders starting from lowest price until ytAmount is filled.
     *      Uses maxQuote as slippage protection. Sweeps at most MAX_MARKET_ORDER_SWEEPS orders.
     *
     * @param poolId     Pool identifier
     * @param cycleId    Cycle identifier
     * @param ytAmount   Total YT to buy
     * @param maxQuote   Maximum quote to spend (slippage protection)
     * @return totalQuote Total quote spent
     *
     * @custom:example
     * marketBuy(poolId, cycleId, 100e18, 10e6); // Buy 100 YT, max 10 USDC
     */
    function marketBuy(bytes32 poolId, uint256 cycleId, uint256 ytAmount, uint256 maxQuote)
        external
        returns (uint256 totalQuote)
    {
        LibPause.requireNotPaused();
        LibReentrancyGuard._nonReentrantBefore();

        if (ytAmount < MIN_ORDER_AMOUNT) {
            revert AmountTooSmall(ytAmount, MIN_ORDER_AMOUNT);
        }

        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();

        // Validate pool and cycle
        LibAppStorage.PoolInfo storage pool = s.pools[poolId];
        if (pool.quoteToken == address(0)) {
            revert PoolNotFound(poolId);
        }
        LibAppStorage.CycleInfo storage cycle = s.cycles[poolId][cycleId];
        if (cycle.ytToken == address(0)) {
            revert InvalidCycle(poolId, cycleId);
        }
        if (block.timestamp >= cycle.maturityDate) {
            revert CycleMatured(poolId, cycleId);
        }

        // Get best sell orders, capped at MAX_MARKET_ORDER_SWEEPS
        uint256[] memory sortedOrderIds = _getSortedSellOrders(poolId, cycleId);

        uint256 remainingYT = ytAmount;
        uint256 totalQuoteSpent = 0;

        for (uint256 i = 0; i < sortedOrderIds.length && remainingYT > 0; i++) {
            (uint256 filled, uint256 spent) =
                _executeSellOrderFill(s, sortedOrderIds[i], remainingYT, maxQuote - totalQuoteSpent, pool, cycle);

            if (filled == 0) continue;

            remainingYT -= filled;
            totalQuoteSpent += spent;

            if (totalQuoteSpent >= maxQuote) break;
        }

        // Check if we filled enough
        if (remainingYT > 0) {
            revert InsufficientLiquidity(ytAmount, ytAmount - remainingYT);
        }

        LibReentrancyGuard._nonReentrantAfter();
        return totalQuoteSpent;
    }

    /**
     * @notice Market sell - sweep buy orders from best price
     * @dev Fills multiple buy orders starting from highest price until ytAmount is filled.
     *      Uses minQuote as slippage protection. Sweeps at most MAX_MARKET_ORDER_SWEEPS orders.
     *
     * @param poolId     Pool identifier
     * @param cycleId    Cycle identifier
     * @param ytAmount   Total YT to sell
     * @param minQuote   Minimum quote to receive (slippage protection)
     * @return totalQuote Total quote received
     *
     * @custom:example
     * marketSell(poolId, cycleId, 100e18, 9e6); // Sell 100 YT, min 9 USDC
     */
    function marketSell(bytes32 poolId, uint256 cycleId, uint256 ytAmount, uint256 minQuote)
        external
        returns (uint256 totalQuote)
    {
        LibPause.requireNotPaused();
        LibReentrancyGuard._nonReentrantBefore();

        if (ytAmount < MIN_ORDER_AMOUNT) {
            revert AmountTooSmall(ytAmount, MIN_ORDER_AMOUNT);
        }

        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();

        // Validate pool and cycle
        LibAppStorage.PoolInfo storage pool = s.pools[poolId];
        if (pool.quoteToken == address(0)) {
            revert PoolNotFound(poolId);
        }
        LibAppStorage.CycleInfo storage cycle = s.cycles[poolId][cycleId];
        if (cycle.ytToken == address(0)) {
            revert InvalidCycle(poolId, cycleId);
        }
        if (block.timestamp >= cycle.maturityDate) {
            revert CycleMatured(poolId, cycleId);
        }

        // Get best buy orders, capped at MAX_MARKET_ORDER_SWEEPS
        uint256[] memory sortedOrderIds = _getSortedBuyOrders(poolId, cycleId);

        uint256 remainingYT = ytAmount;
        uint256 totalQuoteReceived = 0;

        for (uint256 i = 0; i < sortedOrderIds.length && remainingYT > 0; i++) {
            (uint256 filled, uint256 received) = _executeBuyOrderFill(s, sortedOrderIds[i], remainingYT, pool, cycle);

            if (filled == 0) continue;

            remainingYT -= filled;
            totalQuoteReceived += received;
        }

        // Check if we filled enough
        if (remainingYT > 0) {
            revert InsufficientLiquidity(ytAmount, ytAmount - remainingYT);
        }

        // Check slippage
        if (totalQuoteReceived < minQuote) {
            revert SlippageTooLow(totalQuoteReceived, minQuote);
        }

        LibReentrancyGuard._nonReentrantAfter();
        return totalQuoteReceived;
    }

    /**
     * @notice Internal: execute a single sell order fill for marketBuy
     * @return filled YT amount filled
     * @return spent Quote amount spent
     */
    function _executeSellOrderFill(
        LibAppStorage.AppStorage storage s,
        uint256 orderId,
        uint256 maxYT,
        uint256 budgetRemaining,
        LibAppStorage.PoolInfo storage pool,
        LibAppStorage.CycleInfo storage cycle
    ) internal returns (uint256 filled, uint256 spent) {
        LibAppStorage.YTOrder storage order = s.ytOrders[orderId];

        // Skip if order is not valid
        if (!order.isActive || order.maker == msg.sender || block.timestamp >= order.expiresAt) {
            return (0, 0);
        }

        uint256 orderRemaining = order.ytAmount - order.filledAmount;
        uint256 fillAmount = maxYT < orderRemaining ? maxYT : orderRemaining;

        // Calculate quote cost
        uint256 quoteAmount = (fillAmount * order.pricePerYt) / 1e18;
        if (quoteAmount == 0) return (0, 0);

        // Check budget
        if (quoteAmount > budgetRemaining) {
            // Try partial fill to stay under budget
            if (budgetRemaining == 0) return (0, 0);
            fillAmount = (budgetRemaining * 1e18) / order.pricePerYt;
            if (fillAmount == 0) return (0, 0);
            quoteAmount = (fillAmount * order.pricePerYt) / 1e18;
        }

        // Calculate fee
        uint256 takerFee = (quoteAmount * TAKER_FEE_BPS) / BPS_DENOMINATOR;
        uint256 makerReceives = quoteAmount - takerFee;

        // Transfer quote from taker
        IERC20(pool.quoteToken).safeTransferFrom(msg.sender, address(this), quoteAmount);
        IERC20(pool.quoteToken).safeTransfer(order.maker, makerReceives);
        if (takerFee > 0) {
            IERC20(pool.quoteToken).safeTransfer(s.protocolFeeRecipient, takerFee);
        }

        // Transfer YT from maker to taker
        IERC20(cycle.ytToken).safeTransferFrom(order.maker, msg.sender, fillAmount);

        // Update order state
        order.filledAmount += fillAmount;
        if (order.filledAmount == order.ytAmount) {
            order.isActive = false;
        }

        emit OrderFilled(
            order.id, msg.sender, order.poolId, order.cycleId, order.maker, fillAmount, quoteAmount, takerFee
        );

        return (fillAmount, quoteAmount);
    }

    /**
     * @notice Internal: execute a single buy order fill for marketSell
     * @return filled YT amount filled
     * @return received Quote amount received by taker
     */
    function _executeBuyOrderFill(
        LibAppStorage.AppStorage storage s,
        uint256 orderId,
        uint256 maxYT,
        LibAppStorage.PoolInfo storage pool,
        LibAppStorage.CycleInfo storage cycle
    ) internal returns (uint256 filled, uint256 received) {
        LibAppStorage.YTOrder storage order = s.ytOrders[orderId];

        // Skip if order is not valid
        if (!order.isActive || order.maker == msg.sender || block.timestamp >= order.expiresAt) {
            return (0, 0);
        }

        uint256 orderRemaining = order.ytAmount - order.filledAmount;
        uint256 fillAmount = maxYT < orderRemaining ? maxYT : orderRemaining;

        // Calculate quote from escrow
        uint256 quoteAmount = (fillAmount * order.pricePerYt) / 1e18;
        if (quoteAmount == 0) return (0, 0);

        // Calculate fee
        uint256 takerFee = (quoteAmount * TAKER_FEE_BPS) / BPS_DENOMINATOR;
        uint256 takerReceives = quoteAmount - takerFee;

        // Transfer YT from taker to maker
        IERC20(cycle.ytToken).safeTransferFrom(msg.sender, order.maker, fillAmount);

        // Release escrowed quote to taker
        IERC20(pool.quoteToken).safeTransfer(msg.sender, takerReceives);
        if (takerFee > 0) {
            IERC20(pool.quoteToken).safeTransfer(s.protocolFeeRecipient, takerFee);
        }

        // Update order state and escrow
        order.filledAmount += fillAmount;
        s.ytOrderEscrow[order.id] -= quoteAmount;
        if (order.filledAmount == order.ytAmount) {
            order.isActive = false;
        }

        emit OrderFilled(
            order.id, msg.sender, order.poolId, order.cycleId, order.maker, fillAmount, quoteAmount, takerFee
        );

        return (fillAmount, takerReceives);
    }

    /**
     * @notice Get sorted sell orders (ascending by price - best first)
     * @dev Internal helper for marketBuy. Capped at MAX_MARKET_ORDER_SWEEPS
     *      to prevent unbounded gas consumption. Uses insertion sort which
     *      is efficient for small arrays and has O(n*k) complexity where
     *      k = min(valid_orders, MAX_MARKET_ORDER_SWEEPS).
     */
    function _getSortedSellOrders(bytes32 poolId, uint256 cycleId) internal view returns (uint256[] memory) {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        uint256[] storage orderIds = s.ytOrdersByPool[poolId];
        uint256 maxResults = MAX_MARKET_ORDER_SWEEPS;

        // Single pass: collect valid sell orders up to maxResults, keeping sorted by price ascending
        uint256[] memory result = new uint256[](maxResults);
        uint256 count = 0;

        for (uint256 i = 0; i < orderIds.length; i++) {
            LibAppStorage.YTOrder storage order = s.ytOrders[orderIds[i]];
            if (
                order.isActive && order.isSellOrder && order.cycleId == cycleId && order.filledAmount < order.ytAmount
                    && block.timestamp < order.expiresAt
            ) {
                uint256 price = order.pricePerYt;
                uint256 orderId = orderIds[i];

                if (count < maxResults) {
                    // Array not full yet — insert in sorted position
                    uint256 pos = count;
                    while (pos > 0 && s.ytOrders[result[pos - 1]].pricePerYt > price) {
                        result[pos] = result[pos - 1];
                        pos--;
                    }
                    result[pos] = orderId;
                    count++;
                } else if (price < s.ytOrders[result[count - 1]].pricePerYt) {
                    // Array full but this order has a better price than the worst — replace and re-sort
                    uint256 pos = count - 1;
                    while (pos > 0 && s.ytOrders[result[pos - 1]].pricePerYt > price) {
                        result[pos] = result[pos - 1];
                        pos--;
                    }
                    result[pos] = orderId;
                }
            }
        }

        // Trim to actual count
        if (count < maxResults) {
            assembly {
                mstore(result, count)
            }
        }

        return result;
    }

    /**
     * @notice Get sorted buy orders (descending by price - best first)
     * @dev Internal helper for marketSell. Capped at MAX_MARKET_ORDER_SWEEPS
     *      to prevent unbounded gas consumption.
     */
    function _getSortedBuyOrders(bytes32 poolId, uint256 cycleId) internal view returns (uint256[] memory) {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        uint256[] storage orderIds = s.ytOrdersByPool[poolId];
        uint256 maxResults = MAX_MARKET_ORDER_SWEEPS;

        // Single pass: collect valid buy orders up to maxResults, keeping sorted by price descending
        uint256[] memory result = new uint256[](maxResults);
        uint256 count = 0;

        for (uint256 i = 0; i < orderIds.length; i++) {
            LibAppStorage.YTOrder storage order = s.ytOrders[orderIds[i]];
            if (
                order.isActive && !order.isSellOrder && order.cycleId == cycleId && order.filledAmount < order.ytAmount
                    && block.timestamp < order.expiresAt
            ) {
                uint256 price = order.pricePerYt;
                uint256 orderId = orderIds[i];

                if (count < maxResults) {
                    // Array not full yet — insert in sorted position (descending)
                    uint256 pos = count;
                    while (pos > 0 && s.ytOrders[result[pos - 1]].pricePerYt < price) {
                        result[pos] = result[pos - 1];
                        pos--;
                    }
                    result[pos] = orderId;
                    count++;
                } else if (price > s.ytOrders[result[count - 1]].pricePerYt) {
                    // Array full but this order has a better price than the worst — replace and re-sort
                    uint256 pos = count - 1;
                    while (pos > 0 && s.ytOrders[result[pos - 1]].pricePerYt < price) {
                        result[pos] = result[pos - 1];
                        pos--;
                    }
                    result[pos] = orderId;
                }
            }
        }

        // Trim to actual count
        if (count < maxResults) {
            assembly {
                mstore(result, count)
            }
        }

        return result;
    }

    // ============================================================
    //                      VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Get order details
     * @param orderId Order ID
     * @return order Order struct
     */
    function getOrder(uint256 orderId) external view returns (Order memory) {
        LibAppStorage.YTOrder storage o = LibAppStorage.diamondStorage().ytOrders[orderId];

        return Order({
            id: o.id,
            maker: o.maker,
            poolId: o.poolId,
            cycleId: o.cycleId,
            ytAmount: o.ytAmount,
            filledAmount: o.filledAmount,
            pricePerYt: o.pricePerYt,
            isSellOrder: o.isSellOrder,
            createdAt: o.createdAt,
            expiresAt: o.expiresAt,
            isActive: o.isActive
        });
    }

    /**
     * @notice Get all active orders for a pool
     * @param poolId Pool identifier
     * @return orders Array of active orders
     */
    function getActiveOrders(bytes32 poolId) external view returns (Order[] memory orders) {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        uint256[] storage orderIds = s.ytOrdersByPool[poolId];

        // Count active orders
        uint256 activeCount = 0;
        for (uint256 i = 0; i < orderIds.length; i++) {
            LibAppStorage.YTOrder storage o = s.ytOrders[orderIds[i]];
            if (o.isActive && o.expiresAt > block.timestamp) {
                activeCount++;
            }
        }

        // Build array
        orders = new Order[](activeCount);
        uint256 idx = 0;
        for (uint256 i = 0; i < orderIds.length && idx < activeCount; i++) {
            LibAppStorage.YTOrder storage o = s.ytOrders[orderIds[i]];
            if (o.isActive && o.expiresAt > block.timestamp) {
                orders[idx++] = Order({
                    id: o.id,
                    maker: o.maker,
                    poolId: o.poolId,
                    cycleId: o.cycleId,
                    ytAmount: o.ytAmount,
                    filledAmount: o.filledAmount,
                    pricePerYt: o.pricePerYt,
                    isSellOrder: o.isSellOrder,
                    createdAt: o.createdAt,
                    expiresAt: o.expiresAt,
                    isActive: o.isActive
                });
            }
        }
    }

    /**
     * @notice Get escrow amount for a buy order
     * @param orderId Order ID
     * @return amount Escrowed quote tokens
     */
    function getOrderEscrow(uint256 orderId) external view returns (uint256) {
        return LibAppStorage.diamondStorage().ytOrderEscrow[orderId];
    }

    /**
     * @notice Get orderbook summary for a pool (for UI display)
     * @dev Iterates through all orders to calculate summary stats.
     *      For large orderbooks, consider using events for indexing instead.
     *
     * @param poolId Pool identifier
     * @return sellOrderCount Active sell orders count
     * @return buyOrderCount Active buy orders count
     * @return bestSellPrice Best (lowest) sell price in bps (0 if no orders)
     * @return bestBuyPrice Best (highest) buy price in bps (0 if no orders)
     * @return totalSellVolume Total YT available for sale
     * @return totalBuyVolume Total YT demand in buy orders
     */
    function getOrderbookSummary(bytes32 poolId)
        external
        view
        returns (
            uint256 sellOrderCount,
            uint256 buyOrderCount,
            uint256 bestSellPrice,
            uint256 bestBuyPrice,
            uint256 totalSellVolume,
            uint256 totalBuyVolume
        )
    {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        uint256[] storage orderIds = s.ytOrdersByPool[poolId];

        // Initialize best prices (sell = lowest, buy = highest)
        bestSellPrice = type(uint256).max;
        bestBuyPrice = 0;

        for (uint256 i = 0; i < orderIds.length; i++) {
            LibAppStorage.YTOrder storage o = s.ytOrders[orderIds[i]];

            // Skip inactive or expired orders
            if (!o.isActive || o.expiresAt <= block.timestamp) {
                continue;
            }

            uint256 remainingAmount = o.ytAmount - o.filledAmount;

            if (o.isSellOrder) {
                sellOrderCount++;
                totalSellVolume += remainingAmount;
                if (o.pricePerYt < bestSellPrice) {
                    bestSellPrice = o.pricePerYt;
                }
            } else {
                buyOrderCount++;
                totalBuyVolume += remainingAmount;
                if (o.pricePerYt > bestBuyPrice) {
                    bestBuyPrice = o.pricePerYt;
                }
            }
        }

        // Reset to 0 if no orders found
        if (bestSellPrice == type(uint256).max) {
            bestSellPrice = 0;
        }
    }

    // ============================================================
    //                    INTERNAL HELPERS
    // ============================================================

    /**
     * @notice Validate order for filling
     * @dev Checks: order exists, is active, not expired, correct type, cycle not matured
     */
    function _validateOrderForFill(LibAppStorage.YTOrder storage order, uint256 orderId, bool expectSellOrder)
        internal
        view
    {
        if (order.id == 0) {
            revert OrderNotFound(orderId);
        }
        if (!order.isActive) {
            revert OrderNotActive(orderId);
        }
        if (block.timestamp >= order.expiresAt) {
            revert OrderExpired(orderId);
        }
        if (order.isSellOrder != expectSellOrder) {
            revert OrderNotActive(orderId); // Wrong order type
        }

        // Check cycle has not matured (no point trading YT after maturity)
        LibAppStorage.CycleInfo storage cycle = LibAppStorage.diamondStorage().cycles[order.poolId][order.cycleId];
        if (block.timestamp >= cycle.maturityDate) {
            revert CycleMatured(order.poolId, order.cycleId);
        }
    }
}
