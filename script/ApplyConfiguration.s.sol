// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {PoolRegistryFacet} from "../src/facets/PoolRegistryFacet.sol";
import {UniswapV4Adapter} from "../src/adapters/UniswapV4Adapter.sol";
import {UniswapV3Adapter} from "../src/adapters/UniswapV3Adapter.sol";
import {CurveAdapter} from "../src/adapters/CurveAdapter.sol";

/**
 * @title ApplyConfiguration
 * @notice Synchronizes on-chain state with config file
 * @dev Reads config/<chainId>.json and ensures:
 *      1. All configured adapters are deployed
 *      2. All adapters are approved
 *      3. All quote tokens are approved
 *
 * Usage:
 *      pnpm deploy:configuration
 *
 * Required env:
 *   PRIVATE_KEY  - Owner private key
 *
 * Optional:
 *   DIAMOND      - Diamond proxy address (auto-loaded from deployments if not set)
 *   DRY_RUN=true - Only report what would be done
 *
 * Config file format (config/<chainId>.json):
 * {
 *   "name": "Ethereum Mainnet",
 *   "adapters": {
 *     "UniswapV4Adapter": { "poolManager": "0x..." },
 *     "UniswapV3Adapter": { "positionManager": "0x...", "factory": "0x..." },
 *     "CurveAdapter": { "crvToken": "0x..." }
 *   },
 *   "quoteTokens": {
 *     "USDC": "0x...",
 *     "WETH": "0x..."
 *   }
 * }
 */
