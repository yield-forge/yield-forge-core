// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {IERC173} from "../src/interfaces/IERC173.sol";
import {IERC165} from "../src/interfaces/IERC165.sol";

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

contract DeployHelper {
    // Helper to create a FacetCut struct
    function createCut(address facetAddress, IDiamondCut.FacetCutAction action, bytes4[] memory selectors)
        internal
        pure
        returns (IDiamondCut.FacetCut memory)
    {
        return IDiamondCut.FacetCut({facetAddress: facetAddress, action: action, functionSelectors: selectors});
    }

    // ========================================================================
    //                          SELECTOR GETTERS
    // ========================================================================
    // These functions return the selectors for each facet.
    // This helps manage selector lists in one place.

    function getDiamondCutSelectors() internal pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IDiamondCut.diamondCut.selector;
        return selectors;
    }

    function getDiamondLoupeSelectors() internal pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = IDiamondLoupe.facets.selector;
        selectors[1] = IDiamondLoupe.facetFunctionSelectors.selector;
        selectors[2] = IDiamondLoupe.facetAddresses.selector;
        selectors[3] = IDiamondLoupe.facetAddress.selector;
        selectors[4] = IERC165.supportsInterface.selector;
        return selectors;
    }

    function getOwnershipSelectors() internal pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = IERC173.owner.selector;
        selectors[1] = IERC173.transferOwnership.selector;
        return selectors;
    }

    function getPoolRegistrySelectors() internal pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = PoolRegistryFacet.initialize.selector;
        selectors[1] = PoolRegistryFacet.isInitialized.selector;
        selectors[2] = PoolRegistryFacet.approveAdapter.selector;
        selectors[3] = PoolRegistryFacet.revokeAdapter.selector;
        selectors[4] = PoolRegistryFacet.isAdapterApproved.selector;
        selectors[5] = PoolRegistryFacet.approveQuoteToken.selector;
        selectors[6] = PoolRegistryFacet.revokeQuoteToken.selector;
        selectors[7] = PoolRegistryFacet.isQuoteTokenApproved.selector;
        selectors[8] = PoolRegistryFacet.registerPool.selector;
        selectors[9] = PoolRegistryFacet.setPoolGuardian.selector;
        selectors[10] = PoolRegistryFacet.poolGuardian.selector;
        selectors[11] = PoolRegistryFacet.banPool.selector;
        // Optimization: Splitting into multiple cuts if too large in future
        // Current size ok.

        // Add remaining selectors... manually adding to avoid stack too deep in large arrays if not careful,
        // but here it's fine to just return array.
        // Re-declaring a larger array to fit all.
        // Actually, let's list them all clearly.

        selectors = new bytes4[](21);
        selectors[0] = PoolRegistryFacet.initialize.selector;
        selectors[1] = PoolRegistryFacet.isInitialized.selector;
        selectors[2] = PoolRegistryFacet.approveAdapter.selector;
        selectors[3] = PoolRegistryFacet.revokeAdapter.selector;
        selectors[4] = PoolRegistryFacet.isAdapterApproved.selector;
        selectors[5] = PoolRegistryFacet.approveQuoteToken.selector;
        selectors[6] = PoolRegistryFacet.revokeQuoteToken.selector;
        selectors[7] = PoolRegistryFacet.isQuoteTokenApproved.selector;
        selectors[8] = PoolRegistryFacet.registerPool.selector;
        selectors[9] = PoolRegistryFacet.setPoolGuardian.selector;
        selectors[10] = PoolRegistryFacet.poolGuardian.selector;
        selectors[11] = PoolRegistryFacet.banPool.selector;
        selectors[12] = PoolRegistryFacet.unbanPool.selector;
        selectors[13] = PoolRegistryFacet.isPoolBanned.selector;
        selectors[14] = PoolRegistryFacet.setPoolQuoteToken.selector;
        selectors[15] = PoolRegistryFacet.setFeeRecipient.selector;
        selectors[16] = PoolRegistryFacet.feeRecipient.selector;
        selectors[17] = PoolRegistryFacet.getPoolInfo.selector;
        selectors[18] = PoolRegistryFacet.poolExists.selector;
        selectors[19] = PoolRegistryFacet.getCurrentCycleId.selector;
        selectors[20] = PoolRegistryFacet.getCycleInfo.selector;
        // Missing getters
        // getActivePT, getActiveYT, getPoolTokens, getPoolAdapter
        // Let's expand array
        bytes4[] memory expandedSelectors = new bytes4[](25);
        for (uint256 i = 0; i < 21; i++) {
            expandedSelectors[i] = selectors[i];
        }
        expandedSelectors[21] = PoolRegistryFacet.getActivePT.selector;
        expandedSelectors[22] = PoolRegistryFacet.getActiveYT.selector;
        expandedSelectors[23] = PoolRegistryFacet.getPoolTokens.selector;
        expandedSelectors[24] = PoolRegistryFacet.getPoolAdapter.selector;

        return expandedSelectors;
    }

    function getLiquiditySelectors() internal pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = LiquidityFacet.addLiquidity.selector;
        selectors[1] = LiquidityFacet.getTotalLiquidity.selector;
        selectors[2] = LiquidityFacet.previewAddLiquidity.selector;
        selectors[3] = LiquidityFacet.calculateOptimalAmount0.selector;
        selectors[4] = LiquidityFacet.calculateOptimalAmount1.selector;
        selectors[5] = LiquidityFacet.hasActiveCycle.selector;
        selectors[6] = LiquidityFacet.timeToMaturity.selector;
        selectors[7] = LiquidityFacet.getTvl.selector;
        selectors[8] = LiquidityFacet.getPoolTotalTvl.selector;
        return selectors;
    }

    function getYieldAccumulatorSelectors() internal pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = YieldAccumulatorFacet.harvestYield.selector;
        selectors[1] = YieldAccumulatorFacet.claimYield.selector;
        selectors[2] = YieldAccumulatorFacet.syncCheckpoint.selector;
        selectors[3] = YieldAccumulatorFacet.getPendingYield.selector;
        selectors[4] = YieldAccumulatorFacet.getYieldState.selector;
        selectors[5] = YieldAccumulatorFacet.withdrawProtocolFees.selector;
        selectors[6] = YieldAccumulatorFacet.getPendingProtocolFees.selector;
        return selectors;
    }

    function getRedemptionSelectors() internal pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = RedemptionFacet.redeemPT.selector;
        selectors[1] = RedemptionFacet.redeemPTWithZap.selector;
        selectors[2] = RedemptionFacet.upgradePT.selector;
        selectors[3] = RedemptionFacet.hasMatured.selector;
        selectors[4] = RedemptionFacet.previewRedemption.selector;
        selectors[5] = RedemptionFacet.canUpgrade.selector;
        selectors[6] = RedemptionFacet.getMaturityDate.selector;
        return selectors;
    }

    function getYieldForgeMarketSelectors() internal pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = YieldForgeMarketFacet.addYieldForgeLiquidity.selector;
        selectors[1] = YieldForgeMarketFacet.removeYieldForgeLiquidity.selector;
        selectors[2] = YieldForgeMarketFacet.swapExactQuoteForPT.selector;
        selectors[3] = YieldForgeMarketFacet.swapExactPTForQuote.selector;
        selectors[4] = YieldForgeMarketFacet.getYieldForgeMarketInfo.selector;
        selectors[5] = YieldForgeMarketFacet.previewSwapQuoteForPT.selector;
        selectors[6] = YieldForgeMarketFacet.previewSwapPTForQuote.selector;
        selectors[7] = YieldForgeMarketFacet.getPtPrice.selector;
        selectors[8] = YieldForgeMarketFacet.getUserLpBalance.selector;
        selectors[9] = YieldForgeMarketFacet.getCurrentSwapFee.selector;
        selectors[10] = YieldForgeMarketFacet.getLpPositionValue.selector;
        return selectors;
    }

    function getPauseSelectors() internal pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = PauseFacet.pause.selector;
        selectors[1] = PauseFacet.unpause.selector;
        selectors[2] = PauseFacet.setPauseGuardian.selector;
        selectors[3] = PauseFacet.paused.selector;
        selectors[4] = PauseFacet.pauseGuardian.selector;
        return selectors;
    }

    function getYTOrderbookSelectors() internal pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = YTOrderbookFacet.placeSellOrder.selector;
        selectors[1] = YTOrderbookFacet.placeBuyOrder.selector;
        selectors[2] = YTOrderbookFacet.fillSellOrder.selector;
        selectors[3] = YTOrderbookFacet.fillBuyOrder.selector;
        selectors[4] = YTOrderbookFacet.cancelOrder.selector;
        selectors[5] = YTOrderbookFacet.getOrder.selector;
        selectors[6] = YTOrderbookFacet.getActiveOrders.selector;
        selectors[7] = YTOrderbookFacet.getOrderEscrow.selector;
        selectors[8] = YTOrderbookFacet.marketBuy.selector;
        selectors[9] = YTOrderbookFacet.marketSell.selector;
        return selectors;
    }
}
