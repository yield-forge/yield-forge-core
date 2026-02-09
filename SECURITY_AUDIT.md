# Yield Forge Protocol — Security Audit Report

> **Audit Type:** AI-Assisted Static Analysis  
> **Date:** February 8, 2026  
> **Auditor:** Claude (Anthropic) — Opus 4.6  
> **Commit:** `7286d03` (branch: `main`)  
> **Solidity Version:** 0.8.26  
> **Framework:** Foundry (forge)

---

## Disclaimer

**This audit was performed using AI-powered static analysis and manual code review. It is NOT a substitute for a professional security audit conducted by experienced human auditors.**

Specifically, this audit:

- Did **not** include formal verification or symbolic execution
- Did **not** include dynamic analysis, fuzzing, or invariant testing
- Did **not** include economic attack modeling or game-theoretic analysis
- Did **not** verify deployed bytecode against source code
- Was conducted on a **single point-in-time snapshot** of the codebase

**Users interact with this protocol entirely at their own risk.** The authors of this report make no guarantees about the completeness or accuracy of the findings. This report should be considered one input among many in a comprehensive security assessment. The protocol team is strongly encouraged to commission additional audits from established security firms before deploying with significant TVL.

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Scope](#2-scope)
3. [Findings Summary](#3-findings-summary)
4. [High Severity Findings](#4-high-severity-findings)
5. [Medium Severity Findings](#5-medium-severity-findings)
6. [Low Severity Findings](#6-low-severity-findings)
7. [Informational](#7-informational)
8. [Architecture Review](#8-architecture-review)
9. [Test Coverage Assessment](#9-test-coverage-assessment)
10. [Eliminated False Positives](#10-eliminated-false-positives)
11. [Conclusion](#11-conclusion)

---

## 1. Executive Summary

Yield Forge is a DeFi protocol that tokenizes yield from liquidity positions across Uniswap V4, Uniswap V3, and Curve. It separates LP positions into Principal Tokens (PT) and Yield Tokens (YT), enabling secondary market trading of both components. The protocol uses the Diamond Pattern (EIP-2535) for modular upgradeable architecture.

The codebase demonstrates solid engineering practices: consistent use of SafeERC20, reentrancy guards across all state-changing functions, the checks-effects-interactions pattern, comprehensive NatSpec documentation, and a 48-hour timelock for Diamond upgrades.

However, the audit identified **5 high-severity**, **7 medium-severity**, and **7 low-severity** issues, along with **6 informational notes**. The most critical findings involve an asymmetric pricing bug in the AMM, a denial-of-service vector in the YT orderbook, and inconsistent fee accounting in the market LP withdrawal flow.

| Severity      | Count  | Resolved |
| ------------- | ------ | -------- |
| High          | 5      | 4        |
| Medium        | 7      | 1        |
| Low           | 7      | 0        |
| Informational | 6      | 0        |
| **Total**     | **25** | **5**    |

---

## 2. Scope

### 2.1 Files Audited

All source files in `src/` were reviewed (30 files, ~448K total):

| Category           | Files                                                                                                                                                                                                                                          |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Core**           | `Diamond.sol`, `DiamondTimelock.sol`                                                                                                                                                                                                           |
| **Facets (10)**    | `DiamondCutFacet.sol`, `DiamondLoupeFacet.sol`, `OwnershipFacet.sol`, `PauseFacet.sol`, `PoolRegistryFacet.sol`, `LiquidityFacet.sol`, `RedemptionFacet.sol`, `YieldAccumulatorFacet.sol`, `YieldForgeMarketFacet.sol`, `YTOrderbookFacet.sol` |
| **Adapters (3)**   | `UniswapV4Adapter.sol`, `UniswapV3Adapter.sol`, `CurveAdapter.sol`                                                                                                                                                                             |
| **Libraries (7)**  | `LibAppStorage.sol`, `LibDiamond.sol`, `LibYieldForgeMarket.sol`, `LibPause.sol`, `LibReentrancyGuard.sol`, `ProtocolFees.sol`, `TokenNaming.sol`                                                                                              |
| **Tokens (3)**     | `TokenBase.sol`, `PrincipalToken.sol`, `YieldToken.sol`                                                                                                                                                                                        |
| **Interfaces (5)** | `ILiquidityAdapter.sol`, `IDiamondCut.sol`, `IDiamondLoupe.sol`, `IERC173.sol`, `IERC165.sol`                                                                                                                                                  |

### 2.2 Architecture Overview

```
                    User
                     │
                     ▼
              ┌─────────────┐
              │   Diamond    │  (EIP-2535 Proxy)
              │   Proxy      │
              └──────┬───────┘
                     │ delegatecall
       ┌─────────────┼─────────────┐
       ▼             ▼             ▼
  ┌─────────┐  ┌──────────┐  ┌──────────┐
  │Liquidity│  │  Yield   │  │ YieldForge│
  │  Facet  │  │Accumulator│  │  Market  │
  └────┬────┘  └──────────┘  └──────────┘
       │
       ▼
  ┌─────────┐
  │ Adapter │ ──► Uniswap V4 / V3 / Curve
  └─────────┘
```

**Key mechanisms:**

- Liquidity deposited via adapters → PT + YT minted to user
- PT redeemable at maturity for underlying tokens
- YT entitles holder to accumulated swap fees (yield)
- YieldForge Market: time-aware AMM for PT trading (single-sided LP)
- YT Orderbook: peer-to-peer orderbook for YT trading

---

## 3. Findings Summary

| ID   | Severity | Title                                                                      | Status           |
| ---- | -------- | -------------------------------------------------------------------------- | ---------------- |
| H-01 | HIGH     | `swapExactQuoteForPT` uses non-time-aware pricing; preview uses time-aware | **RESOLVED**     |
| H-02 | HIGH     | YT Orderbook unbounded array iteration with O(n²) sort                     | **RESOLVED**     |
| H-03 | HIGH     | `getLpPositionValue()` returns inflated values vs actual withdrawal        | **RESOLVED**     |
| H-04 | HIGH     | Sell orders don't escrow YT — griefing via post-placement transfer         | **ACKNOWLEDGED** |
| H-05 | HIGH     | `redeemPTWithZap()` lacks slippage protection                              | **RESOLVED**     |
| M-01 | MEDIUM   | `_scaleUp`/`_scaleDown` incorrect for tokens with >18 decimals             |
| M-02 | MEDIUM   | No minimum liquidity lock for first YieldForge Market LP                   |
| M-03 | MEDIUM   | `placeSellOrder` balance check is stale at fill time                       |
| M-04 | MEDIUM   | `ytOrdersByPool` array grows unbounded without cleanup                     | **RESOLVED**     |
| M-05 | MEDIUM   | Precision loss in yield distribution for dust amounts                      |
| M-06 | MEDIUM   | `upgradePT` mints same nominal amount regardless of value changes          |
| M-07 | MEDIUM   | `_calculateValueInQuote` overflow risk with extreme prices                 |
| L-01 | LOW      | `cancelOrder` allows post-maturity cancellation                            |
| L-02 | LOW      | No event on zero-yield harvest early return                                |
| L-03 | LOW      | `syncCheckpoint` doesn't check pause state                                 |
| L-04 | LOW      | V3 adapter `previewRemoveLiquidity` inaccurate for full-range positions    |
| L-05 | LOW      | DiamondTimelock proposal ID is non-reproducible                            |
| L-06 | LOW      | Protocol fee rates are immutable constants                                 |
| L-07 | LOW      | Storage gap reduced to 46 slots                                            |
| I-01 | INFO     | Centralization risks in admin functions                                    |
| I-02 | INFO     | `.env` contains default Anvil private key                                  |
| I-03 | INFO     | No ERC-2612 permit support on PT/YT                                        |
| I-04 | INFO     | Known ERC-20 approval race condition                                       |
| I-05 | INFO     | Adapter operations use `deadline: block.timestamp`                         |
| I-06 | INFO     | Multiple critical edge cases untested                                      |

---

## 4. High Severity Findings

### H-01: `swapExactQuoteForPT` Uses Non-Time-Aware Pricing — RESOLVED

**File:** `src/facets/YieldForgeMarketFacet.sol:462`

**Description:**

The `swapExactQuoteForPT()` function calculates swap output using `LibYieldForgeMarket.getAmountOut()`, which applies the constant product formula directly to the stored `virtualQuoteReserve` without time-decay adjustment:

```solidity
// Line 462 — swapExactQuoteForPT (ACTUAL SWAP)
(ptOut, feeAmount18) =
    LibYieldForgeMarket.getAmountOut(quoteIn18, market.virtualQuoteReserve, market.ptReserve, feeBps);
```

However, the **preview function** for the same swap uses time-aware pricing:

```solidity
// Line 683 — previewSwapQuoteForPT (PREVIEW)
(ptOut,) = LibYieldForgeMarket.getAmountOutQuoteToPt(
    quoteIn18, market.virtualQuoteReserve, market.ptReserve, feeBps, market.createdAt, cycle.maturityDate
);
```

And the **reverse swap** (`swapExactPTForQuote`) also uses time-aware pricing:

```solidity
// Line 563 — swapExactPTForQuote (ACTUAL SWAP)
(quoteOut18, feeAmount18) = LibYieldForgeMarket.getAmountOutPtToQuote(
    ptAmountIn, market.ptReserve, market.virtualQuoteReserve, feeBps, market.createdAt, cycle.maturityDate
);
```

**Impact:**

1. **Preview/execution mismatch:** Users see one output in the UI (via preview) but receive a different amount when executing the actual swap. As the cycle progresses, this discrepancy grows.
2. **Asymmetric pricing:** PT→Quote benefits from time-aware convergence (sellers get better rates near maturity), but Quote→PT does not. This creates a systematic arbitrage opportunity.
3. **Broken price convergence:** The core design goal — PT price converging to parity at maturity — only works in the PT→Quote direction. Quote→PT buyers continue to receive the initial discount pricing indefinitely.

**Recommendation:**

Replace line 462 with the time-aware function:

```solidity
(ptOut, feeAmount18) = LibYieldForgeMarket.getAmountOutQuoteToPt(
    quoteIn18, market.virtualQuoteReserve, market.ptReserve, feeBps,
    market.createdAt, cycle.maturityDate
);
```

**Resolution:** Fixed. Replaced `LibYieldForgeMarket.getAmountOut()` with `LibYieldForgeMarket.getAmountOutQuoteToPt()` in `swapExactQuoteForPT()`, passing `market.createdAt` and `cycle.maturityDate` parameters. The actual swap now uses the same time-aware pricing as the preview function and the reverse swap direction.

---

### H-02: YT Orderbook Unbounded Array Iteration with O(n²) Sort — RESOLVED

**File:** `src/facets/YTOrderbookFacet.sol:798-889`

**Description:**

The `_getSortedSellOrders()` and `_getSortedBuyOrders()` helper functions iterate through the **entire** `ytOrdersByPool[poolId]` array to find and sort active orders:

```solidity
function _getSortedSellOrders(bytes32 poolId, uint256 cycleId) internal view returns (uint256[] memory) {
    uint256[] storage orderIds = s.ytOrdersByPool[poolId];

    // First pass: count valid sell orders — O(n)
    for (uint256 i = 0; i < orderIds.length; i++) { ... }

    // Collect valid orders — O(n)
    for (uint256 i = 0; i < orderIds.length && idx < count; i++) { ... }

    // Bubble sort — O(n²)
    for (uint256 i = 0; i < result.length; i++) {
        for (uint256 j = i + 1; j < result.length; j++) { ... }
    }
}
```

These functions are called by `marketBuy()` and `marketSell()`, which are state-changing transactions subject to the block gas limit.

**Impact:**

- The `ytOrdersByPool` array is **append-only** — filled, cancelled, and expired orders are never removed (see M-04). The array will grow monotonically.
- With ~500 orders, the O(n²) sort approaches the gas limit (~30M gas on mainnet).
- Once the gas limit is exceeded, `marketBuy()` and `marketSell()` become permanently unusable for that pool.
- Limit orders (`fillSellOrder`/`fillBuyOrder`) still work, but the primary market order functionality is bricked.
- An attacker can intentionally accelerate this by placing many small orders.

**Recommendation:**

1. **Short term:** Add pagination parameters to `marketBuy`/`marketSell` (max orders to sweep).
2. **Medium term:** Maintain a sorted data structure (e.g., sorted linked list) rather than sorting on each call.
3. **Long term:** Implement order cleanup — remove filled/cancelled/expired order IDs from the array periodically.

**Resolution:** Fixed. Three changes applied: (1) Replaced O(n²) bubble sort with a single-pass insertion sort capped at `MAX_MARKET_ORDER_SWEEPS = 50` best orders, reducing complexity to O(n·k) where k=50. (2) Added a permissionless `cleanupOrders(poolId, maxIterations)` function that compacts the `ytOrdersByPool` array by removing filled, cancelled, and expired entries. (3) Extracted `_executeSellOrderFill()` and `_executeBuyOrderFill()` internal helpers to keep stack depth manageable.

---

### H-03: `getLpPositionValue()` Returns Inflated Values vs Actual Withdrawal — RESOLVED

**File:** `src/facets/YieldForgeMarketFacet.sol:771-800` vs `310-385`

**Description:**

The view function `getLpPositionValue()` and the actual withdrawal function `removeYieldForgeLiquidity()` calculate quote amounts differently:

**View function (getLpPositionValue):**

```solidity
// Line 631-635
quoteAmount = (lpBalance * market.realQuoteReserve) / totalShares;
uint256 quoteFeeShare = (lpBalance * market.accumulatedFeesQuote) / totalShares;
quoteAmount += _scaleDown(quoteFeeShare, pool.quoteDecimals);  // ADDS fee share
```

**Actual withdrawal (removeYieldForgeLiquidity):**

```solidity
// Line 352-358
quoteAmount = (lpShare * market.realQuoteReserve) / totalShares;

uint256 quoteFeeShare = (lpShare * market.accumulatedFeesQuote) / totalShares;

ptAmount += ptFeeShare;
// quoteAmount already includes fees via realQuoteReserve - no addition needed
```

The withdrawal function does NOT add `quoteFeeShare` to `quoteAmount` (the comment says fees are already in `realQuoteReserve`), but the view function DOES add them. This creates a discrepancy.

Additionally, the view function applies `_scaleDown` to `quoteFeeShare` (treating it as 18-decimal), but `accumulatedFeesQuote` is stored in 18 decimals while `realQuoteReserve` is in native decimals — mixing these creates an additional scaling error.

**Impact:**

- UI displays inflated withdrawal amounts compared to what users actually receive.
- Users may make economic decisions (e.g., whether to withdraw) based on incorrect data.
- The larger the accumulated fees, the larger the discrepancy.

**Recommendation:**

Align the view function with the actual withdrawal logic. If quote fees are truly included in `realQuoteReserve`, remove the `quoteFeeShare` addition from `getLpPositionValue()`.

**Resolution:** Fixed. Removed the `quoteFeeShare` addition from `getLpPositionValue()`. Quote LP fees are already included in `realQuoteReserve` (fees are added to reserves during swaps), so the view function was double-counting them. The view function now returns values consistent with actual `removeYieldForgeLiquidity()` payouts.

---

### H-04: Sell Orders Don't Escrow YT — Griefing via Post-Placement Transfer — ACKNOWLEDGED (BY DESIGN)

**File:** `src/facets/YTOrderbookFacet.sol:227-278`

**Description:**

When a user places a sell order via `placeSellOrder()`, the function checks the maker's YT balance but does **not** escrow (transfer) the YT tokens:

```solidity
// Line 253-256
uint256 makerBalance = IERC20(cycle.ytToken).balanceOf(msg.sender);
if (makerBalance < ytAmount) {
    revert InsufficientYTBalance(ytAmount, makerBalance);
}
// YT is NOT transferred — stays with maker
```

This is by design (so makers continue earning yield), but creates a vulnerability: after placing a sell order, the maker can freely transfer their YT to another address. When a taker attempts to fill via `fillSellOrder()`, the `safeTransferFrom` call will revert:

```solidity
// Line 507 — fillSellOrder
IERC20(cycle.ytToken).safeTransferFrom(order.maker, msg.sender, fillAmount);
// Reverts if maker no longer has sufficient YT or hasn't approved
```

**Impact:**

- **Griefing:** An attacker places many sell orders at attractive prices, then transfers YT away. Takers waste gas on every failed fill attempt.
- **Market manipulation:** Fake sell walls create the illusion of supply, suppressing perceived YT price.
- **Market order DoS:** `marketBuy()` iterates through orders — if many are unfillable, it burns gas iterating without executing and may revert with `InsufficientLiquidity`.

**Recommendation:**

Consider one of:

1. **Escrow YT** on order placement (sacrificing yield during escrow period).
2. **Allowance check** at placement: require `allowance(maker, diamond) >= ytAmount` and verify at fill time.
3. **Graceful skip** in `marketBuy()`: wrap `safeTransferFrom` in a try/catch and skip failed orders rather than reverting.
4. **Reputation system:** Track failed fills per maker and deprioritize their orders.

**Team Response:** Acknowledged as intentional design. YT is not escrowed so that the sell order maker continues to earn yield while the order is open. Escrowing YT would cause yield to be auto-claimed to the escrow contract (via `YieldToken._update()` calling `syncCheckpoint`), breaking the protocol's yield distribution logic. The griefing risk is accepted as a trade-off; UI-level mitigations (balance checks, order filtering) will be implemented separately.

---

### H-05: `redeemPTWithZap()` Lacks Slippage Protection — RESOLVED

**File:** `src/facets/RedemptionFacet.sol:157-257`

**Description:**

The standard `redeemPT()` function includes a `maxSlippageBps` parameter for slippage protection:

```solidity
function redeemPT(bytes32 poolId, uint256 cycleId, uint256 ptAmount, uint256 maxSlippageBps) external { ... }
```

However, `redeemPTWithZap()` has no such parameter:

```solidity
function redeemPTWithZap(bytes32 poolId, uint256 cycleId, uint256 ptAmount) external { ... }
```

The function calls `adapter.removeLiquidity()` and accepts whatever amounts are returned without any minimum checks. The underlying Uniswap/Curve operations use `amount0Min = 0` and `amount1Min = 0` at the adapter level.

**Impact:**

- Sandwich attacks can manipulate the pool price before the redemption transaction, extracting value from the redeemer.
- This is especially dangerous for large redemptions which move the pool significantly.
- On public mempools (without private transaction relays), this is readily exploitable by MEV bots.

**Recommendation:**

Add slippage protection parameters:

```solidity
function redeemPTWithZap(
    bytes32 poolId, uint256 cycleId, uint256 ptAmount,
    uint256 minQuoteAmount, uint256 minNonQuoteAmount
) external { ... }
```

**Resolution:** Fixed. Added a `maxSlippageBps` parameter to `redeemPTWithZap()`. The function now previews the expected output amounts via `adapter.previewRemoveLiquidity()`, calculates minimum acceptable amounts based on the slippage tolerance, and reverts with `SlippageExceeded` if the actual amounts received from `adapter.removeLiquidity()` fall below the minimums. This matches the slippage protection pattern already used in `redeemPT()`. Note: this is a breaking change to the function signature — UI updates required.

---

## 5. Medium Severity Findings

### M-01: `_scaleUp`/`_scaleDown` Incorrect for Tokens with >18 Decimals

**File:** `src/facets/YieldForgeMarketFacet.sol:130-145`

**Description:**

```solidity
function _scaleUp(uint256 amount, uint8 decimals) private pure returns (uint256) {
    if (decimals >= 18) return amount;  // Bug: returns unchanged for decimals > 18
    return amount * (10 ** (18 - decimals));
}
```

If a token has decimals > 18 (e.g., 24), the function returns the raw amount without scaling it down to 18 decimals. The same issue exists in `_scaleDown`.

**Impact:** Incorrect AMM pricing for tokens with >18 decimals. Currently no common token uses >18 decimals, and the approved quote token whitelist provides a layer of defense — but the code is still incorrect.

**Recommendation:**

```solidity
function _scaleUp(uint256 amount, uint8 decimals) private pure returns (uint256) {
    if (decimals == 18) return amount;
    if (decimals < 18) return amount * (10 ** (18 - decimals));
    return amount / (10 ** (decimals - 18));
}
```

---

### M-02: No Minimum Liquidity Lock for First YieldForge Market LP

**File:** `src/facets/YieldForgeMarketFacet.sol:196-230`

**Description:**

The first LP to `addYieldForgeLiquidity()` receives all LP tokens without any minimum locked amount. Unlike Uniswap V2 which burns `MINIMUM_LIQUIDITY` (1000 wei) to prevent price manipulation, this market sends all `lpTokens` to the first depositor.

**Impact:**

- First depositor can provide 1 wei of PT, setting an extreme price.
- Subsequent LPs are forced to match this price ratio.
- Donation attacks: first LP deposits minimal amount, then donates PT directly to inflate price.

**Recommendation:** Burn a small `MINIMUM_LIQUIDITY` amount on first deposit to establish a non-removable baseline.

---

### M-03: `placeSellOrder` Balance Check Is Stale at Fill Time

**File:** `src/facets/YTOrderbookFacet.sol:253-256`

**Description:**

The balance check at order placement (`balanceOf(msg.sender) >= ytAmount`) becomes stale immediately after the transaction confirms. The maker can spend or transfer their YT before the order is filled.

**Impact:** Related to H-04. Orders appear valid in the orderbook UI (`getActiveOrders`) but fail when takers attempt to fill them. This degrades user experience and wastes gas.

**Recommendation:** At minimum, add a re-check of balance + allowance in `_validateOrderForFill()` and mark unfillable orders as inactive.

---

### M-04: `ytOrdersByPool` Array Grows Unbounded Without Cleanup — RESOLVED

**File:** `src/libraries/LibAppStorage.sol:380`

**Description:**

The `ytOrdersByPool[poolId]` array is append-only. Every order placed for a pool adds to this array, but filled, cancelled, and expired orders are never removed.

**Impact:**

- All view functions that iterate this array (`getActiveOrders`, `getOrderbookSummary`) become increasingly expensive.
- Contributes to the gas escalation described in H-02.
- Over the lifetime of a popular pool, the array could contain thousands of dead entries.

**Recommendation:** Implement periodic cleanup (e.g., a permissionless `cleanupOrders()` function) or use a linked list with O(1) removal.

**Resolution:** Fixed as part of H-02. Added a permissionless `cleanupOrders(poolId, maxIterations)` function that compacts the `ytOrdersByPool` array by removing entries for inactive, fully filled, or expired orders. The function accepts a `maxIterations` parameter to bound gas usage per call, and can be called by anyone (e.g., keepers or bots).

---

### M-05: Precision Loss in Yield Distribution for Dust Amounts

**File:** `src/facets/YieldAccumulatorFacet.sol:159-161`

**Description:**

```solidity
yieldState.yieldPerShare0 += (userYield0 * PRECISION) / totalYTSupply;
```

When `userYield0 * PRECISION` (1e30) is less than `totalYTSupply`, the result truncates to zero. For example, if `userYield0 = 1 wei` and `totalYTSupply = 1e31`, the division yields 0 and the yield is permanently lost.

**Impact:** Pools with large YT supply and small per-harvest yield amounts will systematically lose yield dust. While individually small, this accumulates over many harvests.

**Recommendation:** Accumulate un-distributable yield in a buffer and include it in the next harvest that produces a non-zero per-share increment.

---

### M-06: `upgradePT` Mints Same Nominal Amount Regardless of Value Changes

**File:** `src/facets/RedemptionFacet.sol:326-355`

**Description:**

```solidity
PrincipalToken(newCycle.ptToken).mint(msg.sender, ptAmount);
YieldToken(newCycle.ytToken).mint(msg.sender, ptAmount);

newPtAmount = ptAmount;
newYtAmount = ptAmount;
```

The upgrade mints the exact same `ptAmount` in the new cycle. However, PT amounts are denominated in quote token value at the time of deposit. If the underlying pool price changed significantly between cycles, the same nominal PT amount may represent a different share of liquidity.

**Impact:** Users who upgrade may receive more or fewer tokens than they would by redeeming and re-depositing, creating an arbitrage opportunity at the expense of other cycle participants.

**Recommendation:** Calculate the actual underlying value of the old PT and mint new PT proportional to current value, or clearly document this as a known trade-off.

---

### M-07: `_calculateValueInQuote` Overflow Risk with Extreme Prices

**File:** `src/facets/LiquidityFacet.sol:313-321`

**Description:**

```solidity
uint256 intermediate = (amount0Used * sqrtPrice) / (1 << 96);
amount0InQuote = (intermediate * sqrtPrice) / (1 << 96);
```

When `amount0Used` is large (e.g., 1e27 for a high-decimal token) and `sqrtPrice` is near its maximum (~1.46e29 for extreme price ratios), the multiplication `amount0Used * sqrtPrice` can exceed `type(uint256).max`, causing a revert.

Similarly for the inverse calculation:

```solidity
uint256 intermediate = (amount1Used << 96) / sqrtPrice;
```

The left-shift `amount1Used << 96` overflows when `amount1Used > 2^160`.

**Impact:** Large deposits in pools with extreme price ratios will revert, preventing liquidity addition. This is a DoS condition for specific pool configurations.

**Recommendation:** Use a mulDiv library (e.g., OpenZeppelin's `Math.mulDiv`) for overflow-safe full-precision multiplication and division.

---

## 6. Low Severity Findings

### L-01: `cancelOrder` Allows Post-Maturity Cancellation

**File:** `src/facets/YTOrderbookFacet.sol:647-680`

The function does not check whether the cycle has matured before allowing cancellation. While not exploitable (escrow is rightfully returned), it may confuse users who expect orders to auto-expire at maturity.

---

### L-02: No Event on Zero-Yield Harvest

**File:** `src/facets/YieldAccumulatorFacet.sol:175-179`

When `harvestYield()` collects zero yield, it returns early without emitting any event. This makes it harder for off-chain monitoring systems to track harvest attempts and distinguish "no yield available" from "function not called."

---

### L-03: `syncCheckpoint` Doesn't Check Pause State

**File:** `src/facets/YieldAccumulatorFacet.sol:270-291`

The `syncCheckpoint()` function (called by YieldToken on every transfer) does not check `LibPause.requireNotPaused()`. This means YT transfers continue working even when the protocol is paused, which may be unintended.

---

### L-04: V3 Adapter Preview Inaccuracy

**File:** `src/adapters/UniswapV3Adapter.sol` (previewRemoveLiquidity)

The preview function estimates amounts using a proportional reserve calculation, which is inaccurate for full-range Uniswap V3 positions where the token ratio depends on the current tick position.

---

### L-05: DiamondTimelock Proposal ID Is Non-Reproducible

**File:** `src/DiamondTimelock.sol:112`

```solidity
proposalId = keccak256(abi.encode(_facetCuts, _init, _calldata, block.timestamp, msg.sender));
```

Including `block.timestamp` means the same proposal submitted at different times produces different IDs, making it impossible to verify proposal contents by re-computing the ID.

---

### L-06: Protocol Fee Rates Are Immutable Constants

**File:** `src/libraries/ProtocolFees.sol`

Fee rates (5% yield fee, 20% AMM fee share) are defined as constants. While this prevents governance attacks on fee parameters, it also requires a full contract redeployment to adjust fees in response to market conditions.

---

### L-07: Storage Gap Reduced to 46 Slots

**File:** `src/libraries/LibAppStorage.sol:383`

The `__gap` was reduced from 50 to 46 slots after adding YT orderbook fields. One more major feature addition could exhaust remaining slots, complicating future upgrades.

---

## 7. Informational

### I-01: Centralization Risks

The protocol owner has significant power:

- Approve/revoke adapters and quote tokens
- Register pools
- Set fee recipient and pool guardian
- Execute Diamond upgrades (with 48h timelock)
- Pause/unpause the entire protocol

**Mitigation present:** 48-hour timelock on Diamond upgrades gives users time to exit. Pool guardian can only ban (not steal funds). Banned pools still allow redemption and yield claims.

**Recommendation:** Consider transferring ownership to a multi-sig wallet or DAO governance for production deployment.

### I-02: Default Anvil Private Key in `.env`

The `.env` file contains the default Anvil/Hardhat private key (`0xac0974...`). While this is clearly for local development, the file is tracked by git. Ensure `.env` is in `.gitignore` for production deployments.

### I-03: No ERC-2612 Permit Support

PT and YT tokens do not support gasless approvals via `permit()`. Users must submit separate `approve()` transactions before interacting with the Diamond.

### I-04: Known ERC-20 Approval Race Condition

PT and YT inherit from OpenZeppelin's standard ERC-20, which has the known approval race condition. Integrators should use `increaseAllowance`/`decreaseAllowance` instead of `approve`.

### I-05: Adapter Deadline Set to `block.timestamp`

Uniswap V3 adapter operations use `deadline: block.timestamp`, which offers no MEV protection since the deadline is always met within the same block. Consider accepting a user-specified deadline parameter.

### I-06: Critical Edge Cases Untested

The test suite (13 files) covers core functionality but lacks coverage for:

- Zero YT supply during harvest (orphaned yield)
- Extreme sqrtPriceX96 values in `_calculateValueInQuote`
- Partial market order failures in YT orderbook
- YieldForge Market behavior at exact maturity timestamp
- Overflow scenarios in LP token calculations
- Orderbook gas consumption with large order counts

---

## 8. Architecture Review

### 8.1 Diamond Pattern (EIP-2535)

The Diamond implementation follows the reference implementation closely. Key observations:

- **Storage:** Single `AppStorage` struct accessed via a fixed storage slot. All facets share the same storage layout.
- **Upgrades:** Protected by `DiamondTimelock` with a 48-hour delay and 7-day grace period. This is industry-standard and gives users adequate exit time.
- **Function routing:** The `Diamond.sol` fallback function uses `selectorToFacetAndPosition` mapping for O(1) function dispatch.
- **Reentrancy:** A single `LibReentrancyGuard` is shared across all facets via Diamond Storage, correctly preventing cross-facet reentrancy.

**Assessment:** The Diamond implementation is sound. The storage layout is clean, the upgrade mechanism is well-protected, and the reentrancy guard correctly operates across facet boundaries.

### 8.2 Adapter Pattern

Adapters implement `ILiquidityAdapter` and are deployed as standalone contracts (not facets). This is a good design choice:

- Adapters can be independently upgraded without touching the Diamond
- Each adapter encapsulates protocol-specific complexity
- The adapter whitelist prevents unauthorized implementations

**Concern:** Adapters hold no state themselves — all state is in the Diamond. However, adapters execute external calls to Uniswap/Curve on behalf of the Diamond via `delegatecall` from facets calling adapter functions. Since adapters are called via normal `call` (not `delegatecall`), tokens must be transferred to/from the Diamond explicitly, which is correctly implemented.

### 8.3 Token Architecture

PT and YT are separate ERC-20 contracts deployed per cycle per pool. Each has an immutable reference to the Diamond for access control.

**Strength:** The YieldToken checkpoint system correctly prevents "yield sniping" (buying YT, claiming accumulated yield, selling YT).

**Concern:** YieldToken's `_update()` hook makes external calls to the Diamond (`syncCheckpoint`), but access control is properly enforced (only the specific YT token can call `syncCheckpoint` for its own pool/cycle).

---

## 9. Test Coverage Assessment

### 9.1 Test Files Present (13)

| Test File                         | Coverage Area                         |
| --------------------------------- | ------------------------------------- |
| `DiamondTest.t.sol`               | Diamond proxy and facet routing       |
| `DiamondTimelockTest.t.sol`       | Timelock proposal/execution           |
| `PoolRegistryFacetTest.t.sol`     | Pool registration and admin           |
| `LiquidityFacetTest.t.sol`        | Liquidity addition and cycle creation |
| `RedemptionFacetTest.t.sol`       | PT redemption flows                   |
| `YieldAccumulatorFacetTest.t.sol` | Yield harvest and claim               |
| `YieldForgeMarketFacetTest.t.sol` | AMM swaps and LP                      |
| `YTOrderbookFacetTest.t.sol`      | Orderbook operations                  |
| `LibYieldForgeMarketTest.t.sol`   | AMM math library                      |
| `AdapterTest.t.sol`               | Adapter integration                   |
| `TokenTest.t.sol`                 | PT/YT token operations                |
| `PauseFacetTest.t.sol`            | Pause mechanism                       |
| `IntegrationTest.t.sol`           | End-to-end flows                      |

### 9.2 Missing Test Coverage

The following scenarios lack dedicated test coverage:

- **Boundary conditions:** Maturity timestamp boundaries, zero-amount operations, empty cycles
- **Gas limits:** Orderbook performance with 100+ orders
- **Overflow:** Extreme `sqrtPriceX96` values, large deposit amounts
- **Time-dependent:** AMM behavior at exact maturity, time-decay at various points
- **Adversarial:** Sell order griefing (H-04), orderbook spam (H-02)
- **Precision:** Dust yield distribution, rounding in fee calculations
- **Cross-facet:** Interactions between YieldForge Market and Redemption flows

**Recommendation:** Add fuzz tests for mathematical functions and invariant tests for protocol-wide properties (e.g., "total PT supply always equals total claimable underlying").

---

## 10. Eliminated False Positives

During the audit, automated analysis flagged the following issues which were confirmed to be **not actual vulnerabilities** upon manual code review:

### FP-01: "Reentrancy Guard Double-Exit in `harvestYield()`"

**Claim:** Calling `_nonReentrantAfter()` on both the early return path (line 178) and the normal exit path (line 192) causes a double-exit bug.

**Reality:** These are on **mutually exclusive code paths**. The early return at line 178 exits the function — execution never reaches line 192 in that case. The reentrancy guard is correctly managed.

### FP-02: "PT Transfer Before Maturity Check in `addYieldForgeLiquidity()`"

**Claim:** The function transfers PT from the user before checking cycle maturity, causing tokens to be "stuck" if the check fails.

**Reality:** The maturity check (`if (block.timestamp >= cycle.maturityDate)`) is at line 196. The PT `safeTransferFrom` is at line 208. The check comes **before** the transfer. If it reverts, no transfer occurs. The entire transaction reverts atomically.

### FP-03: "YieldToken `_update()` Reentrancy Risk"

**Claim:** External calls from `_update()` to the Diamond create a reentrancy window.

**Reality:** The `syncCheckpoint()` function verifies `msg.sender == cycle.ytToken`, ensuring only the specific YT token can invoke it. Additionally, the Diamond's state-changing functions are protected by `LibReentrancyGuard`, which covers cross-facet reentrancy. The YT transfer itself occurs within the Diamond's reentrancy-locked context (during `mint()`), making reentrant exploitation infeasible.

---

## 11. Conclusion

### Overall Assessment

The Yield Forge codebase demonstrates strong engineering fundamentals:

- **Architecture:** The Diamond Pattern is cleanly implemented with proper storage management and a well-designed upgrade mechanism.
- **Security patterns:** Consistent use of SafeERC20, reentrancy guards, checks-effects-interactions, and access control.
- **Documentation:** Comprehensive NatSpec comments with examples and explanations of design decisions.
- **Modularity:** Clean separation between protocol-agnostic facets and protocol-specific adapters.

The audit identified **5 high-severity issues**. As of the latest revision, **4 have been resolved** and **1 acknowledged as intentional design**:

1. **H-01** (asymmetric AMM pricing) — **RESOLVED.** Swap now uses time-aware pricing.
2. **H-02** (orderbook DoS) — **RESOLVED.** Capped sort at 50 entries + added cleanup function.
3. **H-03** (view function inconsistency) — **RESOLVED.** Removed double-counted fee addition.
4. **H-04** (non-escrowed sell orders) — **ACKNOWLEDGED.** Intentional design to preserve yield claiming for sell order makers.
5. **H-05** (missing slippage protection) — **RESOLVED.** Added `maxSlippageBps` parameter with preview-based checks.

Additionally, **M-04** (unbounded array growth) was resolved as part of the H-02 fix.

### Severity Distribution

```
HIGH:          ████████████████████  5  (4 resolved, 1 acknowledged)
MEDIUM:        ████████████████████████████  7  (1 resolved)
LOW:           ████████████████████████████  7
INFORMATIONAL: ████████████████████████  6
```

### Recommendation

The remaining medium and low severity findings should be evaluated for remediation. The protocol team should:

1. **Before launch** address remaining medium-severity findings (M-01 through M-07, excluding resolved M-04)
2. **Before mainnet** commission at least one additional audit from an established security firm
3. **Ongoing** expand test coverage with fuzz and invariant tests

---

_This report was generated by Claude (Anthropic) as part of an AI-assisted security review. It should be used as supplementary analysis alongside professional human audits. The findings reflect the state of the code at the specified commit and may not apply to subsequent versions._
