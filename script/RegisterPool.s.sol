// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {PoolRegistryFacet} from "../src/facets/PoolRegistryFacet.sol";
import {ILiquidityAdapter} from "../src/interfaces/ILiquidityAdapter.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title RegisterPool
 * @notice Script to register an existing pool for yield tokenization
 *
 * Usage:
 *   pnpm admin:register-pool <ADAPTER> <POOL_PARAMS> <QUOTE_TOKEN>
 *
 * Arguments:
 *   ADAPTER      - Adapter address (must be approved)
 *   POOL_PARAMS  - Hex-encoded pool parameters (adapter-specific)
 *   QUOTE_TOKEN  - Address of quote token (must be one of pool tokens + whitelisted)
 *
 * Example pool params encoding:
 *   # For UniswapV4Adapter (PoolKey):
 *   cast abi-encode "f((address,address,uint24,int24,address))" \
 *       "(0xCurrency0,0xCurrency1,3000,60,0xHookAddress)"
 *
 *   # For CurveAdapter (pool address):
 *   cast abi-encode "f(address)" "0xCurvePoolAddress"
 *
 * Environment variables (from .env):
 *   PRIVATE_KEY - Deployer/owner private key
 *   RPC_URL     - Network RPC URL
 *
 * The DIAMOND address is automatically read from deployments/<chainId>.json
 */
contract RegisterPool is Script {
    /**
     * @notice Main entry point - accepts adapter, pool params, and quote token as arguments
     * @param adapter Address of the liquidity adapter
     * @param poolParams Hex-encoded pool parameters (adapter-specific)
     * @param quoteToken Address of the quote token for the secondary market
     */
    function run(
        address adapter,
        bytes calldata poolParams,
        address quoteToken
    ) external {
        // ============ Load Configuration ============
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address diamond = _loadDiamondAddress();

        // ============ Validation ============
        require(adapter != address(0), "Invalid adapter address");
        require(poolParams.length > 0, "Pool params cannot be empty");
        require(quoteToken != address(0), "Invalid quote token address");

        console.log("=== Register Pool ===");
        console.log("Diamond:", diamond);
        console.log("Adapter:", adapter);
        console.log("Pool Params Length:", poolParams.length);
        console.log("Quote Token:", quoteToken);

        // ============ Pre-flight Checks ============
        PoolRegistryFacet registry = PoolRegistryFacet(diamond);

        // Check adapter approved
        require(
            registry.isAdapterApproved(adapter),
            "Adapter not approved. Run admin:approve-adapter first"
        );
        console.log("Adapter approved: true");

        // Check pool supported by adapter
        ILiquidityAdapter adapterContract = ILiquidityAdapter(adapter);
        require(
            adapterContract.supportsPool(poolParams),
            "Pool not supported by adapter"
        );
        console.log("Pool supported by adapter: true");

        // Get pool tokens for logging
        (address token0, address token1) = adapterContract.getPoolTokens(
            poolParams
        );
        console.log("Token0:", token0);
        console.log("Token1:", token1);

        _logTokenInfo("Token0", token0);
        _logTokenInfo("Token1", token1);

        // Check quoteToken is one of pool tokens
        require(
            quoteToken == token0 || quoteToken == token1,
            "Quote token must be one of the pool tokens"
        );

        // Check quoteToken is approved
        require(
            registry.isQuoteTokenApproved(quoteToken),
            "Quote token not in whitelist. Run admin:approve-quote-token first"
        );
        console.log("Quote Token approved: true");
        _logTokenInfo("Quote Token", quoteToken);

        // ============ Execute ============
        vm.startBroadcast(privateKey);

        bytes32 poolId = registry.registerPool(adapter, poolParams, quoteToken);

        vm.stopBroadcast();

        // ============ Output ============
        console.log("SUCCESS: Pool registered");
        console.log("Pool ID:", vm.toString(poolId));
        console.log("Used Quote Token:", quoteToken);
    }

    function _logTokenInfo(string memory label, address token) internal view {
        if (token == address(0)) {
            string memory symbol = _loadNativeTokenSymbol();
            console.log(string.concat(label, " Symbol: ", symbol));
            return;
        }

        try IERC20Metadata(token).symbol() returns (string memory symbol) {
            console.log(string.concat(label, " Symbol: ", symbol));
        } catch {
            // Native token or non-standard ERC20
        }
    }

    function _loadNativeTokenSymbol() internal view returns (string memory) {
        string memory chainId = vm.toString(block.chainid);
        string memory path = string.concat(
            vm.projectRoot(),
            "/config/",
            chainId,
            ".json"
        );

        try vm.readFile(path) returns (string memory json) {
            try vm.parseJsonString(json, ".nativeTokenSymbol") returns (
                string memory symbol
            ) {
                return symbol;
            } catch {
                return "ETH";
            }
        } catch {
            return "ETH";
        }
    }

    function _loadDiamondAddress() internal view returns (address) {
        string memory chainId = vm.toString(block.chainid);
        string memory path = string.concat(
            vm.projectRoot(),
            "/deployments/",
            chainId,
            ".json"
        );

        string memory json = vm.readFile(path);
        address diamond = vm.parseJsonAddress(json, ".Diamond");
        require(diamond != address(0), "Diamond not found in deployment file");

        console.log("Loaded Diamond from:", path);
        return diamond;
    }
}
