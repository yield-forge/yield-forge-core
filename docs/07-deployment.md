# Deployment Guide

This document describes how to deploy and configure the Yield Forge protocol.

## Prerequisites

1.  Install [Foundry](https://getfoundry.sh).
2.  Set up your `.env` file:
    ```ini
    PRIVATE_KEY=...
    RPC_URL=...
    ETHERSCAN_API_KEY=...
    ```

> **Security Note:** `PRIVATE_KEY` is always loaded from `.env` and never passed via command line.

---

## Deployment Workflow

### Step 1: Deploy Protocol

```bash
pnpm deploy
```

This deploys:

- Diamond proxy
- All facets
- DiamondTimelock

Addresses saved to `deployments/<chainId>.json`.

---

### Step 2: Apply Configuration

The recommended way to configure the protocol is through the config files:

```bash
# Check what would be done (dry run)
pnpm deploy:configuration:dry

# Apply configuration
pnpm deploy:configuration
```

**This command will:**

1. ✅ Deploy any missing adapters from config
2. ✅ Approve any unapproved adapters
3. ✅ Approve any unapproved quote tokens

---

## Configuration Files

Configuration is stored per-chain in `config/<chainId>.json`:

```
config/
├── 1.json         # Ethereum Mainnet
├── 42161.json     # Arbitrum One
└── 11155111.json  # Sepolia Testnet
```

### Config Structure

```json
{
  "name": "Ethereum Mainnet",
  "adapters": {
    "UniswapV4Adapter": { "poolManager": "0x..." },
    "UniswapV3Adapter": { "positionManager": "0x...", "factory": "0x..." }
  },
  "quoteTokens": {
    "USDC": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    "WETH": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
  }
}
```

### Add New Network

Create `config/<chainId>.json` with protocol addresses.

### Add Adapter to Network

Add entry to `adapters` object and run `pnpm deploy:configuration`.

---

## Manual Commands

All admin scripts use command-line arguments (secrets are loaded from `.env`).

### Deploy Adapters

Deploy a specific adapter:

```bash
ADAPTER=UniswapV4Adapter pnpm deploy:adapters
```

### Approve Quote Token

```bash
pnpm admin:approve-quote-token 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
```

### Approve Adapter

```bash
pnpm admin:approve-adapter 0xAdapterAddress
```

### Register Pool

```bash
pnpm admin:register-pool <ADAPTER> <POOL_PARAMS> <QUOTE_TOKEN>
```

See [Admin Operations](./08-admin-operations.md) for detailed usage.

---

## Upgrading Facets

After deployment, you may need to upgrade facets to add new functionality or fix bugs.

### Upgrade Specific Facet

```bash
# Dry run (simulation)
FACET=LiquidityFacet pnpm facet:upgrade:dry

# Execute upgrade
FACET=LiquidityFacet pnpm facet:upgrade
```

### Upgrade All Facets

```bash
FACET=all pnpm facet:upgrade
```

### Available Facets

- `PoolRegistryFacet`
- `LiquidityFacet`
- `YieldAccumulatorFacet`
- `RedemptionFacet`
- `YieldForgeMarketFacet`
- `PauseFacet`
- `DiamondLoupeFacet`
- `OwnershipFacet`

### How It Works

The upgrade script automatically:

1. Deploys new facet implementation
2. Compares current Diamond selectors with expected selectors from `DeployHelper.sol`
3. Creates appropriate cuts:
   - `Add` for new functions
   - `Replace` for existing functions
4. Executes the diamond cut

### Adding New Functions to a Facet

1. Add the function to the facet contract (e.g., `src/facets/LiquidityFacet.sol`)
2. Add the selector to `DeployHelper.sol` in the corresponding getter (e.g., `getLiquiditySelectors()`)
3. Run the upgrade: `FACET=LiquidityFacet pnpm facet:upgrade`

### Production Note

If the Diamond is owned by a Timelock, direct upgrades will fail. Use the `proposeDiamondCut` flow instead.

---

## Post-Deployment Checklist

- [ ] Verify Diamond on Etherscan
- [ ] Run `pnpm deploy:configuration` for each network
- [ ] Transfer ownership to DiamondTimelock (production)

---

## Contracts Deployed

Addresses are saved to:

- `deployments/<chainId>.json` - Diamond and facets
- `deployments/adapters-<chainId>.json` - Adapters

---

## Available npm Scripts

| Script                                  | Description                   |
| --------------------------------------- | ----------------------------- |
| `pnpm build`                            | Compile contracts             |
| `pnpm test`                             | Run tests                     |
| `pnpm test:gas`                         | Run tests with gas report     |
| `pnpm deploy`                           | Deploy protocol               |
| `pnpm deploy:dry`                       | Deploy protocol (simulation)  |
| `pnpm deploy:adapters`                  | Deploy adapters               |
| `pnpm deploy:configuration`             | Apply full configuration      |
| `pnpm deploy:configuration:dry`         | Preview configuration changes |
| `FACET=X pnpm facet:upgrade`            | Upgrade facet                 |
| `FACET=X pnpm facet:upgrade:dry`        | Preview upgrade (simulation)  |
| `pnpm admin:approve-adapter <addr>`     | Approve adapter               |
| `pnpm admin:approve-quote-token <addr>` | Approve quote token           |
| `pnpm admin:register-pool <A> <P> <Q>`  | Register pool                 |
| `pnpm dev:mint-tokens <token> <amount>` | Mint tokens (local dev)       |
