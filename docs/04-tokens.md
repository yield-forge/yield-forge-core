# Token Mechanics

Yield Forge uses two token types to separate principal and yield components of liquidity positions.

## Token Architecture

```
                    ┌─────────────────────────────┐
                    │        TokenBase            │
                    │     (Abstract ERC20)        │
                    └──────────────┬──────────────┘
                                   │
                    ┌──────────────┴──────────────┐
                    │                             │
              ┌─────▼─────┐               ┌───────▼───────┐
              │  Principal │               │    Yield     │
              │   Token    │               │    Token     │
              │    (PT)    │               │     (YT)     │
              └───────────┘               └───────────────┘
```

---

## TokenBase

**File:** `src/tokens/TokenBase.sol`

Abstract base contract with shared functionality for PT and YT.

### Immutable Properties

| Property       | Description                                        |
| -------------- | -------------------------------------------------- |
| `diamond`      | Address of YieldForge Diamond (only minter/burner) |
| `poolId`       | Unique pool identifier                             |
| `cycleId`      | Cycle number this token belongs to                 |
| `maturityDate` | Unix timestamp when cycle matures                  |

### Core Functions

```solidity
// Only Diamond can mint/burn
function mint(address to, uint256 amount) external;
function burn(address from, uint256 amount) external;

// View functions
function isMature() external view returns (bool);
function timeUntilMaturity() external view returns (uint256);
function getUnderlyingTokens() external view returns (address, address);
function getPoolInfo() external view returns (PoolInfo memory);
```

### Access Control

```solidity
modifier onlyDiamond() {
    require(msg.sender == diamond, "Not authorized");
    _;
}
```

---

## Principal Token (PT)

**File:** `src/tokens/PrincipalToken.sol`

### Purpose

Represents the **principal component** of a tokenized yield position. After maturity, PT can be redeemed for a proportional share of the underlying liquidity position.

### Token Naming

```
YF-PT-[HASH]-[DATE]
Example: YF-PT-A3F2E9-JAN2025
```

| Component | Meaning                           |
| --------- | --------------------------------- |
| YF        | Yield Forge brand                 |
| PT        | Principal Token                   |
| A3F2E9    | First 6 characters of poolId hash |
| JAN2025   | Maturity month/year               |

### Lifecycle

```
1. User deposits tokens via addLiquidity()
       │
       ▼
2. Diamond calculates total value in quote token
       │
       ▼
3. Diamond mints PT + YT based on quote value (18 decimals)
       │
       ▼
4. Optional: Trade PT on YieldForge Market
       │
       ▼
5. After maturity: Redeem PT for underlying tokens
       │
       ▼
6. PT burned, user receives token0 + token1
```

### PT/YT Minting: Quote Token Value

PT and YT amounts are based on the **total value of deposited tokens in quote token terms**, normalized to 18 decimals. This provides meaningful, human-readable token amounts.

**Example:**

```
User deposits: 1 WBTC + 90,000 USDT
WBTC price: ~90,000 USDT
Quote token: USDT

Total value = 90,000 (WBTC in USDT) + 90,000 (USDT) = 180,000

User receives: 180,000 PT + 180,000 YT (with 18 decimals)
```

**Calculation:**

```solidity
// Get current price from adapter (sqrtPriceX96 format)
(uint160 sqrtPriceX96, ) = adapter.getPoolPrice(poolParams);

// Convert non-quote token to quote value using price
// Normalize result to 18 decimals
uint256 valueInQuote = _calculateValueInQuote(amount0Used, amount1Used, pool);

// Mint PT/YT based on quote value
PrincipalToken(ptToken).mint(user, valueInQuote);
YieldToken(ytToken).mint(user, valueInQuote);
```

### Redemption: Proportional Share

At redemption, PT represents a **proportional share** of the pool's liquidity, regardless of the PT amount:

```solidity
userLiquidity = (ptAmount * cycle.totalLiquidity) / totalPTSupply
```

**Why this works:**

- All users who deposited at the same price get proportionally equal PT
- The ratio `ptAmount / totalPTSupply` correctly represents user's share
- Actual tokens received depend on current pool state (price, liquidity)

**Example:**

