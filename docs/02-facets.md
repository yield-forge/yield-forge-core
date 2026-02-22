# Facets Documentation

The Diamond uses modular facets to organize protocol logic. Each facet is a separate contract whose functions are accessible through the main Diamond address.

## Core Diamond Facets

### DiamondCutFacet

**File:** `src/facets/DiamondCutFacet.sol`

Handles Diamond upgrades by adding, replacing, or removing facet functions.

```solidity
function diamondCut(
    FacetCut[] calldata _diamondCut,
    address _init,
    bytes calldata _calldata
) external;
```

- **Access**: Owner only
- **Purpose**: Modify which facets handle which functions
- **Security**: Should be protected by DiamondTimelock in production

---

### DiamondLoupeFacet

**File:** `src/facets/DiamondLoupeFacet.sol`

Implements EIP-2535 introspection functions.

| Function                          | Description                            |
| --------------------------------- | -------------------------------------- |
| `facets()`                        | Returns all facets and their selectors |
| `facetFunctionSelectors(address)` | Returns selectors for a specific facet |
| `facetAddress(bytes4)`            | Returns facet implementing a selector  |
| `facetAddresses()`                | Returns all facet addresses            |

---

### OwnershipFacet

**File:** `src/facets/OwnershipFacet.sol`

Implements EIP-173 ownership standard.

| Function                     | Description                      |
| ---------------------------- | -------------------------------- |
| `owner()`                    | Returns current owner address    |
| `transferOwnership(address)` | Transfers ownership (owner only) |

---

### PauseFacet

**File:** `src/facets/PauseFacet.sol`

Emergency pause mechanism for the protocol.

| Function     | Access                | Description                    |
| ------------ | --------------------- | ------------------------------ |
| `pause()`    | Owner or PoolGuardian | Pauses all protocol operations |
| `unpause()`  | Owner only            | Resumes protocol operations    |
| `isPaused()` | Public                | Check pause status             |

---

## Protocol Facets

### PoolRegistryFacet

**File:** `src/facets/PoolRegistryFacet.sol`

Manages pool registration and protocol configuration.

#### Initialization

```solidity
function initialize(address feeRecipient_) external onlyOwner;
```

#### Adapter Management

```solidity
function approveAdapter(address adapter) external onlyOwner;
function revokeAdapter(address adapter) external onlyOwner;
function isAdapterApproved(address adapter) external view returns (bool);
```

#### Quote Token Management

```solidity
function approveQuoteToken(address token) external onlyOwner;
function revokeQuoteToken(address token) external onlyOwner;
```

#### Pool Registration

```solidity
function registerPool(
    address adapter,
    bytes calldata poolParams,
    address quoteToken  // Must be one of pool tokens and in approved whitelist
) external onlyOwner returns (bytes32 poolId);
```

**Pool ID Generation:**

```solidity
poolId = keccak256(abi.encode(adapter, keccak256(poolParams)))
```

**Registration Process:**
1. Validates adapter is approved
2. Fetches pool tokens via `adapter.getPoolTokens()`
3. Validates `quoteToken` is one of pool's tokens AND in approved whitelist
4. Caches `quoteDecimals` from `IERC20Metadata(quoteToken).decimals()` for gas efficiency
5. Stores pool info in `LibAppStorage`

#### Pool Guardian

```solidity
function setPoolGuardian(address guardian) external onlyOwner;
function banPool(bytes32 poolId) external onlyPoolGuardian;
function unbanPool(bytes32 poolId) external onlyOwner;
```

---

### LiquidityFacet

**File:** `src/facets/LiquidityFacet.sol`

Handles liquidity addition and cycle management.

#### Add Liquidity

```solidity
function addLiquidity(
    bytes32 poolId,
    uint256 amount0,
    uint256 amount1
) external returns (uint256 liquidity, uint256 ptAmount, uint256 ytAmount);
```

**Flow:**

1. Validate pool exists and is not banned
2. Create new cycle if none exists or current expired
3. Transfer tokens from user to Diamond
4. Add liquidity via adapter
5. Calculate total value in quote token (normalized to 18 decimals)
6. Mint PT/YT to user based on quote value
7. Return unused tokens

**PT/YT Amount Calculation:**

```solidity
// Get price from adapter
(uint160 sqrtPriceX96, ) = adapter.getPoolPrice(poolParams);

// Calculate total value in quote token terms
uint256 valueInQuote = _calculateValueInQuote(amount0Used, amount1Used, pool);

// Mint PT/YT based on quote value (18 decimals)
PrincipalToken(ptToken).mint(user, valueInQuote);
YieldToken(ytToken).mint(user, valueInQuote);
```

**Example:**

- User deposits 1 WBTC + 90,000 USDT
- WBTC price: 90,000 USDT
- Quote token: USDT
- Value: 90,000 + 90,000 = 180,000 USDT
- User receives: 180,000e18 PT + 180,000e18 YT

**Cycle Creation:**

- Automatically triggered on first `addLiquidity` or when current cycle matures
- 90-day maturity period
- Deploys new PT and YT token contracts per cycle

