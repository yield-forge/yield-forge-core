// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {DeployHelper} from "./DeployHelper.sol";

// Facets
import {DiamondCutFacet} from "../src/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../src/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {PoolRegistryFacet} from "../src/facets/PoolRegistryFacet.sol";
import {LiquidityFacet} from "../src/facets/LiquidityFacet.sol";
import {YieldAccumulatorFacet} from "../src/facets/YieldAccumulatorFacet.sol";
import {RedemptionFacet} from "../src/facets/RedemptionFacet.sol";
import {YieldForgeMarketFacet} from "../src/facets/YieldForgeMarketFacet.sol";
import {PauseFacet} from "../src/facets/PauseFacet.sol";

/**
 * @title Upgrade Script
 * @notice Universal script for upgrading Diamond facets
 * @dev Automatically detects which selectors need to be added or replaced.
 *
 * USAGE:
 *   # Upgrade specific facet:
 *   FACET=LiquidityFacet pnpm upgrade
 *
 *   # Dry run (simulation):
 *   FACET=LiquidityFacet pnpm upgrade:dry
 *
 *   # Upgrade all facets:
 *   FACET=all pnpm upgrade
 *
 * The script will:
 * 1. Deploy new facet implementation
 * 2. Compare current Diamond selectors with expected selectors
 * 3. Create appropriate cuts (Add for new, Replace for existing)
 * 4. Execute the diamond cut
 *
 * NOTE: If Diamond is owned by Timelock, direct upgrade will fail.
 * Use proposeDiamondCut flow instead.
 */
contract Upgrade is Script, DeployHelper {
    // Facet name => selector getter mapping handled via if/else in code

    function run() external {
        string memory facetName = vm.envString("FACET");
        require(bytes(facetName).length > 0, "FACET env variable required");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address diamond = _loadDiamondAddress();

        console.log("=== Yield Forge Upgrade ===");
        console.log("Diamond:", diamond);
        console.log("Facet to upgrade:", facetName);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        if (_strEq(facetName, "all")) {
            _upgradeAllFacets(diamond);
        } else {
            _upgradeFacet(diamond, facetName);
        }

        vm.stopBroadcast();
    }

    function _upgradeFacet(address diamond, string memory facetName) internal {
        // Deploy new facet and get expected selectors
        (address newFacet, bytes4[] memory expectedSelectors) = _deployFacet(
            facetName
        );

        if (newFacet == address(0)) {
            console.log("Unknown facet:", facetName);
            revert("Unknown facet name");
        }

        console.log("New", facetName, "deployed at:", newFacet);

        // Build cuts by comparing with current Diamond state
        IDiamondCut.FacetCut[] memory cuts = _buildCuts(
            diamond,
            newFacet,
            expectedSelectors
        );

        if (cuts.length == 0) {
            console.log("No changes needed for", facetName);
            return;
        }

        // Execute cuts
        _executeCut(diamond, cuts);
    }

    function _upgradeAllFacets(address diamond) internal {
        string[7] memory facets = [
            "PoolRegistryFacet",
            "LiquidityFacet",
            "YieldAccumulatorFacet",
            "RedemptionFacet",
            "YieldForgeMarketFacet",
            "PauseFacet",
            "DiamondLoupeFacet"
        ];

        for (uint i = 0; i < facets.length; i++) {
            console.log("--- Upgrading", facets[i], "---");
            _upgradeFacet(diamond, facets[i]);
            console.log("");
        }
    }

    function _deployFacet(
        string memory facetName
    ) internal returns (address facet, bytes4[] memory selectors) {
        if (_strEq(facetName, "PoolRegistryFacet")) {
            facet = address(new PoolRegistryFacet());
            selectors = getPoolRegistrySelectors();
        } else if (_strEq(facetName, "LiquidityFacet")) {
            facet = address(new LiquidityFacet());
            selectors = getLiquiditySelectors();
        } else if (_strEq(facetName, "YieldAccumulatorFacet")) {
            facet = address(new YieldAccumulatorFacet());
            selectors = getYieldAccumulatorSelectors();
        } else if (_strEq(facetName, "RedemptionFacet")) {
            facet = address(new RedemptionFacet());
            selectors = getRedemptionSelectors();
        } else if (_strEq(facetName, "YieldForgeMarketFacet")) {
            facet = address(new YieldForgeMarketFacet());
            selectors = getYieldForgeMarketSelectors();
        } else if (_strEq(facetName, "PauseFacet")) {
            facet = address(new PauseFacet());
            selectors = getPauseSelectors();
        } else if (_strEq(facetName, "DiamondLoupeFacet")) {
            facet = address(new DiamondLoupeFacet());
            selectors = getDiamondLoupeSelectors();
        } else if (_strEq(facetName, "OwnershipFacet")) {
            facet = address(new OwnershipFacet());
            selectors = getOwnershipSelectors();
        }
    }

    function _buildCuts(
        address diamond,
        address newFacet,
        bytes4[] memory expectedSelectors
    ) internal view returns (IDiamondCut.FacetCut[] memory) {
        // Separate selectors into Add vs Replace
        bytes4[] memory toAdd = new bytes4[](expectedSelectors.length);
        bytes4[] memory toReplace = new bytes4[](expectedSelectors.length);
        uint addCount = 0;
        uint replaceCount = 0;

        IDiamondLoupe loupe = IDiamondLoupe(diamond);

        for (uint i = 0; i < expectedSelectors.length; i++) {
            bytes4 selector = expectedSelectors[i];
            address currentFacet = loupe.facetAddress(selector);

            if (currentFacet == address(0)) {
                // Selector not in Diamond - need to Add
                toAdd[addCount++] = selector;
                console.log("  [ADD]", vm.toString(selector));
            } else if (currentFacet != newFacet) {
                // Selector exists but on different facet - need to Replace
                toReplace[replaceCount++] = selector;
                console.log("  [REPLACE]", vm.toString(selector));
            }
            // If currentFacet == newFacet, no change needed
        }

        // Build cuts array
        uint cutCount = 0;
        if (addCount > 0) cutCount++;
        if (replaceCount > 0) cutCount++;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](
            cutCount
        );
        uint cutIndex = 0;

        if (addCount > 0) {
            bytes4[] memory addSelectors = new bytes4[](addCount);
            for (uint i = 0; i < addCount; i++) {
                addSelectors[i] = toAdd[i];
            }
            cuts[cutIndex++] = createCut(
                newFacet,
                IDiamondCut.FacetCutAction.Add,
                addSelectors
            );
        }

        if (replaceCount > 0) {
            bytes4[] memory replaceSelectors = new bytes4[](replaceCount);
            for (uint i = 0; i < replaceCount; i++) {
                replaceSelectors[i] = toReplace[i];
            }
            cuts[cutIndex++] = createCut(
                newFacet,
                IDiamondCut.FacetCutAction.Replace,
                replaceSelectors
            );
        }

        return cuts;
    }

    function _executeCut(
        address diamond,
        IDiamondCut.FacetCut[] memory cuts
    ) internal {
        try IDiamondCut(diamond).diamondCut(cuts, address(0), "") {
            console.log("Upgrade executed successfully");
        } catch Error(string memory reason) {
            console.log("Upgrade failed:", reason);
            console.log(
                "If Diamond is owned by Timelock, use proposeDiamondCut."
            );
        } catch {
            console.log("Upgrade failed - check owner (likely Timelock)");
            console.log("Use proposeDiamondCut flow for production.");
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

    function _strEq(
        string memory a,
        string memory b
    ) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
