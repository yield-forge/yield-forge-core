# YieldForge Market (Internal AMM)

YieldForge Market is a built-in constant product AMM enabling PT trading before maturity.

## Overview

```
┌─────────────────────────────────────────────────────────┐
│                  YieldForge Market                       │
├─────────────────────────────────────────────────────────┤
│                                                         │
│    PT Reserve ◄─────────────► Virtual Quote Reserve    │
│                                                         │
│    x * y = k (Constant Product)                        │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### Key Properties

| Property | Description |
|----------|-------------|
| **Quote Token** | Selected from pool's tokens (whitelist priority) |
| **Virtual Quote** | Not actual deposits - computed from PT value |
| **Single-Sided LP** | LPs deposit only PT |
| **Auto-Create** | Market created when cycle starts |

---

## Market Status Lifecycle

```
┌──────────┐     First LP      ┌──────────┐     Maturity     ┌──────────┐
│ PENDING  │ ────────────────► │  ACTIVE  │ ───────────────► │ EXPIRED  │
└──────────┘                   └──────────┘                   └──────────┘
                                     │
                                     │ Guardian action
                                     ▼
                               ┌──────────┐
                               │  BANNED  │
                               └──────────┘
```

### Status Definitions

| Status | Description |
|--------|-------------|
| **PENDING** | Market created, awaiting first LP to set price |
| **ACTIVE** | Trading enabled, LPs can add/remove liquidity |
| **EXPIRED** | Maturity reached, PT should be redeemed directly |
| **BANNED** | Emergency disabled by guardian |

---

## Core Concepts

### Virtual Quote Reserve

LPs deposit only PT. The "virtual quote reserve" is calculated from PT value at discount:

```solidity
virtualQuote = ptAmount * (BPS_DENOMINATOR - discountBps) / BPS_DENOMINATOR
```

**NOTE:** All internal AMM values (ptReserve, virtualQuoteReserve) are stored in 18 decimals.
External quote token amounts are scaled at swap boundaries using `quoteDecimals`.

**Example:**
- LP deposits 1000 PT at 5% discount (500 bps)
- virtualQuote = 1000e18 * (10000 - 500) / 10000 = 950e18

### Discount

Discount represents how much PT trades below face value:

```
Face Value (at maturity) = 1.0
Discount 5% → PT Price = 0.95

