// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibYieldForgeMarket} from "../libraries/LibYieldForgeMarket.sol";
import {LibPause} from "../libraries/LibPause.sol";
import {LibReentrancyGuard} from "../libraries/LibReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title YieldForgeMarketFacet
 * @author Yield Forge Team
 * @notice Enables YieldForge market trading for Principal Tokens (PT)
 * @dev Implements a built-in AMM with single-sided liquidity
 *
 * ARCHITECTURE:
 * -------------
 * This facet provides a constant-product AMM where:
 * - LPs deposit only PT tokens (single-sided)
 * - Quote token reserves are virtual (calculated from PT price)
 * - Trading fees are dynamic based on time to maturity
 *
 * WHY SINGLE-SIDED LIQUIDITY?
 * ---------------------------
 * PT tokens have a known maturity date and will converge to par value.
 * Traditional 50/50 liquidity would cause unnecessary IL for LPs.
 * Instead:
 * - LPs deposit PT only
 * - Virtual quote = PT * (1 - discount)
 * - AMM maintains x*y=k with virtual quote
 *
 * LIFECYCLE:
 * ----------
 * 1. Cycle starts → YieldForge market created (PENDING)
 * 2. First LP deposits PT → Sets initial price, market ACTIVE
 * 3. Trading enabled → Users swap quote↔PT
 * 4. Maturity reached → Market EXPIRED
 * 5. LPs withdraw PT (at par value)
 *
 * EXAMPLE FLOW:
 * -------------
 * - Pool: USDC/WETH with USDC as quoteToken
 * - PT represents claim on LP position
 * - User swaps USDC for PT at discount (getting future yield exposure)
 * - At maturity, PT redeems for underlying LP position
 *
 * SECURITY NOTES:
 * ---------------
 * - All transfers use SafeERC20
 * - Slippage protection via minOut/maxIn parameters
 * - Re-entrancy protection via checks-effects-interactions pattern
 * - Market must be ACTIVE for swaps
 */
