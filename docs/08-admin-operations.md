# Admin Operations

This document describes how to perform administrative operations after the protocol is deployed.

## Prerequisites

Ensure your `.env` file contains:
```ini
PRIVATE_KEY=<owner_private_key>
RPC_URL=<rpc_endpoint>
```

> **Security Note:** `PRIVATE_KEY` is always loaded from `.env` and never passed via command line to prevent exposure in shell history.

> **Note:** The `DIAMOND` address is automatically loaded from `deployments/<chainId>.json`

## Quick Reference

| Operation | Command |
|-----------|---------|
| Approve Adapter | `pnpm admin:approve-adapter <address>` |
| Approve Quote Token | `pnpm admin:approve-quote-token <address>` |
| Register Pool | `pnpm admin:register-pool <adapter> <params> <quote>` |
| Deprecate Adapter | `cast send $DIAMOND "deprecateAdapter(address)" <adapter>` |
| Undeprecate Adapter | `cast send $DIAMOND "undeprecateAdapter(address)" <adapter>` |

---

## 1. Approve Adapter

Before registering pools, you must approve the liquidity adapter.

```bash
pnpm admin:approve-adapter 0xAdapterAddress
```

**Example:**
```bash
pnpm admin:approve-adapter 0x1234567890123456789012345678901234567890
```

**Pre-flight checks:**
- Verifies adapter is not already approved
- Skips execution if already approved

---

## 2. Approve Quote Token

At least one of the pool's tokens must be in the quote token whitelist.

```bash
pnpm admin:approve-quote-token 0xTokenAddress
```

**Examples:**
```bash
# Approve USDC on Mainnet
pnpm admin:approve-quote-token 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48

# Approve WETH on Mainnet
pnpm admin:approve-quote-token 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
```

**Recommended tokens:**
- `USDC` - Most stable, preferred
- `WETH` - For ETH-paired pools
- `DAI` - Stable alternative

**Pre-flight checks:**
- Logs token symbol and decimals
- Skips if already approved

---

## 3. Register Pool

Register an existing pool for yield tokenization.

```bash
pnpm admin:register-pool <ADAPTER> <POOL_PARAMS> <QUOTE_TOKEN>
```

**Arguments:**
| Argument | Description |
|----------|-------------|
| `ADAPTER` | Address of the approved liquidity adapter |
| `POOL_PARAMS` | Hex-encoded pool parameters (adapter-specific) |
| `QUOTE_TOKEN` | Address of the quote token (must be in whitelist) |

### Pool Params Encoding

**UniswapV4 (PoolKey):**
```bash
cast abi-encode \
    "f((address,address,uint24,int24,address))" \
    "(0xCurrency0,0xCurrency1,3000,60,0xHookAddress)"
```

**UniswapV3 (Pool Address):**
```bash
cast abi-encode "f(address)" "0xPoolAddress"
```

### Full Example

```bash
# Encode pool params for UniswapV3
PARAMS=$(cast abi-encode "f(address)" "0xPoolAddress")

# Register the pool
pnpm admin:register-pool \
    0xUniswapV3AdapterAddress \
    $PARAMS \
    0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
```

**Pre-flight checks:**
- Verifies adapter is approved
- Verifies pool is supported by adapter
- Verifies quote token is one of pool's tokens
- Verifies quote token is in whitelist
- Logs pool tokens and selected quote token

---

## 4. Deprecate Adapter

Mark an adapter for graceful wind-down. Pools using this adapter will finish their current cycle but no new cycles will start.

```bash
cast send $DIAMOND "deprecateAdapter(address)" 0xOldAdapterAddress \
    --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

**Effects:**
- Current active cycles run to completion (users can still add liquidity, harvest, claim, trade)
- After the current cycle matures, no new cycle is created
- Redemption and yield claims are never blocked

**Verify:**
```bash
cast call $DIAMOND "isAdapterDeprecated(address)(bool)" 0xOldAdapterAddress
cast call $DIAMOND "isPoolFinished(bytes32)(bool)" $POOL_ID
```

### Undeprecate (Rollback)

```bash
cast send $DIAMOND "undeprecateAdapter(address)" 0xAdapterAddress \
    --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

### Adapter Transition Workflow

To upgrade an adapter (e.g., deploy a new version with bug fixes or new features):

```
1. Deploy new adapter contract
2. Approve new adapter:          pnpm admin:approve-adapter <newAdapter>
3. Deprecate old adapter:        cast send $DIAMOND "deprecateAdapter(address)" <oldAdapter>
4. Wait for current cycles to mature (up to 90 days)
5. Register same pools with new adapter:
   pnpm admin:register-pool <newAdapter> <poolParams> <quoteToken>
6. Revoke old adapter (optional): pnpm admin:revoke-adapter <oldAdapter>
```

---

## Verification

After registration, verify via:

```bash
cast call $DIAMOND "poolExists(bytes32)(bool)" $POOL_ID
cast call $DIAMOND "getPoolInfo(bytes32)" $POOL_ID
```

## Common Workflow

```
1. Deploy Protocol           → pnpm deploy
2. Approve Adapters          → pnpm admin:approve-adapter <address>
3. Approve Quote Tokens      → pnpm admin:approve-quote-token <address>
4. Register Pools            → pnpm admin:register-pool <adapter> <params> <quote>
5. Users can now addLiquidity → starts Cycle #1

Adapter upgrade:
6. Deploy new adapter        → ADAPTER=NewAdapter pnpm deploy:adapters
7. Approve new adapter       → pnpm admin:approve-adapter <newAdapter>
8. Deprecate old adapter     → cast send $DIAMOND "deprecateAdapter(address)" <old>
9. Wait for cycle maturity   → cast call $DIAMOND "isPoolFinished(bytes32)(bool)" <poolId>
10. Re-register pools        → pnpm admin:register-pool <newAdapter> <params> <quote>
```

---

## Dev Scripts

For local development on Anvil forks, there are additional utility scripts:

### Mint Tokens (Dev Only)

Mint/deal ERC20 tokens to your wallet on a local fork. Uses Foundry's cheatcode.

```bash
pnpm dev:mint-tokens <TOKEN_ADDRESS> <AMOUNT>
```

**Examples:**
```bash
# Mint 1000 USDC
pnpm dev:mint-tokens 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 1000

# Mint 10.5 WETH
pnpm dev:mint-tokens 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 10.5

# Mint 0.001 tokens (fractional amounts supported)
pnpm dev:mint-tokens 0xTokenAddress 0.001
```

**Features:**
- Automatically reads token decimals
- Supports fractional amounts (e.g., `10.5`, `0.001`)
- Shows balance before/after
- Only works on local Anvil forks (uses `deal` cheatcode)

> **Note:** By default uses `RPC_URL` from `.env`, or `http://localhost:8545` if not set.
