# Yield Forge - Architecture Overview

## Introduction

Yield Forge is a DeFi protocol that enables **yield tokenization** for liquidity positions across multiple protocols (Uniswap V4, V3, Curve). Inspired by Pendle Finance, it separates yield-bearing positions into two components:

- **Principal Token (PT)**: Represents the original deposit amount, redeemable at maturity
- **Yield Token (YT)**: Represents rights to accumulated yield (swap fees) until maturity

## Core Architecture: Diamond Pattern (EIP-2535)

The protocol uses the **Diamond Pattern** for upgradeability and modular design:

```
                    ┌──────────────────┐
                    │     Diamond      │
                    │   (Main Proxy)   │
                    └────────┬─────────┘
                             │
    ┌────────────────────────┼────────────────────────┐
    │           │            │            │           │
    ▼           ▼            ▼            ▼           ▼
┌────────┐ ┌────────┐ ┌───────────┐ ┌─────────┐ ┌──────────┐
│  Pool  │ │Liquidity│ │YieldForge │ │  Yield  │ │    YT    │
│Registry│ │ Facet   │ │MarketFacet│ │Accumul. │ │Orderbook │
└────────┘ └────────┘ └───────────┘ └─────────┘ └──────────┘
```

### Why Diamond Pattern?

1. **Unlimited contract size**: Bypasses the 24KB contract limit
2. **Modular upgrades**: Update individual facets without full redeploy
3. **Shared storage**: All facets share the same storage via `LibAppStorage`
4. **Single entry point**: Users interact with one Diamond address

## Storage Architecture

All protocol state lives in `LibAppStorage.sol`:

```solidity
struct AppStorage {
    // Pool Registry
    mapping(bytes32 => PoolInfo) pools;
    mapping(bytes32 => uint256) currentCycleId;
    
    // Cycle Management
    mapping(bytes32 => mapping(uint256 => CycleInfo)) cycles;
    
    // Yield Tracking
    mapping(bytes32 => mapping(uint256 => CycleYieldState)) cycleYieldState;
    
    // Secondary Market: PT AMM (time-aware pricing)
    mapping(bytes32 => mapping(uint256 => YieldForgeMarketInfo)) yieldForgeMarkets;
    
    // Secondary Market: YT Orderbook (peer-to-peer)
    mapping(uint256 => YTOrder) ytOrders;
    mapping(uint256 => uint256) ytOrderEscrow;
    mapping(bytes32 => uint256[]) ytOrdersByPool;
    
    // Protocol Configuration
    address protocolFeeRecipient;
    address poolGuardian;
}
```

## Component Overview

| Component | Purpose |
|-----------|---------|
| **Diamond.sol** | Main proxy contract routing calls to facets |
| **Facets** | Modular logic components (PoolRegistry, Liquidity, etc.) |
| **Libraries** | Shared utilities (LibAppStorage, LibYieldForgeMarket) |
| **Adapters** | Protocol integrations (UniswapV4, V3, Curve) |
| **Tokens** | PT and YT ERC20 implementations |
| **DiamondTimelock** | Governance timelock for upgrades (48h delay) |

### Key Features

- **Time-Aware PT AMM**: Price automatically converges to parity at maturity
- **YT Orderbook**: Peer-to-peer trading preserving yield rights until fill
- **Yield Metrics**: Historical APY and YT fair value calculation

## Security Architecture

1. **Access Control**: Owner-only admin functions, PoolGuardian for emergencies
2. **Timelock**: 48-hour delay for Diamond upgrades
3. **Reentrancy Guards**: All state-changing functions protected
4. **Pausable**: Emergency pause mechanism across protocol
5. **Adapter Whitelisting**: Only approved adapters can be used

## Related Documentation

- [02-facets.md](./02-facets.md) - Detailed facet documentation
- [03-adapters.md](./03-adapters.md) - Liquidity adapter implementations
- [04-tokens.md](./04-tokens.md) - PT/YT token mechanics
- [05-lifecycle.md](./05-lifecycle.md) - Pool and cycle lifecycle
- [06-yield-market.md](./06-yield-market.md) - YieldForge Market AMM