contract YieldForgeMarketFacet {
    using SafeERC20 for IERC20;

    // ============================================================
    //                          EVENTS
    // ============================================================

    /// @notice Emitted when liquidity is added to YieldForge market
    event YieldForgeLiquidityAdded(
        bytes32 indexed poolId, uint256 indexed cycleId, address indexed user, uint256 ptAmount, uint256 lpTokens
    );

    /// @notice Emitted when liquidity is removed from YieldForge market
    event YieldForgeLiquidityRemoved(
        bytes32 indexed poolId,
        uint256 indexed cycleId,
        address indexed user,
        uint256 lpTokens,
        uint256 ptAmount,
        uint256 quoteAmount
    );

    /// @notice Emitted when a swap occurs
    event YieldForgeSwap(
        bytes32 indexed poolId,
        uint256 indexed cycleId,
        address indexed user,
        uint256 ptIn,
        uint256 ptOut,
        uint256 quoteIn,
        uint256 quoteOut
    );

    /// @notice Emitted when first LP sets initial price
    event YieldForgeMarketActivated(bytes32 indexed poolId, uint256 indexed cycleId, uint256 initialDiscountBps);

    /// @notice Emitted when market reserves change (liquidity add/remove/swap)
    event MarketReservesUpdated(
        bytes32 indexed poolId,
        uint256 indexed cycleId,
        uint256 ptReserve,
        uint256 realQuoteReserve,
        uint256 totalLpShares
    );

    // ============================================================
    //                          ERRORS
    // ============================================================

    /// @notice Pool not found
    error PoolNotFound(bytes32 poolId);

    /// @notice Pool is banned
    error PoolBanned(bytes32 poolId);

    /// @notice Market not in expected status
    error InvalidMarketStatus(
        LibAppStorage.YieldForgeMarketStatus expected, LibAppStorage.YieldForgeMarketStatus actual
    );

    /// @notice Market is expired (after maturity)
    error MarketExpired(bytes32 poolId, uint256 cycleId);

    /// @notice Market is pending (no liquidity yet)
    error MarketPending(bytes32 poolId, uint256 cycleId);

    /// @notice Slippage tolerance exceeded
    error SlippageExceeded(uint256 expected, uint256 actual);

    /// @notice Invalid discount value
    error InvalidDiscount(uint256 discountBps);

    /// @notice Zero amount provided
    error ZeroAmount();

    /// @notice Insufficient LP balance
    error InsufficientLpBalance(uint256 required, uint256 available);

    /// @notice Insufficient quote liquidity in pool
    error InsufficientQuoteLiquidity(uint256 required, uint256 available);

    // ============================================================
    //                   PRIVATE HELPERS
    // ============================================================

    /**
     * @notice Scale amount UP from native decimals to 18 decimals
     * @dev Used at entry points (quote token coming in)
     * @param amount Amount in native decimals
     * @param decimals Token decimals (e.g., 6 for USDT)
     * @return Scaled amount in 18 decimals
     */
    function _scaleUp(uint256 amount, uint8 decimals) private pure returns (uint256) {
        if (decimals >= 18) return amount;
        return amount * (10 ** (18 - decimals));
    }

    /**
     * @notice Scale amount DOWN from 18 decimals to native decimals
     * @dev Used at exit points (quote token going out)
     * @param amount Amount in 18 decimals
     * @param decimals Token decimals (e.g., 6 for USDT)
     * @return Scaled amount in native decimals
     */
    function _scaleDown(uint256 amount, uint8 decimals) private pure returns (uint256) {
        if (decimals >= 18) return amount;
        return amount / (10 ** (18 - decimals));
    }

    // ============================================================
    //                     LIQUIDITY FUNCTIONS
    // ============================================================

    /**
     * @notice Add liquidity to the YieldForge market
     * @dev For first LP: sets initial price via discount
     *      For subsequent LPs: adds at current price
     *
     * FIRST LP BEHAVIOR:
     * - Must specify initialDiscountBps (e.g., 500 = 5% discount)
     * - Sets the initial PT price
     * - Receives PT LP tokens proportional to deposit
     * - MINIMUM_LIQUIDITY is locked forever
     *
     * SUBSEQUENT LP BEHAVIOR:
     * - initialDiscountBps is ignored (current price used)
     * - Receives LP tokens proportional to contribution
     *
     * @param poolId Pool identifier
     * @param ptAmount Amount of PT to deposit
     * @param initialDiscountBps Initial PT discount (only for first LP)
     * @return lpTokens LP tokens minted to caller
     *
     * @custom:example
     * // First LP deposits at 5% discount
     * addYieldForgeLiquidity(poolId, 1000e18, 500);
     *
     * // Subsequent LP deposits (uses current price)
     * addYieldForgeLiquidity(poolId, 500e18, 0);
     */
    function addYieldForgeLiquidity(bytes32 poolId, uint256 ptAmount, uint256 initialDiscountBps)
        external
        returns (uint256 lpTokens)
    {
        // ===== SECURITY CHECKS =====
        LibPause.requireNotPaused();
        LibReentrancyGuard._nonReentrantBefore();

        if (ptAmount == 0) revert ZeroAmount();

        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();

        // Validate pool exists and not banned
        LibAppStorage.PoolInfo storage pool = s.pools[poolId];
        if (!pool.exists) revert PoolNotFound(poolId);
        if (pool.isBanned) revert PoolBanned(poolId);

        // Get current cycle
        uint256 cycleId = s.currentCycleId[poolId];
        LibAppStorage.CycleInfo storage cycle = s.cycles[poolId][cycleId];

        // Check cycle hasn't expired
        if (block.timestamp >= cycle.maturityDate) {
            revert MarketExpired(poolId, cycleId);
        }

        LibAppStorage.YieldForgeMarketInfo storage market = s.yieldForgeMarkets[poolId][cycleId];

        // Get PT token
        address ptToken = cycle.ptToken;

        // Transfer PT from user
        IERC20(ptToken).safeTransferFrom(msg.sender, address(this), ptAmount);

        // Check if this is first LP or market was emptied (needs re-pricing)
        bool needsInitialPricing =
            market.status == LibAppStorage.YieldForgeMarketStatus.PENDING || market.totalLpShares == 0;

        if (needsInitialPricing) {
            // First LP or re-activation after all liquidity withdrawn - set price via discount
            // Max discount is 99% (9900 bps) to ensure PT has some value
            if (initialDiscountBps == 0 || initialDiscountBps > 9900) {
                revert InvalidDiscount(initialDiscountBps);
            }

            uint256 virtualQuote;
            // Calculate initial LP tokens (all in 18 decimals)
            (lpTokens, virtualQuote) = LibYieldForgeMarket.calculateInitialLpTokens(ptAmount, initialDiscountBps);

            // Update market state
            market.status = LibAppStorage.YieldForgeMarketStatus.ACTIVE;
            market.ptReserve = ptAmount;
            market.virtualQuoteReserve = virtualQuote;
            market.totalLpShares = lpTokens;

            // Safety reset: When all LPs withdraw via removeYieldForgeLiquidity(),
            // they receive their proportional share of realQuoteReserve and accumulated fees.
            // After complete withdrawal (totalLpShares = 0), these values should already be 0.
            // We explicitly reset them here as a safety measure against potential rounding dust
            // and to ensure clean state for the newly re-activated market.
            market.realQuoteReserve = 0;
            market.accumulatedFeesPT = 0;
            market.accumulatedFeesQuote = 0;

            if (market.createdAt == 0) {
                market.createdAt = block.timestamp;
            }

            // Mint LP tokens to user
            s.yieldForgeLpBalances[poolId][cycleId][msg.sender] = lpTokens;

            emit YieldForgeMarketActivated(poolId, cycleId, initialDiscountBps);
        } else if (market.status == LibAppStorage.YieldForgeMarketStatus.ACTIVE) {
            // Subsequent LP - use current price (discount ignored)
            lpTokens = LibYieldForgeMarket.calculateSubsequentLpTokens(ptAmount, market.ptReserve, market.totalLpShares);

            // Calculate proportional virtual quote to maintain price
            uint256 additionalVirtualQuote = (ptAmount * market.virtualQuoteReserve) / market.ptReserve;

            // Update market state
            market.ptReserve += ptAmount;
            market.virtualQuoteReserve += additionalVirtualQuote;
            market.totalLpShares += lpTokens;

            // Mint LP tokens to user
            s.yieldForgeLpBalances[poolId][cycleId][msg.sender] += lpTokens;
        } else {
            revert InvalidMarketStatus(LibAppStorage.YieldForgeMarketStatus.ACTIVE, market.status);
        }

        emit YieldForgeLiquidityAdded(poolId, cycleId, msg.sender, ptAmount, lpTokens);

        emit MarketReservesUpdated(poolId, cycleId, market.ptReserve, market.realQuoteReserve, market.totalLpShares);

        // ===== REENTRANCY GUARD EXIT =====
        LibReentrancyGuard._nonReentrantAfter();
    }

    /**
     * @notice Remove liquidity from the YieldForge market
     * @dev Burns LP tokens and returns proportional PT
     *
     * WITHDRAWAL:
     * - LP tokens are burned
     * - User receives proportional PT from reserve
     * - Accumulated fees are included in PT amount
     *
     * NOTE: After maturity, PT can be redeemed 1:1 for underlying
     *
     * @param poolId Pool identifier
     * @param lpTokens LP tokens to burn
     * @return ptAmount PT tokens returned
     *
     * @custom:example
     * removeYieldForgeLiquidity(poolId, 100e18);
     */
    function removeYieldForgeLiquidity(bytes32 poolId, uint256 lpTokens)
        external
        returns (uint256 ptAmount, uint256 quoteAmount)
    {
        // ===== SECURITY CHECKS =====
        LibReentrancyGuard._nonReentrantBefore();

        if (lpTokens == 0) revert ZeroAmount();

        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();

        // Validate pool exists
        LibAppStorage.PoolInfo storage pool = s.pools[poolId];
        if (!pool.exists) revert PoolNotFound(poolId);

        // Get current cycle
        uint256 cycleId = s.currentCycleId[poolId];
        LibAppStorage.CycleInfo storage cycle = s.cycles[poolId][cycleId];

        LibAppStorage.YieldForgeMarketInfo storage market = s.yieldForgeMarkets[poolId][cycleId];

        // Validate user has enough LP tokens
        uint256 userLpBalance = s.yieldForgeLpBalances[poolId][cycleId][msg.sender];
        if (userLpBalance < lpTokens) {
            revert InsufficientLpBalance(lpTokens, userLpBalance);
        }

        // Calculate proportional shares
        uint256 lpShare = lpTokens;
        uint256 totalShares = market.totalLpShares;

        // PT amount from reserve
        ptAmount = (lpShare * market.ptReserve) / totalShares;

        // Quote amount from realQuoteReserve (native decimals)
        // Note: realQuoteReserve already includes LP fees from swaps
        quoteAmount = (lpShare * market.realQuoteReserve) / totalShares;

        // Add proportional share of accumulated PT fees
        // Note: PT fees are tracked separately in accumulatedFeesPT
        uint256 ptFeeShare = (lpShare * market.accumulatedFeesPT) / totalShares;

        // Quote fees (accumulatedFeesQuote) are already included in realQuoteReserve
        // so we only track them for proper state accounting, not for transfer
        uint256 quoteFeeShare = (lpShare * market.accumulatedFeesQuote) / totalShares;

        // Total PT includes fee share (PT fees are separate from reserve)
        ptAmount += ptFeeShare;
        // quoteAmount already includes fees via realQuoteReserve - no addition needed

        // Calculate proportional virtual quote reduction
        uint256 virtualQuoteReduction = (lpShare * market.virtualQuoteReserve) / totalShares;

        // Update state BEFORE transfer (CEI pattern)
        s.yieldForgeLpBalances[poolId][cycleId][msg.sender] -= lpTokens;
        market.totalLpShares -= lpTokens;
        market.ptReserve -= (lpShare * market.ptReserve) / totalShares; // Original amount, not including fees
        market.realQuoteReserve -= (lpShare * market.realQuoteReserve) / totalShares;
        market.virtualQuoteReserve -= virtualQuoteReduction;
        market.accumulatedFeesPT -= ptFeeShare;
        market.accumulatedFeesQuote -= quoteFeeShare;

        // Transfer PT to user
        address ptToken = cycle.ptToken;
        if (ptAmount > 0) {
            IERC20(ptToken).safeTransfer(msg.sender, ptAmount);
        }

        // Transfer quote to user
        if (quoteAmount > 0) {
            IERC20(pool.quoteToken).safeTransfer(msg.sender, quoteAmount);
        }

        emit YieldForgeLiquidityRemoved(poolId, cycleId, msg.sender, lpTokens, ptAmount, quoteAmount);

        emit MarketReservesUpdated(poolId, cycleId, market.ptReserve, market.realQuoteReserve, market.totalLpShares);

        // ===== REENTRANCY GUARD EXIT =====
        LibReentrancyGuard._nonReentrantAfter();
    }

    // ============================================================
    //                      SWAP FUNCTIONS
    // ============================================================

    /**
     * @notice Swap exact quote tokens for PT
     * @dev User deposits quote, receives PT at current AMM price
     *
     * PRICING:
     * Uses constant product formula: x * y = k
     * - Input: quoteToken (actual tokens transferred)
     * - Output: PT (from pool reserve)
     * - Fee: Dynamic based on time to maturity
     *
     * FEE DISTRIBUTION:
     * - 80% of fee added to LP reserves (in quote)
     * - 20% of fee to protocol
     *
     * @param poolId Pool identifier
     * @param quoteAmountIn Amount of quote token to swap
     * @param minPtOut Minimum PT to receive (slippage protection)
     * @return ptOut PT tokens received
     *
     * @custom:example
     * // Swap 100 USDC for PT with 1% slippage tolerance
     * swapExactQuoteForPT(poolId, 100e6, 99e18);
     */
    function swapExactQuoteForPT(bytes32 poolId, uint256 quoteAmountIn, uint256 minPtOut)
        external
        returns (uint256 ptOut)
    {
        // ===== SECURITY CHECKS =====
        LibPause.requireNotPaused();
        LibReentrancyGuard._nonReentrantBefore();

        if (quoteAmountIn == 0) revert ZeroAmount();

        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();

        // Validate pool and status
        LibAppStorage.PoolInfo storage pool = s.pools[poolId];
        if (!pool.exists) revert PoolNotFound(poolId);
        if (pool.isBanned) revert PoolBanned(poolId);

        uint256 cycleId = s.currentCycleId[poolId];
        LibAppStorage.CycleInfo storage cycle = s.cycles[poolId][cycleId];
        LibAppStorage.YieldForgeMarketInfo storage market = s.yieldForgeMarkets[poolId][cycleId];

        // Validate market is active
        if (market.status != LibAppStorage.YieldForgeMarketStatus.ACTIVE) {
            revert InvalidMarketStatus(LibAppStorage.YieldForgeMarketStatus.ACTIVE, market.status);
        }

        // Check not expired
        if (block.timestamp >= cycle.maturityDate) {
            // Update status and revert
            market.status = LibAppStorage.YieldForgeMarketStatus.EXPIRED;
            revert MarketExpired(poolId, cycleId);
        }

        // Calculate dynamic fee
        uint256 feeBps = LibYieldForgeMarket.getSwapFeeBps(cycle.maturityDate);

        // Scale quote input to 18 decimals for AMM calculation
        // All internal AMM math uses normalized 18 decimal values
        uint256 quoteIn18 = _scaleUp(quoteAmountIn, pool.quoteDecimals);

        // Calculate output: quote → PT (all 18 decimals)
        uint256 feeAmount18;
        (ptOut, feeAmount18) =
            LibYieldForgeMarket.getAmountOut(quoteIn18, market.virtualQuoteReserve, market.ptReserve, feeBps);

        // Slippage check
        if (ptOut < minPtOut) {
            revert SlippageExceeded(minPtOut, ptOut);
        }

        // Split fee (18 decimals)
        (uint256 lpFee18, uint256 protocolFee18) = LibYieldForgeMarket.splitFee(feeAmount18);

        // Transfer quote from user (native decimals)
        address quoteToken = pool.quoteToken;
        IERC20(quoteToken).safeTransferFrom(msg.sender, address(this), quoteAmountIn);

        // Update reserves (all 18 decimals internally)
        market.virtualQuoteReserve += (quoteIn18 - feeAmount18);
        market.ptReserve -= ptOut;
        market.accumulatedFeesQuote += lpFee18;

        // Track real quote tokens staying in contract (native decimals)
        // quoteAmountIn - protocolFee (in native decimals)
        uint256 realQuoteStaying = quoteAmountIn - _scaleDown(protocolFee18, pool.quoteDecimals);
        market.realQuoteReserve += realQuoteStaying;

        // Scale down protocol fee for actual transfer
        uint256 protocolFee = _scaleDown(protocolFee18, pool.quoteDecimals);
        if (protocolFee > 0) {
            IERC20(quoteToken).safeTransfer(s.protocolFeeRecipient, protocolFee);
        }

        // Transfer PT to user (already 18 decimals)
        IERC20(cycle.ptToken).safeTransfer(msg.sender, ptOut);

        emit YieldForgeSwap(
            poolId,
            cycleId,
            msg.sender,
            0,
            ptOut,
            quoteAmountIn, // Native decimals for correct display
            0
        );

        emit MarketReservesUpdated(poolId, cycleId, market.ptReserve, market.realQuoteReserve, market.totalLpShares);

        // ===== REENTRANCY GUARD EXIT =====
        LibReentrancyGuard._nonReentrantAfter();
    }

    /**
     * @notice Swap exact PT for quote tokens
     * @dev User deposits PT, receives quote at current AMM price
     *
     * @param poolId Pool identifier
     * @param ptAmountIn Amount of PT to swap
     * @param minQuoteOut Minimum quote to receive (slippage protection)
     * @return quoteOut Quote tokens received
     *
     * @custom:example
     * // Swap 100 PT for USDC with 1% slippage tolerance
     * swapExactPTForQuote(poolId, 100e18, 95e6);
     */
    function swapExactPTForQuote(bytes32 poolId, uint256 ptAmountIn, uint256 minQuoteOut)
        external
        returns (uint256 quoteOut)
    {
        // ===== SECURITY CHECKS =====
        LibPause.requireNotPaused();
        LibReentrancyGuard._nonReentrantBefore();

        if (ptAmountIn == 0) revert ZeroAmount();

        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();

        // Validate pool and status
        LibAppStorage.PoolInfo storage pool = s.pools[poolId];
        if (!pool.exists) revert PoolNotFound(poolId);
        if (pool.isBanned) revert PoolBanned(poolId);

        uint256 cycleId = s.currentCycleId[poolId];
        LibAppStorage.CycleInfo storage cycle = s.cycles[poolId][cycleId];
        LibAppStorage.YieldForgeMarketInfo storage market = s.yieldForgeMarkets[poolId][cycleId];

        // Validate market is active
        if (market.status != LibAppStorage.YieldForgeMarketStatus.ACTIVE) {
            revert InvalidMarketStatus(LibAppStorage.YieldForgeMarketStatus.ACTIVE, market.status);
        }

        // Check not expired
        if (block.timestamp >= cycle.maturityDate) {
            market.status = LibAppStorage.YieldForgeMarketStatus.EXPIRED;
            revert MarketExpired(poolId, cycleId);
        }

        // Calculate dynamic fee
        uint256 feeBps = LibYieldForgeMarket.getSwapFeeBps(cycle.maturityDate);

        // Calculate output: PT → quote (all 18 decimals internally)
        // Uses time-aware pricing: sellers get more quote per PT as maturity approaches
        uint256 feeAmount18;
        uint256 quoteOut18;
        (quoteOut18, feeAmount18) = LibYieldForgeMarket.getAmountOutPtToQuote(
            ptAmountIn, market.ptReserve, market.virtualQuoteReserve, feeBps, market.createdAt, cycle.maturityDate
        );

        // Scale down quote output for slippage check and transfer
        quoteOut = _scaleDown(quoteOut18, pool.quoteDecimals);

        // Slippage check (user specifies minQuoteOut in native decimals)
        if (quoteOut < minQuoteOut) {
            revert SlippageExceeded(minQuoteOut, quoteOut);
        }

        // Split fee (fee is in PT terms, stays 18 decimals)
        (uint256 lpFee, uint256 protocolFee) = LibYieldForgeMarket.splitFee(feeAmount18);

        // Transfer PT from user
        IERC20(cycle.ptToken).safeTransferFrom(msg.sender, address(this), ptAmountIn);

        // Update reserves (all 18 decimals)
        market.ptReserve += (ptAmountIn - feeAmount18);
        market.virtualQuoteReserve -= quoteOut18;
        market.accumulatedFeesPT += lpFee;

        // Deduct real quote tokens leaving the contract (native decimals)
        if (market.realQuoteReserve < quoteOut) {
            revert InsufficientQuoteLiquidity(quoteOut, market.realQuoteReserve);
        }
        market.realQuoteReserve -= quoteOut;

        // Transfer protocol fee (in PT) to recipient
        if (protocolFee > 0) {
            IERC20(cycle.ptToken).safeTransfer(s.protocolFeeRecipient, protocolFee);
        }

        // Transfer quote to user (native decimals)
        IERC20(pool.quoteToken).safeTransfer(msg.sender, quoteOut);

        emit YieldForgeSwap(
            poolId,
            cycleId,
            msg.sender,
            ptAmountIn,
            0,
            0,
            quoteOut // Native decimals for correct display
        );

        emit MarketReservesUpdated(poolId, cycleId, market.ptReserve, market.realQuoteReserve, market.totalLpShares);

        // ===== REENTRANCY GUARD EXIT =====
        LibReentrancyGuard._nonReentrantAfter();
    }

    // ============================================================
    //                      VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Get YieldForge market info for a pool's current cycle
     * @param poolId Pool identifier
     * @return status Market status
     * @return ptReserve PT tokens in pool
     * @return virtualQuoteReserve Virtual quote reserve (for AMM pricing)
     * @return realQuoteReserve Actual quote tokens held in contract
     * @return totalLpShares Total LP shares outstanding
     * @return accumulatedFeesPT Accumulated fees in PT
     * @return accumulatedFeesQuote Accumulated fees in quote
     */
    function getYieldForgeMarketInfo(bytes32 poolId)
        external
        view
        returns (
            LibAppStorage.YieldForgeMarketStatus status,
            uint256 ptReserve,
            uint256 virtualQuoteReserve,
            uint256 realQuoteReserve,
            uint256 totalLpShares,
            uint256 accumulatedFeesPT,
            uint256 accumulatedFeesQuote
        )
    {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 cycleId = s.currentCycleId[poolId];
        LibAppStorage.YieldForgeMarketInfo storage market = s.yieldForgeMarkets[poolId][cycleId];

        return (
            market.status,
            market.ptReserve,
            market.virtualQuoteReserve,
            market.realQuoteReserve,
            market.totalLpShares,
            market.accumulatedFeesPT,
            market.accumulatedFeesQuote
        );
    }

    /**
     * @notice Preview swap output for quote → PT
     * @dev Input quoteIn is in native quote token decimals
     * @param poolId Pool identifier
     * @param quoteIn Quote amount to swap (native decimals, e.g. 1e6 for USDT)
     * @return ptOut Expected PT output (18 decimals)
     * @return feeBps Current swap fee
     */
    function previewSwapQuoteForPT(bytes32 poolId, uint256 quoteIn)
        external
        view
        returns (uint256 ptOut, uint256 feeBps)
    {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 cycleId = s.currentCycleId[poolId];
        LibAppStorage.CycleInfo storage cycle = s.cycles[poolId][cycleId];
        LibAppStorage.YieldForgeMarketInfo storage market = s.yieldForgeMarkets[poolId][cycleId];

        // Scale quote input to 18 decimals for AMM calculation
        uint256 quoteIn18 = _scaleUp(quoteIn, s.pools[poolId].quoteDecimals);

        feeBps = LibYieldForgeMarket.getSwapFeeBps(cycle.maturityDate);

        // Use time-aware pricing for accurate preview
        (ptOut,) = LibYieldForgeMarket.getAmountOutQuoteToPt(
            quoteIn18, market.virtualQuoteReserve, market.ptReserve, feeBps, market.createdAt, cycle.maturityDate
        );
    }

    /**
     * @notice Preview swap output for PT → quote
     * @dev Output quoteOut is in native quote token decimals
     * @param poolId Pool identifier
     * @param ptIn PT amount to swap (18 decimals)
     * @return quoteOut Expected quote output (native decimals, e.g. 1e6 for USDT)
     * @return feeBps Current swap fee
     */
    function previewSwapPTForQuote(bytes32 poolId, uint256 ptIn)
        external
        view
        returns (uint256 quoteOut, uint256 feeBps)
    {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 cycleId = s.currentCycleId[poolId];
        LibAppStorage.CycleInfo storage cycle = s.cycles[poolId][cycleId];
        LibAppStorage.YieldForgeMarketInfo storage market = s.yieldForgeMarkets[poolId][cycleId];

        feeBps = LibYieldForgeMarket.getSwapFeeBps(cycle.maturityDate);

        // Use time-aware pricing for accurate preview
        uint256 quoteOut18;
        (quoteOut18,) = LibYieldForgeMarket.getAmountOutPtToQuote(
            ptIn, market.ptReserve, market.virtualQuoteReserve, feeBps, market.createdAt, cycle.maturityDate
        );

        // Scale down to native decimals for user
        quoteOut = _scaleDown(quoteOut18, s.pools[poolId].quoteDecimals);
    }

    /**
     * @notice Get current PT price in basis points with time-decay applied
     * @dev Returns effective price that accounts for automatic convergence to parity.
     *      As maturity approaches, the price drifts toward 10000 bps (100% = $1).
     * @param poolId Pool identifier
     * @return priceBps PT price (e.g., 9500 = 0.95 = 5% discount)
     */
    function getPtPrice(bytes32 poolId) external view returns (uint256 priceBps) {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 cycleId = s.currentCycleId[poolId];
        LibAppStorage.CycleInfo storage cycle = s.cycles[poolId][cycleId];
        LibAppStorage.YieldForgeMarketInfo storage market = s.yieldForgeMarkets[poolId][cycleId];

        // Use time-aware effective price
        return LibYieldForgeMarket.getEffectivePtPriceBps(
            market.ptReserve, market.virtualQuoteReserve, market.createdAt, cycle.maturityDate
        );
    }

    /**
     * @notice Get user's LP balance for a pool's current cycle
     * @param poolId Pool identifier
     * @param user User address
     * @return lpBalance User's LP token balance
     */
    function getUserLpBalance(bytes32 poolId, address user) external view returns (uint256 lpBalance) {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 cycleId = s.currentCycleId[poolId];
        return s.yieldForgeLpBalances[poolId][cycleId][user];
    }

    /**
     * @notice Get current swap fee for a pool
     * @param poolId Pool identifier
     * @return feeBps Current fee in basis points
     */
    function getCurrentSwapFee(bytes32 poolId) external view returns (uint256 feeBps) {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 cycleId = s.currentCycleId[poolId];
        LibAppStorage.CycleInfo storage cycle = s.cycles[poolId][cycleId];

        return LibYieldForgeMarket.getSwapFeeBps(cycle.maturityDate);
    }

    /**
     * @notice Get user's LP position value (PT + quote they can withdraw)
     * @dev Calculates proportional share of reserves plus accumulated fees
     * @param poolId Pool identifier
     * @param user User address
     * @return lpBalance User's LP token balance
     * @return ptAmount PT tokens the user can withdraw
     * @return quoteAmount Quote tokens the user can withdraw (native decimals)
     */
    function getLpPositionValue(bytes32 poolId, address user)
        external
        view
        returns (uint256 lpBalance, uint256 ptAmount, uint256 quoteAmount)
    {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 cycleId = s.currentCycleId[poolId];
        LibAppStorage.PoolInfo storage pool = s.pools[poolId];
        LibAppStorage.YieldForgeMarketInfo storage market = s.yieldForgeMarkets[poolId][cycleId];

        lpBalance = s.yieldForgeLpBalances[poolId][cycleId][user];

        if (lpBalance == 0 || market.totalLpShares == 0) {
            return (lpBalance, 0, 0);
        }

        uint256 totalShares = market.totalLpShares;

        // Calculate proportional share of PT reserve + fees
        ptAmount = (lpBalance * market.ptReserve) / totalShares;
        uint256 ptFeeShare = (lpBalance * market.accumulatedFeesPT) / totalShares;
        ptAmount += ptFeeShare;

        // Calculate proportional share of real quote reserve + fees
        quoteAmount = (lpBalance * market.realQuoteReserve) / totalShares;
        uint256 quoteFeeShare = (lpBalance * market.accumulatedFeesQuote) / totalShares;
        // quoteFeeShare is in 18 decimals, scale to native
        quoteAmount += _scaleDown(quoteFeeShare, pool.quoteDecimals);
    }
}
