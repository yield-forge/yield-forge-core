# Liquidity Adapters

Adapters provide a unified interface for interacting with different liquidity protocols. Each adapter implements `ILiquidityAdapter` and handles protocol-specific logic.

## Interface: ILiquidityAdapter

**File:** `src/interfaces/ILiquidityAdapter.sol`

```solidity
interface ILiquidityAdapter {
    // Add liquidity to underlying protocol
    function addLiquidity(bytes calldata params)
        external
        returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used);
    
    // Remove liquidity from underlying protocol
    function removeLiquidity(uint128 liquidity, bytes calldata params)
        external
        returns (uint256 amount0, uint256 amount1);
    
    // Collect accumulated yield (swap fees)
    function collectYield(bytes calldata params)
        external
        returns (uint256 yield0, uint256 yield1);
    
    // View functions
    function getPoolTokens(bytes calldata params)
        external view returns (address token0, address token1);
    
    function supportsPool(bytes calldata params)
        external view returns (bool);
    
    function getPendingYield(bytes calldata params)
        external view returns (uint256 pending0, uint256 pending1);
    
    function previewRemoveLiquidity(uint128 liquidity, bytes calldata params)
        external view returns (uint256 amount0, uint256 amount1);
    
    function protocolId() external view returns (string memory);
    function protocolAddress() external view returns (address);
    
    // Preview and pool metrics (used by UI for accurate PT/YT preview)
    function previewAddLiquidity(bytes calldata params)
        external view returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used);
    
    function calculateOptimalAmount1(uint256 amount0, bytes calldata params)
        external view returns (uint256 amount1);
    
    function calculateOptimalAmount0(uint256 amount1, bytes calldata params)
        external view returns (uint256 amount0);
    
    function getPoolPrice(bytes calldata params)
        external view returns (uint160 sqrtPriceX96, int24 tick);
    
    function getPoolFee(bytes calldata params)
        external view returns (uint24 fee);
    
    // TVL functions (for indexer/UI)
    function getPositionValue(bytes calldata params)
        external view returns (uint256 amount0, uint256 amount1);
    
    function getPoolTotalValue(bytes calldata params)
        external view returns (uint256 amount0, uint256 amount1);
}
```

---

## UniswapV4Adapter

**File:** `src/adapters/UniswapV4Adapter.sol`

### Overview

Integrates with Uniswap V4's singleton PoolManager using the `unlock()` callback pattern.

### Key Characteristics

| Property | Value |
|----------|-------|
| Protocol ID | `"V4"` |
| Position Type | Full range (MIN_TICK to MAX_TICK) |
| Liquidity | Fungible across all depositors |
| Yield Source | Swap fees in both tokens |

### Parameter Encoding

```solidity
// poolParams for registration
bytes memory poolParams = abi.encode(PoolKey({
    currency0: Currency.wrap(token0),
    currency1: Currency.wrap(token1),
    fee: 3000,        // 0.3%
    tickSpacing: 60,
    hooks: IHooks(address(0))
}));

// addLiquidity params
bytes memory params = abi.encode(poolKey, amount0, amount1);
```

### Full Range Positions

All liquidity uses full range ticks aligned to pool's tickSpacing:
```solidity
tickLower = (MIN_TICK / tickSpacing) * tickSpacing;
tickUpper = (MAX_TICK / tickSpacing) * tickSpacing;
```

This ensures all LP shares are equivalent, making PT/YT tokens fungible.

### Unlock Callback Pattern

V4 operations require calling `poolManager.unlock()`:

```solidity
function addLiquidity(...) external {
    bytes memory result = poolManager.unlock(
        abi.encode(CallbackData({
            callbackType: CallbackType.ADD_LIQUIDITY,
            poolKey: poolKey,
            amount0: amount0,
            amount1: amount1,
            ...
        }))
    );
}

function unlockCallback(bytes calldata data) external returns (bytes memory) {
    // Actual pool operations happen here
    poolManager.modifyLiquidity(...);
    // Settle token balances
}
```

### Yield Collection (Poke)

Fees are collected using the "poke" technique:
```solidity
// modifyLiquidity with liquidityDelta=0 collects fees without changing position
poolManager.modifyLiquidity(poolId, ModifyLiquidityParams({
    tickLower: ...,
    tickUpper: ...,
    liquidityDelta: 0,  // This triggers fee collection
    salt: salt
}));
```

### Preview View Functions

All adapters implement preview functions for UI integration:

| Function | V4 | V3 | Curve |
|----------|----|----|-------|
| `previewAddLiquidity` | ✅ Uses `LiquidityAmounts` library | ✅ Estimation via pool reserves | ✅ Estimation via pool reserves |
| `calculateOptimalAmount0/1` | ✅ Uses `LiquidityAmounts` | ✅ Reserve ratio | ✅ Reserve ratio |
| `getPoolPrice` | ✅ Returns `(sqrtPriceX96, tick)` | ⚠️ Returns `(0, 0)` | ⚠️ Returns `(0, 0)` |
| `getPoolFee` | ✅ Pool fee | ✅ Pool fee | ✅ Curve fee (converted) |