#### Preview Functions (View)

```solidity
// Preview expected PT/YT tokens before adding liquidity
// Returns value in quote token terms (18 decimals)
function previewAddLiquidity(
    bytes32 poolId,
    uint256 amount0,
    uint256 amount1
) external view returns (
    uint256 expectedPT,    // Value in quote token (18 decimals)
    uint256 expectedYT,    // Value in quote token (18 decimals)
    uint256 amount0Used,   // Actual token0 that will be used
    uint256 amount1Used    // Actual token1 that will be used
);

// Calculate optimal amount1 for given amount0 (auto-sync input fields)
function calculateOptimalAmount1(
    bytes32 poolId,
    uint256 amount0
) external view returns (uint256 amount1);

// Calculate optimal amount0 for given amount1 (auto-sync input fields)
function calculateOptimalAmount0(
    bytes32 poolId,
    uint256 amount1
) external view returns (uint256 amount0);
```

These view functions enable the UI to:

- Display accurate PT/YT preview (in quote value, 18 decimals) before transaction
- Auto-synchronize token input fields based on pool ratio

#### TVL Functions

```solidity
// Get YieldForge position TVL
function getTvl(bytes32 poolId)
    external view returns (
        uint256 amount0,      // Token0 amount in position
        uint256 amount1,      // Token1 amount in position
        uint256 valueInQuote  // Total value in quote token (18 decimals)
    );

// Get total pool TVL (all LPs, not just YieldForge)
function getPoolTotalTvl(bytes32 poolId)
    external view returns (
        uint256 amount0,      // Total token0 in pool
        uint256 amount1,      // Total token1 in pool
        uint256 valueInQuote  // Total value in quote token (18 decimals)
    );
```

#### Events

```solidity
// Emitted after each addLiquidity for indexer/analytics
event TvlUpdated(
    bytes32 indexed poolId,
    uint256 indexed cycleId,
    uint256 yfTvlAmount0,     // YieldForge position token0
    uint256 yfTvlAmount1,     // YieldForge position token1
    uint256 yfTvlInQuote,     // YieldForge TVL in quote token
    uint256 poolTvlAmount0,   // Total pool token0
    uint256 poolTvlAmount1,   // Total pool token1
    uint256 poolTvlInQuote    // Total pool TVL in quote token
);
```

---

### RedemptionFacet

**File:** `src/facets/RedemptionFacet.sol`

Handles PT redemption after maturity.

#### Standard Redemption

```solidity
function redeemPT(
    bytes32 poolId,
    uint256 cycleId,
    uint256 ptAmount,
    uint256 maxSlippageBps
) external returns (uint256 amount0, uint256 amount1);
```

**Requirements:**

- Cycle must be matured (`block.timestamp >= maturityDate`)
- User must hold sufficient PT tokens

**Flow:**

1. Calculate user's share of liquidity
2. Burn PT tokens
3. Remove liquidity via adapter
4. Apply slippage check
5. Transfer tokens to user

#### Zap Redemption

```solidity
function redeemPTWithZap(
    bytes32 poolId,
    uint256 cycleId,
    uint256 ptAmount
) external returns (
    uint256 quoteAmount,
    uint256 nonQuoteAmount,
    address quoteToken,
    address nonQuoteToken
);
```

Convenience function that redeems and returns tokens separately (quote vs non-quote).

---

### YieldAccumulatorFacet

**File:** `src/facets/YieldAccumulatorFacet.sol`

Manages yield collection and distribution to YT holders.

#### Harvest Yield

```solidity
function harvestYield(
    bytes32 poolId
) external returns (uint256 yield0, uint256 yield1);
```

**Key Features:**

- **Permissionless**: Anyone can trigger harvest
- **Protocol Fee**: 5% of yield goes to protocol
- **Distribution**: Remaining 95% distributed to YT holders via `yieldPerShare`

#### Claim Yield

```solidity
function claimYield(
    bytes32 poolId,
    uint256 cycleId
) external returns (uint256 amount0, uint256 amount1);
```

**Checkpoint System:**

- When user receives YT (mint or transfer), checkpoint is set to current `yieldPerShare`
- User can only claim yield accumulated **after** their checkpoint
- Prevents claiming yield that accumulated before ownership

#### View Functions

```solidity
function getPendingYield(
    bytes32 poolId,
    uint256 cycleId,
    address user
) external view returns (uint256 pending0, uint256 pending1);
```

#### Yield Metrics (NEW)

```solidity
struct YieldMetrics {
    uint256 historicalAPYBps;      // APY in basis points (10000 = 100%)
    uint256 totalYieldInQuote;     // Accumulated yield in quote token
    uint256 tvlInQuote;            // Total Value Locked in quote
    uint256 ytFairValueBps;        // YT fair value as % of underlying
    uint256 timeElapsedSeconds;    // Seconds since cycle start
    uint256 timeRemainingSeconds;  // Seconds until maturity
    uint256 lastHarvestTime;       // Last harvest timestamp
}

function getYieldMetrics(bytes32 poolId) 
    external view returns (YieldMetrics memory);
```

