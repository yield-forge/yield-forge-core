// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {Diamond} from "../src/Diamond.sol";
import {DiamondTimelock} from "../src/DiamondTimelock.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";

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
import {YTOrderbookFacet} from "../src/facets/YTOrderbookFacet.sol";

import {DeployHelper} from "./DeployHelper.sol";

contract Deploy is Script, DeployHelper {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Fee recipient configuration (default to deployer, change for prod)
        address feeRecipient = vm.envOr("FEE_RECIPIENT", deployer);
        address poolGuardian = vm.envOr("POOL_GUARDIAN", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy DiamondCutFacet
        DiamondCutFacet diamondCutFacet = new DiamondCutFacet();
        console.log("DiamondCutFacet deployed at:", address(diamondCutFacet));

        // 2. Deploy Diamond
        Diamond diamond = new Diamond(deployer, address(diamondCutFacet));
        console.log("Diamond deployed at:", address(diamond));

        // 3. Deploy other facets
        DiamondLoupeFacet diamondLoupeFacet = new DiamondLoupeFacet();
        OwnershipFacet ownershipFacet = new OwnershipFacet();
        PoolRegistryFacet poolRegistryFacet = new PoolRegistryFacet();
        LiquidityFacet liquidityFacet = new LiquidityFacet();
        YieldAccumulatorFacet yieldAccumulatorFacet = new YieldAccumulatorFacet();
        RedemptionFacet redemptionFacet = new RedemptionFacet();
        YieldForgeMarketFacet yieldForgeMarketFacet = new YieldForgeMarketFacet();
        PauseFacet pauseFacet = new PauseFacet();
        YTOrderbookFacet ytOrderbookFacet = new YTOrderbookFacet();

        console.log("Facets deployed");

        // 4. Prepare Diamond cut
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](9);

        cut[0] = createCut(address(diamondLoupeFacet), IDiamondCut.FacetCutAction.Add, getDiamondLoupeSelectors());
        cut[1] = createCut(address(ownershipFacet), IDiamondCut.FacetCutAction.Add, getOwnershipSelectors());
        cut[2] = createCut(address(poolRegistryFacet), IDiamondCut.FacetCutAction.Add, getPoolRegistrySelectors());
        cut[3] = createCut(address(liquidityFacet), IDiamondCut.FacetCutAction.Add, getLiquiditySelectors());
        cut[4] =
            createCut(address(yieldAccumulatorFacet), IDiamondCut.FacetCutAction.Add, getYieldAccumulatorSelectors());
        cut[5] = createCut(address(redemptionFacet), IDiamondCut.FacetCutAction.Add, getRedemptionSelectors());
        cut[6] =
            createCut(address(yieldForgeMarketFacet), IDiamondCut.FacetCutAction.Add, getYieldForgeMarketSelectors());
        cut[7] = createCut(address(pauseFacet), IDiamondCut.FacetCutAction.Add, getPauseSelectors());
        cut[8] = createCut(address(ytOrderbookFacet), IDiamondCut.FacetCutAction.Add, getYTOrderbookSelectors());

        // 5. Execute Diamond cut
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
        console.log("Diamond cut executed");

        // 6. Initialize Protocol
        PoolRegistryFacet(address(diamond)).initialize(feeRecipient);
        console.log("Protocol initialized with fee recipient:", feeRecipient);

        // 7. Set Pool Guardian (if different from deployer or explicit set)
        PoolRegistryFacet(address(diamond)).setPoolGuardian(poolGuardian);
        console.log("Pool Guardian set to:", poolGuardian);

        // 8. Deploy Timelock (but don't transfer ownership yet - separate step/manual)
        DiamondTimelock timelock = new DiamondTimelock(address(diamond), deployer);
        console.log("DiamondTimelock deployed at:", address(timelock));

        // Note: Transferring ownership to timelock should be a manual step or separate script to ensure verification first.

        // 9. Save deployment artifacts
        string memory chainId = vm.toString(block.chainid);
        string memory json = "deployment_data";

        vm.serializeAddress(json, "Diamond", address(diamond));
        vm.serializeAddress(json, "DiamondCutFacet", address(diamondCutFacet));
        vm.serializeAddress(json, "DiamondLoupeFacet", address(diamondLoupeFacet));
        vm.serializeAddress(json, "OwnershipFacet", address(ownershipFacet));
        vm.serializeAddress(json, "PoolRegistryFacet", address(poolRegistryFacet));
        vm.serializeAddress(json, "LiquidityFacet", address(liquidityFacet));
        vm.serializeAddress(json, "YieldAccumulatorFacet", address(yieldAccumulatorFacet));
        vm.serializeAddress(json, "RedemptionFacet", address(redemptionFacet));
        vm.serializeAddress(json, "YieldForgeMarketFacet", address(yieldForgeMarketFacet));
        vm.serializeAddress(json, "PauseFacet", address(pauseFacet));
        vm.serializeAddress(json, "YTOrderbookFacet", address(ytOrderbookFacet));
        vm.serializeAddress(json, "DiamondTimelock", address(timelock));

        string memory finalJson = vm.serializeAddress(json, "FeeRecipient", feeRecipient);

        string memory path = string.concat(vm.projectRoot(), "/deployments/", chainId, ".json");
        vm.writeJson(finalJson, path);
        console.log("Deployment artifacts saved to:", path);

        vm.stopBroadcast();
    }
}
