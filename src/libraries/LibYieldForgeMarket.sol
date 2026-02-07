// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * @title LibYieldForgeMarket
 * @author Yield Forge Team
 * @notice Library for yieldForge market AMM calculations
 *
 * ARCHITECTURE:
 * -------------
 * This library handles the mathematical core of the yieldForge market:
 * 1. Dynamic swap fees based on time to maturity
 * 2. Constant product AMM calculations (x * y = k)
 * 3. LP token calculations for single-sided deposits
 *
 * PRICING MODEL:
 * --------------
 * PT trades at a discount to par (face value).
 * Example: PT at 5% discount trades for $0.95 per $1 face value.
 *
 * The discount represents the implied yield to maturity:
 * - Higher discount = Higher yield
 * - Discount approaches 0 as maturity approaches
 *
 * SINGLE-SIDED LIQUIDITY:
 * ----------------------
 * Unlike traditional AMMs, LPs only deposit PT tokens.
 * The "quote side" is virtual, calculated from PT price.
 *
 * When LP deposits 1000 PT at 5% discount:
 * - ptReserve increases by 1000
 * - virtualQuoteReserve increases by 950 (1000 * 0.95)
 * - LP receives shares proportional to their contribution
 *
 * FEE STRUCTURE:
 * ----------------------------
 * Fees scale with time-to-maturity to compensate LPs for impermanent loss risk:
 * - Far from maturity (1+ year): 0.1% (10 bps) - minimal risk
 * - Near maturity: Up to 0.5% (50 bps) - higher risk
 * - Fee distribution: 80% LPs, 20% protocol
 */