Discount = 10000 - priceBps
```

---

## Adding Liquidity

### First LP or Re-Activation (Sets Price)

When the market has no liquidity (PENDING status or all LPs withdrew), the first LP sets the price:

```solidity
function addYieldForgeLiquidity(
    bytes32 poolId,
    uint256 ptAmount,
    uint256 initialDiscountBps  // Required: 1-9900 (0.01% to 99%)
) external returns (uint256 lpTokens);
```

**Flow:**
1. Calculate virtual quote from discount
2. LP tokens = sqrt(ptAmount * virtualQuote)
3. Market transitions to ACTIVE status

**Example:**
```solidity
// First LP deposits 1000 PT at 5% discount
addYieldForgeLiquidity(poolId, 1000e18, 500);
// virtualQuote = 950e18
// lpTokens = sqrt(1000e18 * 950e18) ≈ 974.68e18
```

### Re-Activation After Full Withdrawal

If all LPs withdraw their liquidity, the market can be re-activated:

**Conditions detected:**
- Status is ACTIVE but `totalLpShares = 0`
- Next LP must provide `initialDiscountBps` (1-9900) to set new price

**State reset during re-activation:**
- `realQuoteReserve`, `accumulatedFeesPT`, `accumulatedFeesQuote` are reset to 0
- These values should already be 0 after complete withdrawal (each LP receives their proportional share)
- Explicit reset is a safety measure against potential rounding dust

**Price implications:**
- New LP sets price via discount, which may differ from previous price
- This creates a price gap on charts (normal market behavior in DeFi)
- Existing PT holders are not affected for redemption at maturity

### Subsequent LPs (Uses Current Price)

```solidity
addYieldForgeLiquidity(poolId, 500e18, 0);  // discountBps ignored
```

**Flow:**
1. Calculate LP tokens proportional to existing reserves
2. LP tokens = ptAmount * totalLpShares / ptReserve

---

## Removing Liquidity

```solidity
function removeYieldForgeLiquidity(
    bytes32 poolId,
    uint256 lpTokens
) external returns (uint256 ptAmount, uint256 quoteAmount);
```

**Flow:**
1. Calculate proportional PT share from `ptReserve`
2. Calculate proportional quote share from `realQuoteReserve`
3. Add proportional share of accumulated fees (both PT and quote)
4. Burn LP tokens
5. Return PT and quote to user

```solidity
ptAmount = (lpTokens * ptReserve / totalLpShares) + ptFeeShare
quoteAmount = (lpTokens * realQuoteReserve / totalLpShares) + quoteFeeShare
```

**Note:** `realQuoteReserve` accumulates from buy swaps (Quote → PT). If no buy swaps have occurred, `quoteAmount` will be 0.

---

## Trading

### Buy PT with Quote Token

```solidity
function swapQuoteForPT(
    bytes32 poolId,
    uint256 quoteAmount,
    uint256 minPTOut
) external returns (uint256 ptOut);
```

**Flow:**
1. Calculate dynamic fee
2. Apply constant product formula
3. Transfer quote from user
4. Transfer PT to user

### Sell PT for Quote Token

```solidity
function swapPTForQuote(
    bytes32 poolId,
    uint256 ptAmount,
    uint256 minQuoteOut
) external returns (uint256 quoteOut);
```

---

## Fee Structure

### Dynamic Fees (Time-Based)

Fees scale with time-to-maturity to compensate LPs for risk:

```solidity
MIN_FEE_BPS = 10;   // 0.1%
MAX_FEE_BPS = 50;   // 0.5%

// Interpolate based on time remaining
feeBps = MIN_FEE_BPS + (MAX_FEE_BPS - MIN_FEE_BPS) * (365 days - timeToMaturity) / 365 days;
```

| Time to Maturity | Fee |
|------------------|-----|
| > 1 year | 0.10% |
| 6 months | ~0.30% |
| 1 month | ~0.47% |
| Matured | 0.50% |

### Fee Distribution

| Recipient | Share |
|-----------|-------|
| LPs | 80% |
| Protocol | 20% |

Fee accumulation stored in market struct:
```solidity
struct YieldForgeMarketInfo {
    uint256 accumulatedFeesPT;
    uint256 accumulatedFeesQuote;
}
```

---

## AMM Math

### Constant Product Formula

```solidity
// After swap: (reserveIn + amountIn) * (reserveOut - amountOut) = k

function getAmountOut(
    uint256 amountIn,
    uint256 reserveIn,
    uint256 reserveOut,
    uint256 feeBps
) internal pure returns (uint256 amountOut, uint256 feeAmount) {
    // Calculate fee
    feeAmount = (amountIn * feeBps) / BPS_DENOMINATOR;
    uint256 amountInAfterFee = amountIn - feeAmount;
    
    // Constant product
    uint256 numerator = amountInAfterFee * reserveOut;
    uint256 denominator = reserveIn + amountInAfterFee;
    amountOut = numerator / denominator;
}
```

### Time-Aware Price Convergence

The AMM automatically adjusts prices to converge toward parity (1:1) as maturity approaches. This mimics real-world bond pricing behavior.

**Why Time-Aware Pricing?**
- Early in cycle: PT trades at discount (e.g., 95%)
- Near maturity: PT should trade at ~100% (parity)
- At maturity: PT = underlying value

**Quadratic Time Decay:**

```solidity
// factor = (elapsed / duration)²
// Quadratic provides slower drift early, faster near maturity