**APY Calculation:**
```
historicalAPY = (totalYield / TVL) / elapsedTime × 365 days
ytFairValue = APY × timeRemaining / 365 days
```

---

### YieldForgeMarketFacet

**File:** `src/facets/YieldForgeMarketFacet.sol`

Built-in AMM for PT trading before maturity with **time-aware pricing** that automatically converges to parity at maturity.

See [06-yield-market.md](./06-yield-market.md) for detailed documentation.

---

### YTOrderbookFacet (NEW)

**File:** `src/facets/YTOrderbookFacet.sol`

Peer-to-peer orderbook for trading Yield Tokens (YT).

#### Why Orderbook (Not AMM)?

AMM for YT has a critical problem: when YT is held by the pool, accumulated fees get "stuck" rather than going to the holder. With an orderbook:
- YT stays with the **maker** until order is filled
- Maker continues earning fees until sale
- Only at fill: claim fees → transfer YT → transfer quote

#### Order Types

| Type | Description |
|------|-------------|
| **Sell Order** | Maker sells YT for quote. YT NOT escrowed (stays with maker) |
| **Buy Order** | Maker buys YT with quote. Quote IS escrowed in contract |

#### Place Orders

```solidity
// Sell YT
function placeSellOrder(
    bytes32 poolId,
    uint256 ytAmount,
    uint256 pricePerYtBps,  // 10000 = 1:1 with underlying
    uint256 ttlSeconds      // 0 = default 7 days
) external returns (uint256 orderId);

// Buy YT
function placeBuyOrder(
    bytes32 poolId,
    uint256 ytAmount,
    uint256 pricePerYtBps,
    uint256 ttlSeconds
) external returns (uint256 orderId);
```

#### Fill Orders

```solidity
// Buy YT from sell order (taker pays quote)
function fillSellOrder(
    uint256 orderId,
    uint256 fillAmount  // Can be partial
) external returns (uint256 quotePaid);

// Sell YT to buy order (taker receives quote)
function fillBuyOrder(
    uint256 orderId,
    uint256 fillAmount
) external returns (uint256 quoteReceived);
```

#### Cancel Order

```solidity
function cancelOrder(uint256 orderId) external;
```
- Only maker can cancel
- Buy orders: escrowed quote returned

#### Fees

| Fee | Amount |
|-----|--------|
| Taker Fee | 0.3% (30 bps) of quote amount |
| Recipient | Protocol fee recipient |

#### Safety Validations

The orderbook includes the following safety checks:

| Validation | Error | Purpose |
|------------|-------|---------|
| `maker != taker` | `CannotFillOwnOrder(orderId)` | Prevents wash trading |
| `quoteAmount > 0` | `QuoteAmountTooSmall(ytAmount, price)` | Prevents zero-cost fills |
| `cycle not matured` | `CycleMatured(poolId, cycleId)` | Blocks trading after maturity |

#### View Functions

```solidity
// Get single order details
function getOrder(uint256 orderId) external view returns (Order memory);

// Get all active orders for a pool (excludes expired/cancelled/filled)
function getActiveOrders(bytes32 poolId) external view returns (Order[] memory);

// Get escrowed quote amount for buy order
function getOrderEscrow(uint256 orderId) external view returns (uint256);

// Get aggregated orderbook summary for UI
function getOrderbookSummary(bytes32 poolId) external view returns (
    uint256 sellOrderCount,   // Number of active sell orders
    uint256 buyOrderCount,    // Number of active buy orders
    uint256 bestSellPrice,    // Lowest sell price (best ask) in bps
    uint256 bestBuyPrice,     // Highest buy price (best bid) in bps
    uint256 totalSellVolume,  // Total YT available for sale
    uint256 totalBuyVolume    // Total YT demand
);
```

#### Events

```solidity
event OrderPlaced(
    uint256 indexed orderId,
    address indexed maker,
    bytes32 indexed poolId,
    uint256 cycleId,
    uint256 ytAmount,
    uint256 pricePerYtBps,
    bool isSellOrder,
    uint256 expiresAt
);

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

event OrderCancelled(uint256 indexed orderId, address indexed maker);
```

---


## Facet Interactions

```
User
  │
  ├── addLiquidity() ──────────► LiquidityFacet ──────► Adapter ──────► Uniswap
  │                                    │
  │                                    └── mints ──────► PT + YT
  │
  ├── harvestYield() ──────────► YieldAccumulatorFacet ──► Adapter.collectYield()
  │
  ├── claimYield() ────────────► YieldAccumulatorFacet ──► Transfers tokens
  │
  ├── redeemPT() ──────────────► RedemptionFacet ─────────► Adapter.removeLiquidity()
  │
  ├── swapQuoteForPT() ────────► YieldForgeMarketFacet ──► Internal AMM swap (PT)
  │
  └── placeSellOrder() ────────► YTOrderbookFacet ────────► P2P orderbook (YT)
      fillSellOrder()
```
