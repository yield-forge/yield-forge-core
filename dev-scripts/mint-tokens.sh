#!/bin/bash
# Dev script to mint ERC20 tokens on Anvil fork
# Uses forge to find the correct storage slot, then applies via Anvil RPC
#
# Usage: pnpm dev:mint-tokens <token_address> <amount>
#
# Examples:
#   pnpm dev:mint-tokens 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9 1000
#   pnpm dev:mint-tokens 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f 10

set -e

# Load .env if exists
if [ -f .env ]; then
    set -a
    source .env
    set +a
fi

TOKEN=$1
AMOUNT=$2
RPC_URL=${RPC_URL:-http://localhost:8545}

if [ -z "$TOKEN" ] || [ -z "$AMOUNT" ]; then
    echo "Usage: $0 <token_address> <amount>"
    echo "Example: $0 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9 1000"
    exit 1
fi

if [ -z "$PRIVATE_KEY" ]; then
    echo "ERROR: PRIVATE_KEY not set in .env"
    exit 1
fi

RECIPIENT=$(cast wallet address --private-key $PRIVATE_KEY)

# Step 1: Run forge script to find the correct storage slot
# The Solidity script uses stdStorage which can find slots even for proxies
echo "Finding storage slot..."

OUTPUT=$(forge script dev-scripts/MintTokens.s.sol:MintTokens \
    --rpc-url $RPC_URL \
    --sig "run(address,string)" $TOKEN $AMOUNT \
    2>&1)

# Extract the SLOT_INFO line
SLOT_LINE=$(echo "$OUTPUT" | grep "SLOT_INFO:" | tail -1)

if [ -z "$SLOT_LINE" ]; then
    echo "ERROR: Could not find storage slot"
    echo "$OUTPUT"
    exit 1
fi

# Parse: SLOT_INFO:<token>:<slot>:<value>
# The format from console.log is: SLOT_INFO:%s:%s:%s
# Which becomes: SLOT_INFO:0x...:0x...:0x...
SLOT=$(echo "$SLOT_LINE" | sed 's/.*SLOT_INFO:[^:]*:\([^:]*\):.*/\1/')
VALUE=$(echo "$SLOT_LINE" | sed 's/.*SLOT_INFO:[^:]*:[^:]*:\(.*\)/\1/' | tr -d ' ')

# Print the human-readable output from forge
echo "$OUTPUT" | grep -A 100 "=== Mint Tokens" | head -20

echo ""
echo "Applying storage change via Anvil RPC..."
echo "Slot: $SLOT"
echo "Value: $VALUE"

# Step 2: Apply the storage change via Anvil RPC
cast rpc anvil_setStorageAt $TOKEN $SLOT $VALUE --rpc-url $RPC_URL > /dev/null

# Step 3: Verify
NEW_BALANCE=$(cast call $TOKEN "balanceOf(address)(uint256)" $RECIPIENT --rpc-url $RPC_URL)

echo ""
echo "Balance After: $NEW_BALANCE"
echo ""
echo "SUCCESS: Tokens minted to $RECIPIENT"
