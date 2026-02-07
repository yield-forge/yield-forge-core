// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {PoolRegistryFacet} from "../src/facets/PoolRegistryFacet.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title ApproveQuoteToken
 * @notice Script to approve a token for use as quote currency in secondary markets
 *
 * Usage:
 *   pnpm admin:approve-quote-token <TOKEN_ADDRESS>
 *
 * Example:
 *   pnpm admin:approve-quote-token 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
 *
 * Environment variables (from .env):
 *   PRIVATE_KEY - Deployer/owner private key
 *   RPC_URL     - Network RPC URL
 *
 * The DIAMOND address is automatically loaded from deployments/<chainId>.json
 */
contract ApproveQuoteToken is Script {
    /**
     * @notice Main entry point - accepts quote token address as argument
     * @param quoteToken Address of the token to approve as quote currency
     */
    function run(address quoteToken) external {
        // ============ Load Configuration ============
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address diamond = _loadDiamondAddress();

        // ============ Validation ============
        require(quoteToken != address(0), "Invalid quote token address");

        console.log("=== Approve Quote Token ===");
        console.log("Diamond:", diamond);
        console.log("Quote Token:", quoteToken);

        // ============ Token Info (for logging) ============
        if (quoteToken == address(0)) {
            string memory symbol = _loadNativeTokenSymbol();
            console.log("Token Symbol:", symbol);
            console.log("Token Decimals: 18");
        } else {
            try IERC20Metadata(quoteToken).symbol() returns (
                string memory symbol
            ) {
                console.log("Token Symbol:", symbol);
            } catch {
                console.log("WARNING: Could not read token symbol");
            }
            try IERC20Metadata(quoteToken).decimals() returns (uint8 decimals) {
                console.log("Token Decimals:", decimals);
            } catch {
                console.log("WARNING: Could not read token decimals");
            }
        }
        // ============ Pre-flight Checks ============
        PoolRegistryFacet registry = PoolRegistryFacet(diamond);

        bool alreadyApproved = registry.isQuoteTokenApproved(quoteToken);
        if (alreadyApproved) {
            console.log("WARNING: Quote token already approved, skipping");
            return;
        }

        // ============ Execute ============
        vm.startBroadcast(privateKey);

        registry.approveQuoteToken(quoteToken);

        vm.stopBroadcast();

        // ============ Verification ============
        require(
            registry.isQuoteTokenApproved(quoteToken),
            "Quote token approval failed"
        );
        console.log("SUCCESS: Quote token approved");
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

        return diamond;
    }
}
