# Pool and Cycle Lifecycle

This document describes the complete lifecycle of pools and cycles in Yield Forge.

## Pool Lifecycle

### 1. Pool Registration

**Who:** Protocol Owner  
**Function:** `PoolRegistryFacet.registerPool()`

```
┌─────────────────────────────────────────────────────────┐
│                   POOL REGISTRATION                      │
├─────────────────────────────────────────────────────────┤
│  1. Approve adapter (if not already)                    │
│  2. Approve quote token (if not already)                │
│  3. Call registerPool(adapter, poolParams, quoteToken)  │
│  4. Validate quoteToken is one of pool tokens           │
│  5. Cache quoteDecimals for gas efficiency              │
│  6. Pool ID generated: keccak256(adapter, poolParams)   │
│  7. Pool state: REGISTERED (no active cycle)            │
└─────────────────────────────────────────────────────────┘
```

**Pool ID Generation:**

```solidity
bytes32 poolId = keccak256(abi.encode(adapter, keccak256(poolParams)));
```

This ensures uniqueness across:

- Different protocols (same pool address won't conflict)
- Different pools within same protocol

### 2. First Liquidity (Cycle Start)

**Who:** Any User  
**Function:** `LiquidityFacet.addLiquidity()`

```
┌─────────────────────────────────────────────────────────┐
│                    CYCLE CREATION                        │
├─────────────────────────────────────────────────────────┤
│  1. Detect no active cycle (cycleId = 0)                │
│  2. Create Cycle #1                                     │
│  3. Calculate maturity (now + 90 days)                  │
│  4. Deploy new PT + YT tokens                           │
│  5. Initialize YieldForge Market (PENDING status)        │
│  6. User receives PT + YT tokens                        │
└─────────────────────────────────────────────────────────┘
```

### 3. Active Period

**Duration:** Until maturity (90 days default)

During the active period:

- Users can add liquidity → receive PT + YT
- Users can tokenize existing LP positions → receive PT + YT (via LPTokenizeFacet)
- Anyone can harvest yield → distributes to YT holders
- YT holders can claim accumulated yield
- PT can be traded on YieldForge Market

### 4. Adapter Deprecation (Graceful Wind-Down)

**Who:** Protocol Owner
**Function:** `PoolRegistryFacet.deprecateAdapter()`

```
┌─────────────────────────────────────────────────────────┐
│                ADAPTER DEPRECATED                        │
├─────────────────────────────────────────────────────────┤
│  • Current active cycle runs to completion normally     │
│  • Users CAN still add liquidity to active cycle        │
│  • Anyone CAN still harvest yield                       │
│  • YT holders CAN still claim yield                     │
│  • PT CAN still be redeemed after maturity              │
│  • No new cycles start after current cycle matures      │
│  • Owner can undeprecate via undeprecateAdapter()       │
└─────────────────────────────────────────────────────────┘
```

**"Pool Finished" State:**

A pool is considered "finished" when its adapter is deprecated AND either:
- No cycles were ever started, OR
- The last cycle has matured (`block.timestamp >= maturityDate`)

Once a pool is finished, the same underlying pool (same `poolParams`) can be re-registered with a new adapter.

**Adapter Transition Flow:**
```
1. Deploy new adapter
2. Approve new adapter
3. Deprecate old adapter
4. Wait for current cycle to mature (up to 90 days)
5. Register same poolParams with new adapter
6. Users continue with new pool
```

### 5. Pool Banning (Emergency)

**Who:** Pool Guardian or Owner
**Function:** `PoolRegistryFacet.banPool()`

```
┌─────────────────────────────────────────────────────────┐
│                    POOL BANNED                           │
├─────────────────────────────────────────────────────────┤
│  • No new liquidity can be added                        │
│  • Existing positions CAN still be redeemed             │
│  • YT holders CAN still claim yield                     │
│  • PT CAN still be traded on market                     │
│  • Owner can unban via unbanPool()                      │
└─────────────────────────────────────────────────────────┘
```

---

## Cycle Lifecycle

### Cycle States

```
   INACTIVE           ACTIVE           MATURED
       │                 │                 │
       │    First        │    Maturity     │
       │  addLiquidity   │    Date         │
       ▼                 ▼                 ▼
   ┌───────┐        ┌─────────┐       ┌─────────┐
   │  No   │───────►│ Active  │──────►│ Matured │
   │ Cycle │        │  Cycle  │       │  Cycle  │
   └───────┘        └─────────┘       └─────────┘
                         │
                         │ New addLiquidity
                         │ after maturity
                         ▼
                    ┌─────────┐
                    │  New    │
                    │ Cycle   │
                    └─────────┘
```

### Cycle Data Structure

```solidity
struct CycleInfo {
    uint256 cycleId;           // Sequential: 1, 2, 3...
    uint256 startTimestamp;    // When cycle began
    uint256 maturityDate;      // When PT can be redeemed
    uint128 totalLiquidity;    // Total LP position size
    address ptToken;           // Principal Token address
    address ytToken;           // Yield Token address
    bool isActive;             // Current active cycle flag
    int24 tickLower;           // Uniswap: MIN_TICK
    int24 tickUpper;           // Uniswap: MAX_TICK
}
```

### Cycle Duration

Default cycle duration is **90 days**:

```solidity
uint256 constant CYCLE_DURATION = 90 days;

maturityDate = block.timestamp + CYCLE_DURATION;
```

---

## Yield Lifecycle

### Yield Accumulation

```
        Pool Swap Fees
              │
              ▼
        Adapter.collectYield()
              │
              ▼
    ┌─────────────────────┐
    │    Raw Yield        │
    │  (token0 + token1)  │
    └─────────┬───────────┘
              │
              ├────► 5% Protocol Fee
              │
              └────► 95% YT Holders
                          │
                          ▼
                    yieldPerShare +=
                    (yield * 1e30) / ytSupply
```

### Harvesting

**Who:** Anyone (permissionless)  
**Function:** `YieldAccumulatorFacet.harvestYield()`

```solidity
function harvestYield(bytes32 poolId) external {
    // 1. Collect yield from adapter
    (yield0, yield1) = adapter.collectYield(poolParams);

    // 2. Calculate protocol fee (5%)
    protocolFee0 = yield0 * 500 / 10000;
    protocolFee1 = yield1 * 500 / 10000;

    // 3. Update yield per share
    yieldState.yieldPerShare0 += (userYield0 * PRECISION) / ytSupply;
    yieldState.yieldPerShare1 += (userYield1 * PRECISION) / ytSupply;
}
```

### Claiming

**Who:** YT Holders  
**Function:** `YieldAccumulatorFacet.claimYield()`

```solidity
function claimYield(poolId, cycleId) external {
    // Calculate pending yield
    pending0 = ytBalance * (yieldPerShare0 - checkpoint0) / PRECISION;
    pending1 = ytBalance * (yieldPerShare1 - checkpoint1) / PRECISION;

    // Update checkpoint
    userCheckpoint = currentYieldPerShare;

    // Transfer tokens
    token0.transfer(user, pending0);
    token1.transfer(user, pending1);
}
```

---

## Redemption Lifecycle

### PT Redemption (After Maturity)

**Who:** PT Holders  
**Function:** `RedemptionFacet.redeemPT()`

```
┌─────────────────────────────────────────────────────────┐
│                    PT REDEMPTION                         │
├─────────────────────────────────────────────────────────┤
│  Prerequisite: block.timestamp >= maturityDate          │
│                                                         │
│  1. Calculate liquidity share:                          │
│     userLiquidity = ptAmount * totalLiquidity / ptSupply│
│                                                         │
│  2. Burn PT tokens                                      │
│                                                         │
│  3. Remove liquidity via adapter                        │
│     → Returns token0 + token1                           │
│                                                         │
│  4. Apply slippage check                                │
│                                                         │
│  5. Transfer tokens to user                             │
└─────────────────────────────────────────────────────────┘
```

### YT After Maturity

After maturity:

- YT stops accumulating new yield
- Can still claim previously accumulated yield
- Cannot be burned with unclaimed yield

---

## LP Tokenize Flow

LP Tokenize allows users with existing Uniswap V3/V4 full-range positions to convert them into PT/YT tokens in a single transaction, without manually withdrawing and re-depositing.

```
┌─────────────────────────────────────────────────────────┐
│                     LP UNLOCK                           │
├─────────────────────────────────────────────────────────┤
│  Prerequisite: User has a full-range LP position        │
│                User approves NFT to Diamond             │
│                                                         │
│  1. User calls tokenizePosition(                          │
│       adapter, poolParams, quoteToken,                  │
│       userTokenId, percentBps                           │
│     )                                                   │
│                                                         │
│  2. Auto-register pool if not exists                    │
│     (self-call to registerPool)                         │
│                                                         │
│  3. Ensure active cycle (create if needed)              │
│                                                         │
│  4. Transfer NFT: user → adapter                        │
│                                                         │
│  5. Adapter:                                            │
│     a. Validate position is full-range                  │
│     b. Decrease user's position by percentBps           │
│     c. Collect principal + accumulated fees             │
│     d. Add tokens to protocol's aggregated position     │
│     e. Return NFT to user                               │
│                                                         │
│  6. Facet mints PT + YT based on value in quote token   │
│                                                         │
│  7. Refund any dust tokens to user                      │
└─────────────────────────────────────────────────────────┘
```

**Example:**
```
User has a Uniswap V3 WETH/USDC position with 10 ETH + 30,000 USDC
  │
  ├── Calls tokenizePosition(v3Adapter, ..., tokenId, 5000)  // 50%
  │
  ├── Adapter withdraws 5 ETH + 15,000 USDC from user's NFT
  │   └── Also collects accumulated swap fees
  │
  ├── Adapter deposits into protocol's position
  │
  ├── Value calculation: 5 * 3000 + 15000 = 30,000 USDC
  │
  └── User receives: 30,000 PT + 30,000 YT (18 decimals)
      User still owns their NFT with the remaining 50%
```

**Partial vs Full Unlock:**

| percentBps | Effect |
|------------|--------|
| 10000 (100%) | Entire position is converted. NFT returned with zero liquidity. |
| 5000 (50%) | Half the position is converted. NFT retains the other half. |
| 1 (0.01%) | Minimal conversion. Useful for testing. |

---

## Complete User Flow

```
Day 0: User deposits 1000 USDC + 1 ETH via addLiquidity() or tokenizePosition()
        │
        ├── Total value in quote (USDC): 1000 + 2000 = 3000
        ├── Receives 3000 PT + 3000 YT (18 decimals)
        │
        ▼
Day 1-90: Pool accumulates swap fees
        │
        ├── Anyone calls harvestYield() periodically
        ├── User's YT accrues yield share
        ├── User can claimYield() anytime
        │
        ▼
Day 45: User decides to...
        │
        ├── Option A: Hold both PT + YT until maturity
        │
        ├── Option B: Sell YT, keep PT (lock in fixed rate)
        │
        ├── Option C: Sell PT, keep YT (bet on high volume)
        │
        └── Option D: Sell both (exit position)
        │
        ▼
Day 90+: Maturity reached
        │
        ├── User claims remaining yield
        │
        └── User redeems PT for underlying tokens
             │
             └── Liquidity calculation:
                   userLiquidity = (userPT / totalPTSupply) * totalLiquidity

             → Receives proportional share of pool
               (actual amounts depend on current pool state)
```

### PT Amount vs Liquidity

**Important:** PT amount (in quote value) is different from raw liquidity units.

```
Deposit:
- User deposits 1000 USDC + 1 ETH
- Adapter adds liquidity → returns 500 liquidity units
- Quote value: 3000 USDC equivalent
- User receives: 3000 PT + 3000 YT

Redemption:
- User has 3000 PT (50% of totalPTSupply = 6000)
- Pool has 1000 total liquidity units
- User's share: 50% × 1000 = 500 liquidity units
- Adapter removes 500 liquidity → returns tokens
```

The key insight: **PT represents a share of the pool, not a fixed token amount**.

---

## Automatic Cycle Transition

When `addLiquidity()` is called after maturity:

```solidity
function ensureActiveCycle(bytes32 poolId) internal {
    // Block new cycles on deprecated adapters
    if (s.deprecatedAdapters[pool.adapter]) {
        revert AdapterDeprecated(pool.adapter);
    }

    if (block.timestamp >= currentCycle.maturityDate) {
        // Deactivate old cycle
        currentCycle.isActive = false;

        // Start new cycle
        _startNewCycle(poolId);
    }
}
```

New cycle:

- Gets new cycle ID (previous + 1)
- Deploys fresh PT + YT tokens
- Creates new YieldForge Market (PENDING)
- Old cycle's PT/YT remain valid for redemption/claiming
- **Not created** if the pool's adapter is deprecated (reverts `AdapterDeprecated`)
