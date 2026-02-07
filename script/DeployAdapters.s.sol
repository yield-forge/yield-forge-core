// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {PoolRegistryFacet} from "../src/facets/PoolRegistryFacet.sol";
import {UniswapV4Adapter} from "../src/adapters/UniswapV4Adapter.sol";
import {UniswapV3Adapter} from "../src/adapters/UniswapV3Adapter.sol";
import {CurveAdapter} from "../src/adapters/CurveAdapter.sol";

/**
 * @title DeployAdapters
 * @notice Deploy a specific adapter using per-chain config
 * @dev Run with adapter name:
 *
 *      ADAPTER=UniswapV4Adapter pnpm deploy:adapters
 *      ADAPTER=UniswapV3Adapter pnpm deploy:adapters
 *      ADAPTER=CurveAdapter pnpm deploy:adapters
 *
 * Required env:
 *   PRIVATE_KEY  - Deployer private key
 *   ADAPTER      - Adapter name
 *
 * The DIAMOND address is automatically loaded from deployments/<chainId>.json
 *
 * Optional:
 *   AUTO_APPROVE=true - Automatically approve adapter (default: true)
 *
 * Protocol addresses are loaded from config/<chainId>.json
 */
contract DeployAdapters is Script {
    function run() external {
        // ============ Load Configuration ============
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address diamond = _loadDiamondAddress();
        string memory adapterName = vm.envString("ADAPTER");
        bool autoApprove = vm.envOr("AUTO_APPROVE", true);

        // ============ Validation ============
        require(bytes(adapterName).length > 0, "ADAPTER not set");

        // ============ Load Config File ============
        string memory chainId = vm.toString(block.chainid);
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
        string memory basePath = string.concat(".adapters.", adapterName);

        console.log("=== Deploy Adapter ===");
        console.log("Network:", networkName);
        console.log("Chain ID:", block.chainid);
        console.log("Diamond:", diamond);
        console.log("Adapter:", adapterName);

        vm.startBroadcast(privateKey);

        // ============ Deploy Adapter ============
        address adapter;

        if (keccak256(bytes(adapterName)) == keccak256("UniswapV4Adapter")) {
            adapter = _deployV4(config, basePath, diamond);
        } else if (
            keccak256(bytes(adapterName)) == keccak256("UniswapV3Adapter")
        ) {
            adapter = _deployV3(config, basePath, diamond);
        } else if (keccak256(bytes(adapterName)) == keccak256("CurveAdapter")) {
            adapter = _deployCurve(config, basePath, diamond);
        } else {
            revert(string.concat("Unknown adapter: ", adapterName));
        }

        // ============ Auto Approve ============
        if (autoApprove) {
            PoolRegistryFacet registry = PoolRegistryFacet(diamond);

            if (!registry.isAdapterApproved(adapter)) {
                registry.approveAdapter(adapter);
                console.log("Adapter approved");
            } else {
                console.log("Adapter already approved");
            }
        }

        vm.stopBroadcast();

        // ============ Save Deployment ============
        _saveDeployment(adapterName, adapter);

        console.log("=== Deployment Complete ===");
    }

    function _deployV4(
        string memory config,
        string memory basePath,
        address diamond
    ) internal returns (address) {
        address poolManager = vm.parseJsonAddress(
            config,
            string.concat(basePath, ".poolManager")
        );
        require(poolManager != address(0), "poolManager not configured");

        console.log("PoolManager:", poolManager);

        UniswapV4Adapter adapter = new UniswapV4Adapter(poolManager, diamond);
        console.log("UniswapV4Adapter deployed at:", address(adapter));
        return address(adapter);
    }

    function _deployV3(
        string memory config,
        string memory basePath,
        address diamond
    ) internal returns (address) {
        address positionManager = vm.parseJsonAddress(
            config,
            string.concat(basePath, ".positionManager")
        );
        address factory = vm.parseJsonAddress(
            config,
            string.concat(basePath, ".factory")
        );
        require(
            positionManager != address(0),
            "positionManager not configured"
        );
        require(factory != address(0), "factory not configured");

        console.log("PositionManager:", positionManager);
        console.log("Factory:", factory);

        UniswapV3Adapter adapter = new UniswapV3Adapter(
            positionManager,
            factory,
            diamond
        );
        console.log("UniswapV3Adapter deployed at:", address(adapter));
        return address(adapter);
    }

    function _deployCurve(
        string memory config,
        string memory basePath,
        address diamond
    ) internal returns (address) {
        address crvToken = vm.parseJsonAddress(
            config,
            string.concat(basePath, ".crvToken")
        );
        require(crvToken != address(0), "crvToken not configured");

        console.log("CRV Token:", crvToken);

        CurveAdapter adapter = new CurveAdapter(diamond, crvToken);
        console.log("CurveAdapter deployed at:", address(adapter));
        return address(adapter);
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

        // Try to read existing file, or start fresh
        string memory json = "adapters";
        string memory existingPath = path;

        try vm.readFile(existingPath) returns (string memory content) {
            // Parse existing adapters and re-serialize them
            string[] memory keys = vm.parseJsonKeys(content, "$");
            for (uint256 i = 0; i < keys.length; i++) {
                if (
                    keccak256(bytes(keys[i])) != keccak256(bytes(adapterName))
                ) {
                    address existingAdapter = vm.parseJsonAddress(
                        content,
                        string.concat(".", keys[i])
                    );
                    vm.serializeAddress(json, keys[i], existingAdapter);
                }
            }
        } catch {
            // File doesn't exist, that's fine
        }
        string memory finalJson = vm.serializeAddress(
            json,
            adapterName,
            adapter
        );

        vm.writeJson(finalJson, path);
        console.log("Saved to:", path);
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