function getTimeDecayFactor(
    uint256 createdAt,
    uint256 maturityDate
) internal view returns (uint256 factor) {
    uint256 elapsed = block.timestamp - createdAt;
    uint256 duration = maturityDate - createdAt;
    
    // ratio = elapsed / duration (scaled by 1e18)
    uint256 ratio = (elapsed * 1e18) / duration;
    
    // factor = ratio² / 1e18
    factor = (ratio * ratio) / 1e18;
}
```

**Example (90-day cycle, 10% initial discount):**

| Day | Elapsed % | Decay Factor | Effective Price |
|-----|-----------|--------------|-----------------|
| 0   | 0%        | 0%           | 90% (original)  |
| 45  | 50%       | 25%          | 92.5%           |
| 67  | 75%       | 56%          | 95.6%           |
| 90  | 100%      | 100%         | 100% (parity)   |

**Effective Reserve Calculation:**

```solidity
// For Quote→PT swaps: increase effective quote reserve
effectiveQuote = virtualQuote + (ptReserve - virtualQuote) × decayFactor

// For PT→Quote swaps: decrease effective PT reserve
effectivePt = ptReserve - (ptReserve - virtualQuote) × decayFactor
```

### Initial LP Token Calculation

```solidity
lpTokens = sqrt(ptAmount * virtualQuoteReserve)
```

### Subsequent LP Token Calculation

```solidity
lpTokens = ptAmount * totalLpShares / ptReserve
```

---

## Library: LibYieldForgeMarket

**File:** `src/libraries/LibYieldForgeMarket.sol`

### Core AMM Functions

| Function | Purpose |
|----------|---------|
| `getSwapFeeBps()` | Calculate dynamic fee based on time |
| `getAmountOut()` | Calculate output for given input (swap) |
| `getAmountIn()` | Calculate required input for desired output |
| `calculateInitialLpTokens()` | First LP token calculation |
| `calculateSubsequentLpTokens()` | Additional LP token calculation |
| `calculateWithdrawAmount()` | PT returned for LP token burn |
| `getPtPriceBps()` | Current PT price in basis points |
| `getDiscountBps()` | Current discount from face value |

### Time-Aware Functions (NEW)

| Function | Purpose |
|----------|---------|
| `getTimeDecayFactor()` | Quadratic decay factor (0→1e18) |
| `getEffectiveVirtualQuoteReserve()` | Quote reserve with time drift |
| `getEffectivePtReserve()` | PT reserve with time drift |
| `getAmountOutQuoteToPt()` | Time-aware Quote→PT swap |
| `getAmountOutPtToQuote()` | Time-aware PT→Quote swap |
| `getAmountInQuoteToPt()` | Time-aware exact output Quote→PT |
| `getAmountInPtToQuote()` | Time-aware exact output PT→Quote |
| `getEffectivePtPriceBps()` | Effective price with decay |
| `getEffectiveDiscountBps()` | Effective discount with decay |


---

## Decimal Handling

The AMM uses a **"Normalize on Entry, Denormalize on Exit"** pattern for handling different quote token decimals (e.g., USDT with 6 decimals vs WETH with 18 decimals).

### Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                      EXTERNAL WORLD                          │
│              (tokens in native decimals)                     │
└──────────────────────────────────────────────────────────────┘
                    │                      ▲
                    │ _scaleUp()           │ _scaleDown()
                    ▼                      │
┌──────────────────────────────────────────────────────────────┐
│                   INTERNAL AMM DOMAIN                        │
│        (all values normalized to 18 decimals)               │
│                                                              │
│   ptReserve (18)  ◄──────────────►  virtualQuoteReserve (18)│
│                                                              │
│                    x * y = k                                 │
│            (K is consistent for any quote token)            │
└──────────────────────────────────────────────────────────────┘
```

### Key Points

| Aspect | Details |
|--------|---------|
| **Internal Storage** | All reserves stored in 18 decimals |
| **Quote Token Decimals** | Cached in `PoolInfo.quoteDecimals` for gas efficiency |
| **Scaling Location** | Only in swap functions (`swapExactQuoteForPT`, `swapExactPTForQuote`) |
| **Events** | Emit native decimal values for correct UI display |
| **Price Calculation** | Direct division (both reserves are 18 decimals) |

