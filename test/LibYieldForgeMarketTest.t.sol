// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {LibYieldForgeMarket} from "../src/libraries/LibYieldForgeMarket.sol";

/**
 * @title LibYieldForgeMarketTest
 * @notice Tests for AMM math: constant product, fees, LP tokens, pricing
 */
contract LibYieldForgeMarketTest is Test {
    // Wrapper contract to test internal library functions
    LibYieldForgeMarketWrapper wrapper;

    function setUp() public {
        // Set a realistic timestamp to avoid underflows in time tests
        vm.warp(365 days);
        wrapper = new LibYieldForgeMarketWrapper();
    }

    // ================================================================
    //                    FEE CALCULATION TESTS
    // ================================================================

    function test_GetSwapFeeBps_ReturnsBaseFeeForLongMaturity() public {
        // 1+ year to maturity → 10 bps
        uint256 maturityDate = block.timestamp + 400 days;
        uint256 fee = wrapper.getSwapFeeBps(maturityDate);
        assertEq(fee, 10); // BASE_FEE_BPS
    }

    function test_GetSwapFeeBps_ReturnsMaxFeeAtMaturity() public {
        // Already matured → 50 bps
        uint256 maturityDate = block.timestamp - 1;
        uint256 fee = wrapper.getSwapFeeBps(maturityDate);
        assertEq(fee, 50); // MAX_FEE_BPS
    }

    function test_GetSwapFeeBps_LinearInterpolation() public {
        // Halfway (182.5 days) should be ~30 bps
        uint256 maturityDate = block.timestamp + 182 days;
        uint256 fee = wrapper.getSwapFeeBps(maturityDate);
        // Fee = 10 + (50-10) * (365-182)/365 ≈ 30
        assertGt(fee, 25);
        assertLt(fee, 35);
    }

    function test_SplitFee_80To20Split() public {
        uint256 totalFee = 1000;
        (uint256 lpFee, uint256 protocolFee) = wrapper.splitFee(totalFee);

        // 80% to LPs
        assertEq(lpFee, 800);
        // 20% to protocol
        assertEq(protocolFee, 200);
    }

    // ================================================================
    //                    AMM CALCULATION TESTS
    // ================================================================

    function test_GetAmountOut_ConstantProduct() public view {
        // Swap 100 into pool with reserves 1000/1000
        // amountOut = 1000 * 100 / (1000 + 100) ≈ 90.9 (minus fee)
        uint256 amountIn = 100e18;
        uint256 reserveIn = 1000e18;
        uint256 reserveOut = 1000e18;
        uint256 feeBps = 30; // 0.3%

        (uint256 amountOut, uint256 feeAmount) = wrapper.getAmountOut(amountIn, reserveIn, reserveOut, feeBps);

        // Fee = 100 * 30 / 10000 = 0.3
        assertEq(feeAmount, 3e17); // 0.3e18

        // amountOut should be significant
        assertGt(amountOut, 90e18);
        assertLt(amountOut, 100e18);
    }

    function test_GetAmountOut_RevertsOnZeroAmount() public {
        vm.expectRevert(LibYieldForgeMarket.ZeroAmount.selector);
        wrapper.getAmountOut(0, 1000e18, 1000e18, 30);
    }

    function test_GetAmountOut_RevertsOnZeroReserve() public {
        vm.expectRevert(LibYieldForgeMarket.InsufficientLiquidity.selector);
        wrapper.getAmountOut(100e18, 0, 1000e18, 30);
    }

    function test_GetAmountIn_ReturnsCorrectInput() public view {
        // Want to get 100 out of pool with reserves 1000/1000
        uint256 amountOut = 100e18;
        uint256 reserveIn = 1000e18;
        uint256 reserveOut = 1000e18;
        uint256 feeBps = 30;

        uint256 amountIn = wrapper.getAmountIn(amountOut, reserveIn, reserveOut, feeBps);

        // amountIn should be > amountOut due to price impact and fees
        assertGt(amountIn, 100e18);
        assertLt(amountIn, 150e18);
    }

    // ================================================================
    //                    LP CALCULATION TESTS
    // ================================================================

    function test_CalculateInitialLpTokens_UsesGeometricMean() public view {
        uint256 ptAmount = 1000e18;
        uint256 discountBps = 500; // 5% discount

        (uint256 lpTokens, uint256 virtualQuote) = wrapper.calculateInitialLpTokens(ptAmount, discountBps);

        // virtualQuote = 1000 * 0.95 = 950
        assertEq(virtualQuote, 950e18);

        // lpTokens = sqrt(1000 * 950) ≈ 974.68
        assertGt(lpTokens, 970e18);
        assertLt(lpTokens, 980e18);
    }

    function test_CalculateSubsequentLpTokens_Proportional() public view {
        uint256 ptAmount = 500e18;
        uint256 ptReserve = 1000e18;
        uint256 totalLpShares = 950e18;

        uint256 lpTokens = wrapper.calculateSubsequentLpTokens(ptAmount, ptReserve, totalLpShares);

        // 500/1000 * 950 = 475
        assertEq(lpTokens, 475e18);
    }

    function test_CalculateWithdrawAmount_ProportionalReturn() public view {
        uint256 lpTokens = 100e18;
        uint256 ptReserve = 1000e18;
        uint256 totalLpShares = 500e18;

        uint256 ptAmount = wrapper.calculateWithdrawAmount(lpTokens, ptReserve, totalLpShares);

        // 100/500 * 1000 = 200
        assertEq(ptAmount, 200e18);
    }

    // ================================================================
    //                    PRICE CALCULATION TESTS
    // ================================================================

    function test_GetPtPriceBps_Correct() public view {
        uint256 ptReserve = 1000e18;
        uint256 virtualQuoteReserve = 950e18; // 5% discount

        uint256 priceBps = wrapper.getPtPriceBps(ptReserve, virtualQuoteReserve);

        // price = 950/1000 = 0.95 = 9500 bps
        assertEq(priceBps, 9500);
    }

    function test_GetDiscountBps_Correct() public view {
        uint256 ptReserve = 1000e18;
        uint256 virtualQuoteReserve = 950e18;

        uint256 discountBps = wrapper.getDiscountBps(ptReserve, virtualQuoteReserve);

        // discount = 10000 - 9500 = 500 bps (5%)
        assertEq(discountBps, 500);
    }

    function test_GetDiscountBps_ZeroWhenAtPar() public view {
        uint256 ptReserve = 1000e18;
        uint256 virtualQuoteReserve = 1000e18; // At par

        uint256 discountBps = wrapper.getDiscountBps(ptReserve, virtualQuoteReserve);

        assertEq(discountBps, 0);
    }

    // ================================================================
    //                    SQRT TESTS
    // ================================================================

    function test_Sqrt_CorrectForPerfectSquares() public view {
        assertEq(wrapper.sqrt(100), 10);
        assertEq(wrapper.sqrt(10000), 100);
        assertEq(wrapper.sqrt(1e18), 1e9);
    }

    function test_Sqrt_FloorForNonPerfect() public view {
        // sqrt(99) = 9 (floor)
        assertEq(wrapper.sqrt(99), 9);
        // sqrt(101) = 10 (floor)
        assertEq(wrapper.sqrt(101), 10);
    }

    // ================================================================
    //                    TIME DECAY TESTS
    // ================================================================

    function test_GetTimeDecayFactor_ZeroAtCreation() public {
        // At creation, decay factor should be 0
        uint256 createdAt = block.timestamp;
        uint256 maturityDate = block.timestamp + 90 days;

        uint256 factor = wrapper.getTimeDecayFactor(createdAt, maturityDate);
        assertEq(factor, 0);
    }

    function test_GetTimeDecayFactor_FullAtMaturity() public {
        // Setup: market was created 90 days ago, maturity is now
        uint256 createdAt = block.timestamp - 90 days;
        uint256 maturityDate = block.timestamp;

        uint256 factor = wrapper.getTimeDecayFactor(createdAt, maturityDate);
        assertEq(factor, 1e18); // TIME_PRECISION
    }

    function test_GetTimeDecayFactor_QuadraticAt50Percent() public {
        // At 50% elapsed, quadratic decay = (0.5)² = 0.25
        uint256 createdAt = block.timestamp - 45 days;
        uint256 maturityDate = block.timestamp + 45 days;

        uint256 factor = wrapper.getTimeDecayFactor(createdAt, maturityDate);

        // Should be approximately 0.25e18 (25%)
        assertGt(factor, 0.24e18);
        assertLt(factor, 0.26e18);
    }

    function test_GetTimeDecayFactor_QuadraticAt75Percent() public {
        // At 75% elapsed, quadratic decay = (0.75)² = 0.5625
        uint256 createdAt = block.timestamp - 67 days;
        uint256 maturityDate = block.timestamp + 23 days; // ~75% elapsed

        uint256 factor = wrapper.getTimeDecayFactor(createdAt, maturityDate);

        // Should be approximately 0.56e18 (56%)
        assertGt(factor, 0.5e18);
        assertLt(factor, 0.62e18);
    }

    function test_GetEffectiveVirtualQuoteReserve_NoChangeAtCreation() public {
        uint256 virtualQuote = 900e18; // 10% discount
        uint256 ptReserve = 1000e18;
        uint256 createdAt = block.timestamp;
        uint256 maturityDate = block.timestamp + 90 days;

        uint256 effectiveQuote =
            wrapper.getEffectiveVirtualQuoteReserve(virtualQuote, ptReserve, createdAt, maturityDate);

        assertEq(effectiveQuote, virtualQuote); // No change at creation
    }

    function test_GetEffectiveVirtualQuoteReserve_ParityAtMaturity() public {
        uint256 virtualQuote = 900e18; // 10% discount
        uint256 ptReserve = 1000e18;
        uint256 createdAt = block.timestamp - 90 days;
        uint256 maturityDate = block.timestamp; // At maturity

        uint256 effectiveQuote =
            wrapper.getEffectiveVirtualQuoteReserve(virtualQuote, ptReserve, createdAt, maturityDate);

        // At maturity, effective quote should equal PT reserve (parity)
        assertEq(effectiveQuote, ptReserve);
    }

    function test_GetEffectiveVirtualQuoteReserve_PartialDrift() public {
        // 10% discount, 50% time elapsed → 25% drift (quadratic)
        uint256 virtualQuote = 900e18;
        uint256 ptReserve = 1000e18;
        uint256 createdAt = block.timestamp - 45 days;
        uint256 maturityDate = block.timestamp + 45 days;

        uint256 effectiveQuote =
            wrapper.getEffectiveVirtualQuoteReserve(virtualQuote, ptReserve, createdAt, maturityDate);

        // Gap = 100e18, decay = 0.25, drift = 25e18
        // Expected effective quote ≈ 925e18
        assertGt(effectiveQuote, 920e18);
        assertLt(effectiveQuote, 930e18);
    }

    function test_GetAmountOutQuoteToPt_TimeAware() public {
        // Test that time-aware swap gives different results than base swap
        uint256 amountIn = 100e18;
        uint256 virtualQuote = 900e18;
        uint256 ptReserve = 1000e18;
        uint256 feeBps = 30;

        // Set base time
        uint256 baseTime = block.timestamp;
        uint256 createdAt = baseTime;
        uint256 maturityDate = baseTime + 90 days;

        // At creation: should behave like normal AMM
        (uint256 ptOutCreation,) =
            wrapper.getAmountOutQuoteToPt(amountIn, virtualQuote, ptReserve, feeBps, createdAt, maturityDate);

        // At 50% elapsed: different price
        vm.warp(baseTime + 45 days);

        (uint256 ptOutMidway,) =
            wrapper.getAmountOutQuoteToPt(amountIn, virtualQuote, ptReserve, feeBps, createdAt, maturityDate);

        // At maturity: parity pricing
        vm.warp(maturityDate);

        (uint256 ptOutMaturity,) =
            wrapper.getAmountOutQuoteToPt(amountIn, virtualQuote, ptReserve, feeBps, createdAt, maturityDate);

        // As maturity approaches, PT is worth MORE so we get LESS per quote
        // At creation = maximum PT out, at maturity = minimum PT out
        assertGe(ptOutCreation, ptOutMidway);
        assertGe(ptOutMidway, ptOutMaturity);
        // Verify there IS a difference between creation and maturity
        assertGt(ptOutCreation, ptOutMaturity);
    }

    function test_GetEffectivePtPriceBps_ConvergesToParity() public {
        uint256 ptReserve = 1000e18;
        uint256 virtualQuote = 900e18; // 10% discount
        uint256 createdAt = block.timestamp;
        uint256 maturityDate = block.timestamp + 90 days;

        // At creation: 9000 bps (90%)
        uint256 priceAtCreation = wrapper.getEffectivePtPriceBps(ptReserve, virtualQuote, createdAt, maturityDate);
        assertEq(priceAtCreation, 9000);

        // At maturity: 10000 bps (100% = parity)
        vm.warp(maturityDate);
        uint256 priceAtMaturity = wrapper.getEffectivePtPriceBps(ptReserve, virtualQuote, createdAt, maturityDate);
        assertEq(priceAtMaturity, 10000);
    }

    function test_GetAmountOutPtToQuote_MoreQuoteNearMaturity() public {
        uint256 ptIn = 100e18;
        uint256 ptReserve = 1000e18;
        uint256 virtualQuote = 900e18;
        uint256 feeBps = 30;
        uint256 createdAt = block.timestamp;
        uint256 maturityDate = block.timestamp + 90 days;

        // At creation
        (uint256 quoteOutCreation,) =
            wrapper.getAmountOutPtToQuote(ptIn, ptReserve, virtualQuote, feeBps, createdAt, maturityDate);

        // At maturity
        vm.warp(maturityDate);
        (uint256 quoteOutMaturity,) =
            wrapper.getAmountOutPtToQuote(ptIn, ptReserve, virtualQuote, feeBps, createdAt, maturityDate);

        // Selling PT near maturity should give MORE quote
        assertGt(quoteOutMaturity, quoteOutCreation);
    }
}

