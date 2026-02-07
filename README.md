# Yield Forge

Yield tokenization protocol built with the Diamond pattern (EIP-2535).

## Overview

Yield Forge allows users to split LP positions into Principal Tokens (PT) and Yield Tokens (YT), enabling yield trading and fixed-rate strategies.

## Environment Variables

Create a `.env` file in the project root:

```ini
PRIVATE_KEY=<your_private_key>
RPC_URL=<rpc_endpoint>
ETHERSCAN_API_KEY=<optional_for_verification>
```

> **Note:** `PRIVATE_KEY` is always loaded from `.env` and never passed via command line.

## License

BUSL-1.1
