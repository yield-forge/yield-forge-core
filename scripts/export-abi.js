#!/usr/bin/env node
/**
 * export-abi.js
 *
 * Extracts minimal ABI JSON from Foundry output for use by downstream
 * packages (UI, indexer). The exported files are committed to git so
 * that `github:yield-forge/yield-forge-core` dependency works without
 * requiring Foundry on the consumer side.
 *
 * Usage: node scripts/export-abi.js
 */

const fs = require("fs");
const path = require("path");

const OUT = path.resolve(__dirname, "../out");
const ABI_DIR = path.resolve(__dirname, "../abi");

const FACETS = [
  "LiquidityFacet",
  "YieldForgeMarketFacet",
  "YieldAccumulatorFacet",
  "YTOrderbookFacet",
  "PoolRegistryFacet",
  "RedemptionFacet",
  "PauseFacet",
  "DiamondCutFacet",
  "DiamondLoupeFacet",
  "OwnershipFacet",
  "DiamondTimelock",
];

function main() {
  if (!fs.existsSync(OUT)) {
    console.error("Error: Foundry output not found. Run `forge build` first.");
    process.exit(1);
  }

  if (!fs.existsSync(ABI_DIR)) {
    fs.mkdirSync(ABI_DIR, { recursive: true });
  }

  for (const facet of FACETS) {
    const src = path.join(OUT, `${facet}.sol`, `${facet}.json`);
    if (!fs.existsSync(src)) {
      console.warn(`  SKIP ${facet} (not found)`);
      continue;
    }

    const { abi } = JSON.parse(fs.readFileSync(src, "utf-8"));
    const dest = path.join(ABI_DIR, `${facet}.json`);
    fs.writeFileSync(dest, JSON.stringify(abi, null, 2));
    console.log(`  ${facet} → abi/${facet}.json (${abi.length} entries)`);
  }

  console.log("\nDone. Commit abi/ to make ABIs available via GitHub dependency.");
}

main();