library LibYieldForgeMarket {
    // ============================================================
    //                        CONSTANTS
    // ============================================================

    /// @notice Base swap fee when far from maturity (0.1%)
    uint256 internal constant BASE_FEE_BPS = 10;

    /// @notice Maximum swap fee at maturity (0.5%)
    uint256 internal constant MAX_FEE_BPS = 50;

    /// @notice One year in seconds, used for fee scaling
    uint256 internal constant YEAR = 365 days;

    /// @notice Basis points denominator (10000 = 100%)
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Fee share going to LPs (80%)
    uint256 internal constant LP_FEE_SHARE_BPS = 8_000;

    /// @notice Fee share going to protocol (20%)
    uint256 internal constant PROTOCOL_FEE_SHARE_BPS = 2_000;

    /// @notice Precision for time decay calculations (1e18 = 100%)
    /// @dev Used in getTimeDecayFactor() for high-precision quadratic math
    uint256 internal constant TIME_PRECISION = 1e18;

    // ============================================================
    //                        ERRORS
    // ============================================================

    /// @notice Insufficient output amount for swap
    error InsufficientOutputAmount();

    /// @notice Insufficient input amount for swap
    error InsufficientInputAmount();

    /// @notice Insufficient liquidity in the pool
    error InsufficientLiquidity();

    /// @notice Invalid discount (must be 0-9999 bps)
    error InvalidDiscount(uint256 discountBps);

    /// @notice Zero amount provided
    error ZeroAmount();

    // ============================================================
    //                    FEE CALCULATIONS
    // ============================================================

    /**
     * @notice Calculate dynamic swap fee based on time to maturity
     * @dev Fee increases as maturity approaches
     *
     * RATIONALE:
     * LPs face higher impermanent loss risk near maturity because:
     * - PT price approaches par (1:1 with underlying)
     * - Price volatility can cause significant rebalancing
     * - Arbitrageurs are more active as convergence time shortens
     *
     * FEE CURVE:
     * - At maturity: MAX_FEE_BPS (50 bps = 0.5%)
     * - 1+ year to maturity: BASE_FEE_BPS (10 bps = 0.1%)
     * - In between: Linear interpolation
     *
     * Formula: fee = BASE + (MAX - BASE) * (1 - timeToMaturity/YEAR)
     * Clamped to [BASE_FEE_BPS, MAX_FEE_BPS]
     *
     * @param maturityDate Unix timestamp of cycle maturity
     * @return feeBps Swap fee in basis points
     *
     * @custom:example
     * maturity in 180 days: fee = 10 + (50-10) * (365-180)/365 ≈ 30 bps
     * maturity in 30 days:  fee = 10 + (50-10) * (365-30)/365 ≈ 47 bps
     */
    function getSwapFeeBps(
        uint256 maturityDate
    ) internal view returns (uint256 feeBps) {
        // Handle already matured case
        if (block.timestamp >= maturityDate) {
            return MAX_FEE_BPS;
        }

        uint256 timeToMaturity = maturityDate - block.timestamp;

        // Far from maturity (1+ year): use base fee
        if (timeToMaturity >= YEAR) {
            return BASE_FEE_BPS;
        }

        // Linear interpolation between BASE and MAX
        // fee = BASE + (MAX - BASE) * (YEAR - timeToMaturity) / YEAR
        uint256 additionalFee = ((MAX_FEE_BPS - BASE_FEE_BPS) *
            (YEAR - timeToMaturity)) / YEAR;

        return BASE_FEE_BPS + additionalFee;
    }

    /**
     * @notice Split fee between LPs and protocol
     * @param totalFee Total fee amount
     * @return lpFee Fee portion for LPs (80%)
     * @return protocolFee Fee portion for protocol (20%)
     */
    function splitFee(
        uint256 totalFee
    ) internal pure returns (uint256 lpFee, uint256 protocolFee) {
        lpFee = (totalFee * LP_FEE_SHARE_BPS) / BPS_DENOMINATOR;
        protocolFee = totalFee - lpFee; // Remainder to avoid rounding issues
    }

    // ============================================================
    //                  TIME DECAY CALCULATIONS
    // ============================================================

    /**
     * @notice Calculate time decay factor using quadratic curve
     * @dev Returns a value from 0 (at creation) to TIME_PRECISION (at maturity).
     *
     * WHY QUADRATIC (NOT LINEAR)?
     * ---------------------------
     * Quadratic decay provides a more natural price convergence:
     * - Early in the cycle: slow drift → less arbitrage opportunity
     * - Near maturity: fast drift → ensures convergence to parity
     *
     * This mimics real-world yield behavior where most of the discount
     * "unwinds" closer to maturity (similar to bond pricing).
     *
     * FORMULA:
     * factor = (elapsed / duration)²
     *
     * Example with 90-day cycle:
     * - Day 0:  factor = 0
     * - Day 45: factor = (45/90)² = 0.25 (25%)
     * - Day 67: factor = (67/90)² = 0.55 (55%)
     * - Day 90: factor = 1.0 (100%)
     *
     * @param createdAt   Timestamp when the market was created
     * @param maturityDate Timestamp when the cycle matures
     * @return factor Time decay factor (0 to TIME_PRECISION)
     *
     * @custom:security
     * - Returns TIME_PRECISION if already at or past maturity
     * - Returns 0 if current time is before creation (should not happen)
     * - Uses checked math (Solidity 0.8+) for overflow protection
     */
    function getTimeDecayFactor(
        uint256 createdAt,
        uint256 maturityDate
    ) internal view returns (uint256 factor) {
        // Edge case: already at or past maturity
        if (block.timestamp >= maturityDate) {
            return TIME_PRECISION;
        }

        // Edge case: before creation (shouldn't happen in normal operation)
        if (block.timestamp <= createdAt) {
            return 0;
        }

        // Calculate elapsed time and total duration
        uint256 elapsed = block.timestamp - createdAt;
        uint256 duration = maturityDate - createdAt;

        // Quadratic decay: factor = (elapsed / duration)²
        // We compute in two steps to maintain precision:
        // 1. ratio = elapsed * TIME_PRECISION / duration
        // 2. factor = ratio * ratio / TIME_PRECISION
        uint256 ratio = (elapsed * TIME_PRECISION) / duration;
        factor = (ratio * ratio) / TIME_PRECISION;
    }

    /**
     * @notice Calculate effective virtual quote reserve with time decay applied
     * @dev Adjusts the virtual quote reserve to make PT price converge to parity.
     *
     * HOW IT WORKS:
     * -------------
     * PT price in AMM = virtualQuoteReserve / ptReserve
     *
     * At creation (discount 10%):
     *   virtualQuote = 900, ptReserve = 1000 → price = 0.90
     *
     * At maturity (should be parity):
     *   We need price = 1.0 → virtualQuote should equal ptReserve
     *
     * This function interpolates virtualQuote toward ptReserve over time:
     *   effectiveQuote = virtualQuote + (ptReserve - virtualQuote) × decayFactor
     *
     * Example (10% discount, 50% time elapsed):
     *   virtualQuote = 900, ptReserve = 1000, decayFactor = 0.25 (quadratic at 50%)
     *   effectiveQuote = 900 + (1000 - 900) × 0.25 = 925
     *   Effective price = 925/1000 = 0.925 (instead of 0.90)
     *
     * @param virtualQuoteReserve Current virtual quote reserve (18 decimals)
     * @param ptReserve           Current PT reserve (18 decimals)
     * @param createdAt           Market creation timestamp
     * @param maturityDate        Cycle maturity timestamp
     * @return effectiveQuote     Time-adjusted virtual quote reserve
     *
     * @custom:note Both reserves should be in the same denomination (18 decimals)
     *              for correct calculation.
     */
    function getEffectiveVirtualQuoteReserve(
        uint256 virtualQuoteReserve,
        uint256 ptReserve,
        uint256 createdAt,
        uint256 maturityDate
    ) internal view returns (uint256 effectiveQuote) {
        uint256 decayFactor = getTimeDecayFactor(createdAt, maturityDate);

        // If market just started, no adjustment needed
        if (decayFactor == 0) {
            return virtualQuoteReserve;
        }

        // If at maturity, return parity (quote = pt)
        if (decayFactor == TIME_PRECISION) {
            return ptReserve;
        }

        // Interpolate: effectiveQuote = quote + (pt - quote) × factor / PRECISION
        // This handles both cases: quote < pt (discount) and quote > pt (premium)
        if (ptReserve >= virtualQuoteReserve) {
            // Normal case: PT at discount (quote < pt)
            uint256 gap = ptReserve - virtualQuoteReserve;
            effectiveQuote =
                virtualQuoteReserve +
                (gap * decayFactor) /
                TIME_PRECISION;
        } else {
            // Rare case: PT at premium (quote > pt)
            uint256 gap = virtualQuoteReserve - ptReserve;
            effectiveQuote =
                virtualQuoteReserve -
                (gap * decayFactor) /
                TIME_PRECISION;
        }
    }

    /**
     * @notice Calculate effective PT reserve with time decay applied
     * @dev Used for PT→Quote swaps where we need to adjust PT side.
     *
     * This is the inverse adjustment of getEffectiveVirtualQuoteReserve().
     * For PT→Quote swaps, we adjust the PT reserve down toward quote reserve.
     *
     * WHY ADJUST PT RESERVE?
     * ----------------------
     * For Quote→PT: we increase effective quote → user gets more PT per quote
     * For PT→Quote: we decrease effective PT → user gets more quote per PT
     *
     * Both adjustments push PT price toward parity as maturity approaches.
     *
     * @param ptReserve           Current PT reserve (18 decimals)
     * @param virtualQuoteReserve Current virtual quote reserve (18 decimals)
     * @param createdAt           Market creation timestamp
     * @param maturityDate        Cycle maturity timestamp
     * @return effectivePt        Time-adjusted PT reserve
     */
    function getEffectivePtReserve(
        uint256 ptReserve,
        uint256 virtualQuoteReserve,
        uint256 createdAt,
        uint256 maturityDate
    ) internal view returns (uint256 effectivePt) {
        uint256 decayFactor = getTimeDecayFactor(createdAt, maturityDate);

        if (decayFactor == 0) {
            return ptReserve;
        }

        if (decayFactor == TIME_PRECISION) {
            return virtualQuoteReserve;
        }

        // Interpolate: effectivePt = pt + (quote - pt) × factor / PRECISION
        if (virtualQuoteReserve >= ptReserve) {
            uint256 gap = virtualQuoteReserve - ptReserve;
            effectivePt = ptReserve + (gap * decayFactor) / TIME_PRECISION;
        } else {
            uint256 gap = ptReserve - virtualQuoteReserve;
            effectivePt = ptReserve - (gap * decayFactor) / TIME_PRECISION;
        }
    }

    // ============================================================
    //                    AMM CALCULATIONS
    // ============================================================

    /**
     * @notice Calculate output amount for a swap (constant product)
     * @dev Uses x * y = k formula with fee deduction
     *
     * CONSTANT PRODUCT FORMULA:
     * After swap: (reserveIn + amountIn) * (reserveOut - amountOut) = k
     * Solving for amountOut:
     *   amountOut = reserveOut - k / (reserveIn + amountIn)
     *   amountOut = reserveOut * amountIn / (reserveIn + amountIn)
     *
     * With fee:
     *   amountInWithFee = amountIn * (10000 - feeBps) / 10000
     *   Then apply formula above
     *
     * @param amountIn Amount of input token
     * @param reserveIn Reserve of input token
     * @param reserveOut Reserve of output token
     * @param feeBps Fee in basis points
     * @return amountOut Amount of output token
     * @return feeAmount Fee taken from input
     *
     * @custom:example
     * Swap 100 quote for PT:
     *   amountIn = 100, reserveIn = 900 (quote), reserveOut = 1000 (PT)
     *   feeBps = 30
     *   amountInWithFee = 100 * 9970 / 10000 = 99.7
     *   amountOut = 1000 * 99.7 / (900 + 99.7) = 99.73 PT
     */
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 feeBps
    ) internal pure returns (uint256 amountOut, uint256 feeAmount) {
        if (amountIn == 0) revert ZeroAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();

        // Calculate fee
        feeAmount = (amountIn * feeBps) / BPS_DENOMINATOR;
        uint256 amountInAfterFee = amountIn - feeAmount;

        // Constant product formula: amountOut = reserveOut * amountIn / (reserveIn + amountIn)
        // Using multiplication before division to maintain precision
        uint256 numerator = reserveOut * amountInAfterFee;
        uint256 denominator = reserveIn + amountInAfterFee;

        amountOut = numerator / denominator;

        if (amountOut == 0) revert InsufficientOutputAmount();
    }

    /**
     * @notice Calculate required input for desired output (reverse calculation)
     * @dev Used for exactOutput swaps
     *
     * FORMULA DERIVATION:
     * From: (reserveIn + amountIn) * (reserveOut - amountOut) = reserveIn * reserveOut
     * Solving for amountIn:
     *   amountIn = reserveIn * amountOut / (reserveOut - amountOut)
     *
     * With fee adjustment:
     *   amountInBeforeFee = amountIn * 10000 / (10000 - feeBps)
     *
     * @param amountOut Desired output amount
     * @param reserveIn Reserve of input token
     * @param reserveOut Reserve of output token
     * @param feeBps Fee in basis points
     * @return amountIn Required input amount (including fee)
     */
    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 feeBps
    ) internal pure returns (uint256 amountIn) {
        if (amountOut == 0) revert ZeroAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        if (amountOut >= reserveOut) revert InsufficientLiquidity();

        // Calculate amount needed before fee
        uint256 numerator = reserveIn * amountOut;
        uint256 denominator = reserveOut - amountOut;
        uint256 amountInWithoutFee = (numerator / denominator) + 1; // Round up

        // Add fee: amountIn = amountInWithoutFee * 10000 / (10000 - feeBps)
        amountIn =
            (amountInWithoutFee * BPS_DENOMINATOR) /
            (BPS_DENOMINATOR - feeBps) +
            1; // Round up
    }

    // ============================================================
    //                TIME-AWARE AMM CALCULATIONS
    // ============================================================

    /**
     * @notice Calculate output for Quote→PT swap with time-based price convergence
     * @dev This is the main swap function that applies time decay to push PT price toward parity.
     *
     * HOW TIME-AWARE PRICING WORKS:
     * -----------------------------
     * 1. Calculate effective virtual quote reserve (increased toward ptReserve)
     * 2. Use effective reserve in constant product formula
     * 3. Result: user gets more PT per quote as maturity approaches
     *
     * Example (10% initial discount, 50% time elapsed):
     *   Original reserves: quote=900, pt=1000
     *   Effective quote after decay: 925 (moved 25% toward 1000)
     *
     *   Swap 100 quote:
     *   - Without time drift: 100 * 1000 / (900 + 100) = 100 PT
     *   - With time drift:    100 * 1000 / (925 + 100) = 97.6 PT
     *
     *   Wait, that's fewer PT! Let me explain why this is correct:
     *   - Effective price = 925/1000 = 0.925 (vs 0.90 without drift)
     *   - PT is worth MORE (closer to $1), so you get "fewer" PT per quote
     *   - But each PT you get is worth more! Total value is preserved.
     *
     * @param amountIn              Amount of quote token to swap
     * @param virtualQuoteReserve   Current virtual quote reserve (18 decimals)
     * @param ptReserve             Current PT reserve (18 decimals)
     * @param feeBps                Swap fee in basis points
     * @param createdAt             Market creation timestamp
     * @param maturityDate          Cycle maturity timestamp
     * @return amountOut            PT tokens to receive
     * @return feeAmount            Fee deducted from input
     *
     * @custom:security Uses existing getAmountOut internally to minimize code duplication
     */
    function getAmountOutQuoteToPt(
        uint256 amountIn,
        uint256 virtualQuoteReserve,
        uint256 ptReserve,
        uint256 feeBps,
        uint256 createdAt,
        uint256 maturityDate
    ) internal view returns (uint256 amountOut, uint256 feeAmount) {
        // Calculate time-adjusted quote reserve
        uint256 effectiveQuote = getEffectiveVirtualQuoteReserve(
            virtualQuoteReserve,
            ptReserve,
            createdAt,
            maturityDate
        );

        // Use standard AMM formula with effective reserve
        return getAmountOut(amountIn, effectiveQuote, ptReserve, feeBps);
    }

    /**
     * @notice Calculate output for PT→Quote swap with time-based price convergence
     * @dev Applies time decay to PT reserve side for fair PT→Quote pricing.
     *
     * WHY ADJUST PT RESERVE (NOT QUOTE)?
     * ----------------------------------
     * For PT→Quote, the user is selling PT. At maturity, 1 PT = 1 underlying value.
     * We adjust the effective PT reserve DOWN toward quote reserve.
     * This means: same amount of PT gives MORE quote output as maturity approaches.
     *
     * Example (10% initial discount, 50% time elapsed):
     *   Original reserves: pt=1000, quote=900
     *   Effective PT after decay: 975 (moved 25% toward 900)
     *
     *   Swap 100 PT:
     *   - Without drift: 100 * 900 / (1000 + 100) = 81.8 quote
     *   - With drift:    100 * 900 / (975 + 100) = 83.7 quote
     *
     *   User gets MORE quote per PT as maturity approaches ✓
     *
     * @param amountIn              Amount of PT to swap
     * @param ptReserve             Current PT reserve (18 decimals)
     * @param virtualQuoteReserve   Current virtual quote reserve (18 decimals)
     * @param feeBps                Swap fee in basis points
     * @param createdAt             Market creation timestamp
     * @param maturityDate          Cycle maturity timestamp
     * @return amountOut            Quote tokens to receive
     * @return feeAmount            Fee deducted from input
     */
    function getAmountOutPtToQuote(
        uint256 amountIn,
        uint256 ptReserve,
        uint256 virtualQuoteReserve,
        uint256 feeBps,
        uint256 createdAt,
        uint256 maturityDate
    ) internal view returns (uint256 amountOut, uint256 feeAmount) {
        // Calculate time-adjusted PT reserve
        uint256 effectivePt = getEffectivePtReserve(
            ptReserve,
            virtualQuoteReserve,
            createdAt,
            maturityDate
        );

        // Use standard AMM formula with effective reserve
        return getAmountOut(amountIn, effectivePt, virtualQuoteReserve, feeBps);
    }

    /**
     * @notice Calculate required Quote input for desired PT output (with time drift)
     * @dev ExactOutput version of getAmountOutQuoteToPt
     *
     * @param amountOut             Desired PT amount to receive
     * @param virtualQuoteReserve   Current virtual quote reserve (18 decimals)
     * @param ptReserve             Current PT reserve (18 decimals)
     * @param feeBps                Swap fee in basis points
     * @param createdAt             Market creation timestamp
     * @param maturityDate          Cycle maturity timestamp
     * @return amountIn             Quote tokens required (including fee)
     */
    function getAmountInQuoteToPt(
        uint256 amountOut,
        uint256 virtualQuoteReserve,
        uint256 ptReserve,
        uint256 feeBps,
        uint256 createdAt,
        uint256 maturityDate
    ) internal view returns (uint256 amountIn) {
        uint256 effectiveQuote = getEffectiveVirtualQuoteReserve(
            virtualQuoteReserve,
            ptReserve,
            createdAt,
            maturityDate
        );

        return getAmountIn(amountOut, effectiveQuote, ptReserve, feeBps);
    }

    /**
     * @notice Calculate required PT input for desired Quote output (with time drift)
     * @dev ExactOutput version of getAmountOutPtToQuote
     *
     * @param amountOut             Desired quote amount to receive
     * @param ptReserve             Current PT reserve (18 decimals)
     * @param virtualQuoteReserve   Current virtual quote reserve (18 decimals)
     * @param feeBps                Swap fee in basis points
     * @param createdAt             Market creation timestamp
     * @param maturityDate          Cycle maturity timestamp
     * @return amountIn             PT tokens required (including fee)
     */
    function getAmountInPtToQuote(
        uint256 amountOut,
        uint256 ptReserve,
        uint256 virtualQuoteReserve,
        uint256 feeBps,
        uint256 createdAt,
        uint256 maturityDate
    ) internal view returns (uint256 amountIn) {
        uint256 effectivePt = getEffectivePtReserve(
            ptReserve,
            virtualQuoteReserve,
            createdAt,
            maturityDate
        );

        return getAmountIn(amountOut, effectivePt, virtualQuoteReserve, feeBps);
    }

    // ============================================================
    //                    LP CALCULATIONS
    // ============================================================
    /**
     * @notice Calculate LP tokens for initial liquidity deposit
     * @dev First depositor sets the price via discount
     *
     * INITIAL LP TOKEN MINTING:
     * LP tokens = sqrt(ptAmount * virtualQuote)
     *
     * This uses the geometric mean to ensure LP tokens are proportional
     * to both reserves, making the pool resistant to manipulation.
     *
     * NOTE: All values are in 18 decimals internally.
     * External quote token amounts are scaled at the swap boundary.
     *
     * @param ptAmount Amount of PT being deposited (18 decimals)
     * @param discountBps PT discount in basis points (e.g., 500 = 5%)
     * @return lpTokens LP tokens to mint
     * @return virtualQuote Virtual quote reserve to initialize (18 decimals)
     */
    function calculateInitialLpTokens(
        uint256 ptAmount,
        uint256 discountBps
    ) internal pure returns (uint256 lpTokens, uint256 virtualQuote) {
        if (ptAmount == 0) revert ZeroAmount();
        if (discountBps >= BPS_DENOMINATOR) revert InvalidDiscount(discountBps);

        // Calculate virtual quote: PT value at discount (18 decimals)
        // virtualQuote = ptAmount * (10000 - discountBps) / 10000
        virtualQuote =
            (ptAmount * (BPS_DENOMINATOR - discountBps)) /
            BPS_DENOMINATOR;

        // LP tokens = sqrt(ptAmount * virtualQuote)
        lpTokens = sqrt(ptAmount * virtualQuote);

        if (lpTokens == 0) revert InsufficientLiquidity();
    }

    /**
     * @notice Calculate LP tokens for subsequent deposits
     * @dev Deposits must maintain current price ratio
     *
     * SUBSEQUENT LP TOKEN MINTING:
     * LP tokens = min(
     *   ptAmount * totalLpShares / ptReserve,
     *   impliedQuote * totalLpShares / virtualQuoteReserve
     * )
     *
     * For single-sided PT deposits, we use:
     * lpTokens = ptAmount * totalLpShares / ptReserve
     *
     * @param ptAmount Amount of PT being deposited
     * @param ptReserve Current PT reserve
     * @param totalLpShares Current total LP shares
     * @return lpTokens LP tokens to mint
     */
    function calculateSubsequentLpTokens(
        uint256 ptAmount,
        uint256 ptReserve,
        uint256 totalLpShares
    ) internal pure returns (uint256 lpTokens) {
        if (ptAmount == 0) revert ZeroAmount();
        if (ptReserve == 0 || totalLpShares == 0)
            revert InsufficientLiquidity();

        // LP tokens proportional to PT contribution
        lpTokens = (ptAmount * totalLpShares) / ptReserve;
    }

    /**
     * @notice Calculate PT amount when removing liquidity
     * @dev Returns proportional PT + accumulated fees
     *
     * @param lpTokens LP tokens being burned
     * @param ptReserve Current PT reserve
     * @param totalLpShares Current total LP shares
     * @return ptAmount PT tokens to return
     */
    function calculateWithdrawAmount(
        uint256 lpTokens,
        uint256 ptReserve,
        uint256 totalLpShares
    ) internal pure returns (uint256 ptAmount) {
        if (lpTokens == 0) revert ZeroAmount();
        if (totalLpShares == 0) revert InsufficientLiquidity();

        // PT proportional to LP share
        ptAmount = (lpTokens * ptReserve) / totalLpShares;
    }

    /**
     * @notice Calculate implied PT price from market state
     * @dev Price = virtualQuoteReserve / ptReserve
     *
     * PRICE INTERPRETATION:
     * - price = 0.95 means PT trades at 5% discount
     * - price = 1.00 means PT trades at par (at maturity)
     *
     * @param ptReserve Current PT reserve
     * @param virtualQuoteReserve Current virtual quote reserve
     * @return priceBps Price in basis points (10000 = 1.00)
     */
    function getPtPriceBps(
        uint256 ptReserve,
        uint256 virtualQuoteReserve
    ) internal pure returns (uint256 priceBps) {
        if (ptReserve == 0) return BPS_DENOMINATOR; // Par if no liquidity

        priceBps = (virtualQuoteReserve * BPS_DENOMINATOR) / ptReserve;
    }

    /**
     * @notice Calculate implied discount from PT price
     * @dev Discount = 10000 - priceBps
     *
     * @param ptReserve Current PT reserve
     * @param virtualQuoteReserve Current virtual quote reserve
     * @return discountBps Discount in basis points
     */
    function getDiscountBps(
        uint256 ptReserve,
        uint256 virtualQuoteReserve
    ) internal pure returns (uint256 discountBps) {
        uint256 priceBps = getPtPriceBps(ptReserve, virtualQuoteReserve);

        if (priceBps >= BPS_DENOMINATOR) return 0; // No discount or premium

        discountBps = BPS_DENOMINATOR - priceBps;
    }

    /**
     * @notice Get PT price in bps with time decay applied
     * @dev This is the main view function for displaying current PT price in UI.
     *
     * The effective price accounts for time-based convergence to parity.
     * As maturity approaches, the effective price moves toward 10000 bps (100% = $1).
     *
     * FORMULA:
     * effectivePrice = effectiveQuoteReserve / ptReserve * 10000
     *
     * Example (10% initial discount, 50% time elapsed):
     *   virtualQuote = 900, ptReserve = 1000
     *   effectiveQuote = 925 (after quadratic decay at 50%)
     *   effectivePrice = 925 / 1000 * 10000 = 9250 bps (92.5%)
     *
     * @param ptReserve             Current PT reserve (18 decimals)
     * @param virtualQuoteReserve   Current virtual quote reserve (18 decimals)
     * @param createdAt             Market creation timestamp
     * @param maturityDate          Cycle maturity timestamp
     * @return priceBps             PT price in basis points (10000 = $1 parity)
     */
    function getEffectivePtPriceBps(
        uint256 ptReserve,
        uint256 virtualQuoteReserve,
        uint256 createdAt,
        uint256 maturityDate
    ) internal view returns (uint256 priceBps) {
        if (ptReserve == 0) return 0;

        // Get time-adjusted quote reserve
        uint256 effectiveQuote = getEffectiveVirtualQuoteReserve(
            virtualQuoteReserve,
            ptReserve,
            createdAt,
            maturityDate
        );

        // Calculate price: effectiveQuote / ptReserve * BPS_DENOMINATOR
        priceBps = (effectiveQuote * BPS_DENOMINATOR) / ptReserve;
    }

    /**
     * @notice Get effective discount after time decay
     * @dev Returns 0 at maturity (no discount, PT = parity)
     *
     * @param ptReserve             Current PT reserve
     * @param virtualQuoteReserve   Current virtual quote reserve
     * @param createdAt             Market creation timestamp
     * @param maturityDate          Cycle maturity timestamp
     * @return discountBps          Effective discount in basis points
     */
    function getEffectiveDiscountBps(
        uint256 ptReserve,
        uint256 virtualQuoteReserve,
        uint256 createdAt,
        uint256 maturityDate
    ) internal view returns (uint256 discountBps) {
        uint256 priceBps = getEffectivePtPriceBps(
            ptReserve,
            virtualQuoteReserve,
            createdAt,
            maturityDate
        );

        if (priceBps >= BPS_DENOMINATOR) return 0;

        discountBps = BPS_DENOMINATOR - priceBps;
    }

    // ============================================================
    //                    HELPER FUNCTIONS
    // ============================================================

    /**
     * @notice Calculate integer square root using Babylonian method
     * @dev Optimized for gas efficiency with early termination
     *
     * BABYLONIAN METHOD:
     * 1. Start with guess = x/2
     * 2. Iterate: guess = (guess + x/guess) / 2
     * 3. Stop when guess stops changing
     *
     * @param x Value to take square root of
     * @return y Integer square root (floor)
     */
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;

        // Start with a reasonable guess
        y = x;
        uint256 z = (x + 1) / 2;

        // Iterate until convergence
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