> **Note:** V3 and Curve adapters return `(0, 0)` for `getPoolPrice` due to interface limitations. The UI should handle this gracefully.

---

## UniswapV3Adapter

**File:** `src/adapters/UniswapV3Adapter.sol`

### Overview

Integrates with Uniswap V3 using NonfungiblePositionManager for NFT-based positions.

### Key Characteristics

| Property | Value |
|----------|-------|
| Protocol ID | `"V3"` |
| Position Type | Full range NFT position |
| Position Storage | One NFT per pool (reused for all deposits) |
| Yield Source | Swap fees in both tokens |

### Parameter Encoding

```solidity
// poolParams for registration
bytes memory poolParams = abi.encode(poolAddress);

// addLiquidity params  
bytes memory params = abi.encode(poolAddress, amount0, amount1);
```

### NFT Position Management

The adapter maintains one position NFT per pool:
```solidity
mapping(address => uint256) public poolToTokenId;
```

**First Deposit:** Creates new position via `mint()`
**Subsequent Deposits:** Increases liquidity via `increaseLiquidity()`

### Full Range Implementation

```solidity
// Constants for full range
int24 constant MIN_TICK = -887272;
int24 constant MAX_TICK = 887272;

// Aligned to pool's tick spacing
int24 tickSpacing = IUniswapV3Pool(pool).tickSpacing();
int24 tickLower = (MIN_TICK / tickSpacing) * tickSpacing;
int24 tickUpper = (MAX_TICK / tickSpacing) * tickSpacing;
```

### Remove Liquidity Flow

```solidity
function removeLiquidity(uint128 liquidity, bytes calldata params) {
    // 1. Decrease liquidity
    positionManager.decreaseLiquidity(DecreaseLiquidityParams({
        tokenId: tokenId,
        liquidity: liquidity,
        amount0Min: 0,
        amount1Min: 0,
        deadline: block.timestamp
    }));
    
    // 2. Collect tokens
    positionManager.collect(CollectParams({
        tokenId: tokenId,
        recipient: diamond,
        amount0Max: type(uint128).max,
        amount1Max: type(uint128).max
    }));
}
```

---

## CurveAdapter

**File:** `src/adapters/CurveAdapter.sol`

### Overview

Integrates with Curve StableSwap pools and gauges for CRV rewards.

### Key Characteristics

| Property | Value |
|----------|-------|
| Protocol ID | `"CRV"` |
| Pool Type | 2-token StableSwap |
| LP Storage | Staked in gauge for CRV rewards |
| Yield Source | CRV rewards (trading fees are auto-compounded) |

### Parameter Encoding

```solidity
// poolParams for registration
bytes memory poolParams = abi.encode(curvePoolAddress, gaugeAddress);

// addLiquidity params
bytes memory params = abi.encode(curvePool, gauge, amount0, amount1);
```

### Add Liquidity Flow

```solidity
function addLiquidity(bytes calldata params) {
    // 1. Add liquidity to Curve pool
    uint256 lpReceived = pool.add_liquidity([amount0, amount1], 0);
    
    // 2. Stake LP tokens in gauge for CRV rewards
    gauge.deposit(lpReceived);
    
    // 3. Return unused tokens to Diamond
}
```

### Remove Liquidity Flow

```solidity
function removeLiquidity(uint128 liquidity, bytes calldata params) {
    // 1. Withdraw from gauge
    gauge.withdraw(liquidity);
    
    // 2. Remove liquidity from pool
    pool.remove_liquidity(liquidity, [0, 0]);
    
    // 3. Transfer tokens to Diamond
}
```

### Yield Collection

```solidity
function collectYield(bytes calldata params) {
    // Claim CRV and other reward tokens from gauge
    gauge.claim_rewards(diamond);
    
    // Note: Trading fees are auto-compounded into LP value
    // They are captured on remove_liquidity, not here
}
```

### Yield Types

| Type | Handling |
|------|----------|
| Trading Fees | Auto-compounded into LP token value (captured on redemption) |
| CRV Rewards | Collected via `claim_rewards()` |

---

## Security Considerations

### Adapter Whitelisting

Only approved adapters can be used:
```solidity
// PoolRegistryFacet
mapping(address => bool) public approvedAdapters;

function registerPool(address adapter, ...) {
    require(approvedAdapters[adapter], "Adapter not approved");
}
```

### Diamond-Only Access

All adapter functions are restricted to Diamond:
```solidity
modifier onlyDiamond() {
    require(msg.sender == diamond, "Only Diamond");
    _;
}
```

### Token Handling

- All adapters use `SafeERC20` for token transfers
- Unused tokens are returned to Diamond after operations
- Diamond transfers tokens to user (adapters never hold user funds)

---

## Adding New Adapters

To support a new protocol:

1. Implement `ILiquidityAdapter` interface
2. Handle protocol-specific parameter encoding
3. Ensure only Diamond can call liquidity functions
4. Use `SafeERC20` for all token operations
5. Register with `PoolRegistryFacet.approveAdapter()`