// ================================================================
//                     WRAPPER CONTRACT
// ================================================================

/**
 * @notice Wrapper to expose internal library functions for testing
 */
contract LibYieldForgeMarketWrapper {
    function getSwapFeeBps(uint256 maturityDate) external view returns (uint256) {
        return LibYieldForgeMarket.getSwapFeeBps(maturityDate);
    }

    function splitFee(uint256 totalFee) external pure returns (uint256, uint256) {
        return LibYieldForgeMarket.splitFee(totalFee);
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint256 feeBps)
        external
        pure
        returns (uint256, uint256)
    {
        return LibYieldForgeMarket.getAmountOut(amountIn, reserveIn, reserveOut, feeBps);
    }

    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut, uint256 feeBps)
        external
        pure
        returns (uint256)
    {
        return LibYieldForgeMarket.getAmountIn(amountOut, reserveIn, reserveOut, feeBps);
    }

    function calculateInitialLpTokens(uint256 ptAmount, uint256 discountBps) external pure returns (uint256, uint256) {
        return LibYieldForgeMarket.calculateInitialLpTokens(ptAmount, discountBps);
    }

    function calculateSubsequentLpTokens(uint256 ptAmount, uint256 ptReserve, uint256 totalLpShares)
        external
        pure
        returns (uint256)
    {
        return LibYieldForgeMarket.calculateSubsequentLpTokens(ptAmount, ptReserve, totalLpShares);
    }

    function calculateWithdrawAmount(uint256 lpTokens, uint256 ptReserve, uint256 totalLpShares)
        external
        pure
        returns (uint256)
    {
        return LibYieldForgeMarket.calculateWithdrawAmount(lpTokens, ptReserve, totalLpShares);
    }

    function getPtPriceBps(uint256 ptReserve, uint256 virtualQuoteReserve) external pure returns (uint256) {
        return LibYieldForgeMarket.getPtPriceBps(ptReserve, virtualQuoteReserve);
    }

    function getDiscountBps(uint256 ptReserve, uint256 virtualQuoteReserve) external pure returns (uint256) {
        return LibYieldForgeMarket.getDiscountBps(ptReserve, virtualQuoteReserve);
    }

    function sqrt(uint256 x) external pure returns (uint256) {
        return LibYieldForgeMarket.sqrt(x);
    }

    // ================================================================
    //                TIME DECAY WRAPPER FUNCTIONS
    // ================================================================

    function getTimeDecayFactor(uint256 createdAt, uint256 maturityDate) external view returns (uint256) {
        return LibYieldForgeMarket.getTimeDecayFactor(createdAt, maturityDate);
    }

    function getEffectiveVirtualQuoteReserve(
        uint256 virtualQuoteReserve,
        uint256 ptReserve,
        uint256 createdAt,
        uint256 maturityDate
    ) external view returns (uint256) {
        return LibYieldForgeMarket.getEffectiveVirtualQuoteReserve(
            virtualQuoteReserve, ptReserve, createdAt, maturityDate
        );
    }

    function getEffectivePtReserve(
        uint256 ptReserve,
        uint256 virtualQuoteReserve,
        uint256 createdAt,
        uint256 maturityDate
    ) external view returns (uint256) {
        return LibYieldForgeMarket.getEffectivePtReserve(ptReserve, virtualQuoteReserve, createdAt, maturityDate);
    }

    function getAmountOutQuoteToPt(
        uint256 amountIn,
        uint256 virtualQuoteReserve,
        uint256 ptReserve,
        uint256 feeBps,
        uint256 createdAt,
        uint256 maturityDate
    ) external view returns (uint256, uint256) {
        return LibYieldForgeMarket.getAmountOutQuoteToPt(
            amountIn, virtualQuoteReserve, ptReserve, feeBps, createdAt, maturityDate
        );
    }

    function getAmountOutPtToQuote(
        uint256 amountIn,
        uint256 ptReserve,
        uint256 virtualQuoteReserve,
        uint256 feeBps,
        uint256 createdAt,
        uint256 maturityDate
    ) external view returns (uint256, uint256) {
        return LibYieldForgeMarket.getAmountOutPtToQuote(
            amountIn, ptReserve, virtualQuoteReserve, feeBps, createdAt, maturityDate
        );
    }

    function getEffectivePtPriceBps(
        uint256 ptReserve,
        uint256 virtualQuoteReserve,
        uint256 createdAt,
        uint256 maturityDate
    ) external view returns (uint256) {
        return LibYieldForgeMarket.getEffectivePtPriceBps(ptReserve, virtualQuoteReserve, createdAt, maturityDate);
    }
}
