// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {PoolRegistryFacet} from "../src/facets/PoolRegistryFacet.sol";

/**
 * @title ApproveAdapter
 * @notice Script to approve a liquidity adapter for use with Yield Forge
 *
 * Usage:
 *   pnpm admin:approve-adapter <ADAPTER_ADDRESS>
 *
 * Example:
 *   pnpm admin:approve-adapter 0x1234567890123456789012345678901234567890
 *
 * Environment variables (from .env):
 *   PRIVATE_KEY - Deployer/owner private key
 *   RPC_URL     - Network RPC URL
 *
 * The DIAMOND address is automatically loaded from deployments/<chainId>.json
 */
contract ApproveAdapter is Script {
    /**
     * @notice Main entry point - accepts adapter address as argument
     * @param adapter Address of the adapter to approve
     */
    function run(address adapter) external {
        // ============ Load Configuration ============
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address diamond = _loadDiamondAddress();

        // ============ Validation ============
        require(adapter != address(0), "Invalid adapter address");

        console.log("=== Approve Adapter ===");
        console.log("Diamond:", diamond);
        console.log("Adapter:", adapter);

        // ============ Pre-flight Checks ============
        PoolRegistryFacet registry = PoolRegistryFacet(diamond);

        bool alreadyApproved = registry.isAdapterApproved(adapter);
        if (alreadyApproved) {
            console.log("WARNING: Adapter already approved, skipping");
            return;
        }

        // ============ Execute ============
        vm.startBroadcast(privateKey);

        registry.approveAdapter(adapter);

        vm.stopBroadcast();

        // ============ Verification ============
        require(registry.isAdapterApproved(adapter), "Adapter approval failed");
        console.log("SUCCESS: Adapter approved");
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