contract ApplyConfiguration is Script {
    uint256 public actionsPerformed;

    function run() external {
        // ============ Load Configuration ============
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        bool dryRun = vm.envOr("DRY_RUN", false);

        string memory chainId = vm.toString(block.chainid);

        // ============ Load Diamond Address ============
        // Try env first, then load from deployments
        address diamond = vm.envOr("DIAMOND", address(0));
        if (diamond == address(0)) {
            string memory deploymentsJsonPath = string.concat(
                vm.projectRoot(),
                "/deployments/",
                chainId,
                ".json"
            );
            string memory deploymentsJson;
            try vm.readFile(deploymentsJsonPath) returns (
                string memory content
            ) {
                deploymentsJson = content;
                diamond = vm.parseJsonAddress(deploymentsJson, ".Diamond");
            } catch {
                revert(
                    string.concat(
                        "No DIAMOND env and no deployments/",
                        chainId,
                        ".json found"
                    )
                );
            }
        }

        // ============ Load Config File ============
        string memory configPath = string.concat(
            vm.projectRoot(),
            "/config/",
            chainId,
            ".json"
        );

        string memory config;
        try vm.readFile(configPath) returns (string memory content) {
            config = content;
        } catch {
            revert(
                string.concat("Config not found: config/", chainId, ".json")
            );
        }
        string memory networkName = vm.parseJsonString(config, ".name");

        console.log("=== Apply Configuration ===");
        console.log("Network:", networkName);
        console.log("Chain ID:", block.chainid);
        console.log("Diamond:", diamond);
        console.log("Dry Run:", dryRun);
        console.log("");

        PoolRegistryFacet registry = PoolRegistryFacet(diamond);

        // ============ Load Deployed Adapters ============
        string memory deploymentsPath = string.concat(
            vm.projectRoot(),
            "/deployments/adapters-",
            chainId,
            ".json"
        );

        string memory deployments = "{}";
        try vm.readFile(deploymentsPath) returns (string memory content) {
            deployments = content;
        } catch {
            console.log("No adapters deployed yet");
        }
        if (!dryRun) {
            vm.startBroadcast(privateKey);
        }

        // ============ Process Adapters (Dynamic) ============
        console.log("--- Adapters ---");

        // Read adapter names from config dynamically
        string[] memory adapterNames;
        try vm.parseJsonKeys(config, ".adapters") returns (
            string[] memory keys
        ) {
            adapterNames = keys;
        } catch {
            console.log("No adapters configured");
            adapterNames = new string[](0);
        }
        for (uint256 i = 0; i < adapterNames.length; i++) {
            _processAdapter(
                config,
                deployments,
                adapterNames[i],
                diamond,
                registry,
                dryRun
            );
        }

        // ============ Process Quote Tokens (Dynamic) ============
        console.log("");
        console.log("--- Quote Tokens ---");

        _processQuoteTokens(config, registry, dryRun);

        if (!dryRun) {
            vm.stopBroadcast();
        }

        // ============ Summary ============
        console.log("");
        console.log("=== Summary ===");
        console.log("Actions performed:", actionsPerformed);

        if (dryRun && actionsPerformed > 0) {
            console.log("Run without DRY_RUN=true to apply changes");
        }
    }

    function _processAdapter(
        string memory config,
        string memory deployments,
        string memory adapterName,
        address diamond,
        PoolRegistryFacet registry,
        bool dryRun
    ) internal {
        string memory basePath = string.concat(".adapters.", adapterName);

        // Check if already deployed
        address deployedAdapter;
        try
            vm.parseJsonAddress(deployments, string.concat(".", adapterName))
        returns (address addr) {
            deployedAdapter = addr;
        } catch {
            // Not deployed - deploy it
            console.log(string.concat("[DEPLOY] ", adapterName));
            actionsPerformed++;

            if (!dryRun) {
                deployedAdapter = _deployAdapter(
                    config,
                    basePath,
                    adapterName,
                    diamond
                );
                _saveDeployment(adapterName, deployedAdapter);
            }
        }
        if (deployedAdapter == address(0)) {
            return;
        }

        // Check if approved
        if (!registry.isAdapterApproved(deployedAdapter)) {
            console.log(string.concat("[APPROVE] ", adapterName));
            actionsPerformed++;

            if (!dryRun) {
                registry.approveAdapter(deployedAdapter);
            }
        } else {
            console.log(string.concat("[OK] ", adapterName));
        }
    }

    function _deployAdapter(
        string memory config,
        string memory basePath,
        string memory adapterName,
        address diamond
    ) internal returns (address) {
        bytes32 nameHash = keccak256(bytes(adapterName));

        if (nameHash == keccak256("UniswapV4Adapter")) {
            address poolManager = vm.parseJsonAddress(
                config,
                string.concat(basePath, ".poolManager")
            );
            address adapter = address(
                new UniswapV4Adapter(poolManager, diamond)
            );
            console.log("  Deployed at:", adapter);
            return adapter;
        }

        if (nameHash == keccak256("UniswapV3Adapter")) {
            address positionManager = vm.parseJsonAddress(
                config,
                string.concat(basePath, ".positionManager")
            );
            address factory = vm.parseJsonAddress(
                config,
                string.concat(basePath, ".factory")
            );
            address adapter = address(
                new UniswapV3Adapter(positionManager, factory, diamond)
            );
            console.log("  Deployed at:", adapter);
            return adapter;
        }

        if (nameHash == keccak256("CurveAdapter")) {
            address crvToken = vm.parseJsonAddress(
                config,
                string.concat(basePath, ".crvToken")
            );
            address adapter = address(new CurveAdapter(diamond, crvToken));
            console.log("  Deployed at:", adapter);
            return adapter;
        }

        // Unknown adapter - skip with warning
        console.log(
            string.concat("  [WARN] Unknown adapter type: ", adapterName)
        );
        return address(0);
    }

    function _processQuoteTokens(
        string memory config,
        PoolRegistryFacet registry,
        bool dryRun
    ) internal {
        string[] memory tokenNames;
        try vm.parseJsonKeys(config, ".quoteTokens") returns (
            string[] memory keys
        ) {
            tokenNames = keys;
        } catch {
            console.log("No quote tokens configured");
            return;
        }
        for (uint256 i = 0; i < tokenNames.length; i++) {
            string memory tokenName = tokenNames[i];
            address tokenAddress = vm.parseJsonAddress(
                config,
                string.concat(".quoteTokens.", tokenName)
            );

            if (!registry.isQuoteTokenApproved(tokenAddress)) {
                console.log(string.concat("[APPROVE] ", tokenName));
                actionsPerformed++;

                if (!dryRun) {
                    registry.approveQuoteToken(tokenAddress);
                }
            } else {
                console.log(string.concat("[OK] ", tokenName));
            }
        }
    }

    function _saveDeployment(
        string memory adapterName,
        address adapter
    ) internal {
        string memory chainId = vm.toString(block.chainid);
        string memory path = string.concat(
            vm.projectRoot(),
            "/deployments/adapters-",
            chainId,
            ".json"
        );

        string memory json = "adapters";
        string memory finalJson = vm.serializeAddress(
            json,
            adapterName,
            adapter
        );
        vm.writeJson(finalJson, path);
    }
}