### Scaling Functions

```solidity
// Scale UP: native → 18 decimals (used at entry)
function _scaleUp(uint256 amount, uint8 decimals) private pure returns (uint256) {
    if (decimals >= 18) return amount;
    return amount * (10 ** (18 - decimals));
}

// Scale DOWN: 18 → native decimals (used at exit)
function _scaleDown(uint256 amount, uint8 decimals) private pure returns (uint256) {
    if (decimals >= 18) return amount;
    return amount / (10 ** (18 - decimals));
}
```

### Example: Swap 100 USDT for PT

```solidity
// 1. User sends 100 USDT (100e6 in native decimals)
quoteAmountIn = 100e6;

// 2. Scale up to 18 decimals for AMM calculation
quoteIn18 = _scaleUp(100e6, 6);  // = 100e18

// 3. AMM calculates output (all 18 decimals)
(ptOut, fee18) = getAmountOut(quoteIn18, virtualQuoteReserve, ptReserve, feeBps);

// 4. Update reserves (18 decimals)
virtualQuoteReserve += (quoteIn18 - fee18);

// 5. Transfer PT to user (already 18 decimals, matches PT token)
IERC20(ptToken).transfer(user, ptOut);

// 6. Event emits native quoteAmountIn for correct display
emit YieldForgeSwap(..., quoteAmountIn, ...);  // 100e6
```

## Quote Token Selection

During pool registration, quote token is auto-selected:

```solidity
// Priority: First approved token found in pool
if (approvedQuoteTokens[token0]) {
    quoteToken = token0;
} else if (approvedQuoteTokens[token1]) {
    quoteToken = token1;
} else {
    revert NoApprovedQuoteToken();
}
```

**Recommended Whitelist:**
- USDC (most stable, preferred)
- USDT
- DAI
- WETH

---

## View Functions

```solidity
// Get market info
function getYieldForgeMarketInfo(bytes32 poolId)
    external view returns (YieldForgeMarketInfo memory);

// Get LP balance
function getYieldForgeLpBalance(bytes32 poolId, address user)
    external view returns (uint256);

// Get user's withdrawable position value
function getLpPositionValue(bytes32 poolId, address user)
    external view returns (
        uint256 lpBalance,      // LP token balance
        uint256 ptAmount,       // PT tokens withdrawable (incl. fees)
        uint256 quoteAmount     // Quote tokens withdrawable (incl. fees)
    );

// Preview swap output
function previewSwapQuoteForPT(bytes32 poolId, uint256 quoteAmount)
    external view returns (uint256 ptOut);

function previewSwapPTForQuote(bytes32 poolId, uint256 ptAmount)
    external view returns (uint256 quoteOut);

// Get current pricing
function getPTPrice(bytes32 poolId)
    external view returns (uint256 priceBps);

function getPTDiscount(bytes32 poolId)
    external view returns (uint256 discountBps);
```

---

## Usage Examples

### Buy PT at Discount

```solidity
// Approve quote token
IERC20(usdc).approve(diamond, 1000e6);

// Buy PT with 1000 USDC, expect at least 1040 PT (4% discount)
uint256 ptReceived = yieldForgeMarket.swapQuoteForPT(
    poolId,
    1000e6,   // quoteAmount
    1040e18   // minPTOut
);
```

### Provide Liquidity as First LP

```solidity
// Approve PT
IERC20(ptToken).approve(diamond, 10000e18);

// Add liquidity at 5% discount
uint256 lpTokens = yieldForgeMarket.addYieldForgeLiquidity(
    poolId,
    10000e18,  // ptAmount
    500        // 5% discount (500 bps)
);
```

### Arbitrage at Maturity

When PT matures, it's redeemable 1:1 for underlying. If discount exists:
1. Buy discounted PT on market
2. Redeem PT for full value
3. Profit = discount - fees