```
Pool state:
- totalLiquidity: 1000 units
- totalPTSupply: 180,000 PT (18 decimals)

User has: 18,000 PT (10% of supply)
User's liquidity: (18,000 * 1000) / 180,000 = 100 units (10%)

User receives: 10% of pool's token0 + 10% of pool's token1
```

### Trading Before Maturity

PT trades at a **discount** to face value on YieldForge Market:

- Discount reflects time value of money
- Buyers lock capital until maturity for guaranteed return
- Discount decreases as maturity approaches

---

## Yield Token (YT)

**File:** `src/tokens/YieldToken.sol`

### Purpose

Represents the **yield component** of a tokenized yield position. YT holders earn accumulated swap fees until maturity.

### Token Naming

```
YF-YT-[HASH]-[DATE]
Example: YF-YT-A3F2E9-JAN2025
```

### Yield Distribution Mechanism

```solidity
// When yield is harvested:
yieldPerShare += (totalYield * PRECISION) / totalYTSupply

// User's pending yield:
pendingYield = ytBalance * (currentYieldPerShare - userCheckpoint)
```

### Checkpoint System

Prevents users from claiming yield that accumulated before they obtained YT:

```
Time ────────────────────────────────────────────►

     Harvest    Harvest      User      Harvest
        1          2        buys YT       3
        │          │           │          │
yieldPerShare: 0 → 100 ────► 150 ───────► 200

                           checkpoint
                              set to 150

                           User can only
                           claim: 200 - 150 = 50
```

### Transfer Hook

On every YT transfer, the recipient's checkpoint is updated:

```solidity
function _update(address from, address to, uint256 amount) internal override {
    if (to == address(0) && from != address(0)) {
        // Burn: Check for unclaimed yield
        (uint256 pending0, pending1) = IYieldAccumulator(diamond)
            .getPendingYield(poolId, cycleId, from);
        if (pending0 > 0 || pending1 > 0) {
            revert UnclaimedYieldExists(pending0, pending1);
        }
    }

    super._update(from, to, amount);

    if (to != address(0)) {
        // Sync checkpoint for recipient
        IYieldAccumulator(diamond).syncCheckpoint(poolId, cycleId, to);
    }
}
```

### Burn Protection

YT cannot be burned if user has unclaimed yield:

```solidity
error UnclaimedYieldExists(uint256 pending0, uint256 pending1);
```

User must call `claimYield()` before burning YT.

---

## Two-Token Yield

Both Uniswap V3 and V4 earn fees in **both** pool tokens:

```solidity
struct CycleYieldState {
    uint256 yieldPerShare0;  // Yield per YT in token0
    uint256 yieldPerShare1;  // Yield per YT in token1
    uint256 protocolFee0;
    uint256 protocolFee1;
}
```

When claiming yield, users receive both tokens:

```solidity
function claimYield(poolId, cycleId) returns (uint256 amount0, uint256 amount1);
```

---

## Token Factory

New tokens are created by `LiquidityFacet._startNewCycle()`:

```solidity
function _startNewCycle(bytes32 poolId) internal {
    // Generate unique names
    string memory ptName = TokenNaming.generatePTName(poolId, maturityDate);
    string memory ytName = TokenNaming.generateYTName(poolId, maturityDate);

    // Deploy tokens
    PrincipalToken pt = new PrincipalToken(
        ptName, ptName, address(this), poolId, cycleId, maturityDate
    );

    YieldToken yt = new YieldToken(
        ytName, ytName, address(this), poolId, cycleId, maturityDate
    );

    // Store in cycle info
    cycle.ptToken = address(pt);
    cycle.ytToken = address(yt);
}
```

---

## Token Use Cases

### PT Strategies

| Strategy              | Description                                              |
| --------------------- | -------------------------------------------------------- |
| **Hold to maturity**  | Guaranteed return of underlying at maturity              |
| **Sell immediately**  | Lock in fixed yield by selling YT, keeping PT            |
| **Buy at discount**   | Purchase discounted PT for guaranteed profit at maturity |
| **Provide liquidity** | Add PT to YieldForge Market for LP fees                  |

### YT Strategies

| Strategy                | Description                           |
| ----------------------- | ------------------------------------- |
| **Hold for yield**      | Accumulate swap fees over time        |
| **Sell immediately**    | Monetize future yield upfront         |
| **Speculate on volume** | Buy YT betting on high trading volume |
