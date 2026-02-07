// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Diamond} from "../src/Diamond.sol";
import {DiamondCutFacet} from "../src/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../src/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {PoolRegistryFacet} from "../src/facets/PoolRegistryFacet.sol";
import {LiquidityFacet} from "../src/facets/LiquidityFacet.sol";
import {YTOrderbookFacet} from "../src/facets/YTOrderbookFacet.sol";
import {YieldAccumulatorFacet} from "../src/facets/YieldAccumulatorFacet.sol";
import {LibAppStorage} from "../src/libraries/LibAppStorage.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {IERC165} from "../src/interfaces/IERC165.sol";
import {IERC173} from "../src/interfaces/IERC173.sol";
import {ILiquidityAdapter} from "../src/interfaces/ILiquidityAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title YTOrderbookFacetTest
 * @notice Comprehensive tests for YT orderbook: placement, filling, cancellation, edge cases
 */
contract YTOrderbookFacetTest is Test {
    Diamond diamond;
    DiamondCutFacet diamondCutFacet;
    DiamondLoupeFacet diamondLoupeFacet;
    OwnershipFacet ownershipFacet;
    PoolRegistryFacet poolRegistryFacet;
    LiquidityFacet liquidityFacet;
    YTOrderbookFacet ytOrderbookFacet;
    YieldAccumulatorFacet yieldAccumulatorFacet;

    MockOrderbookAdapter mockAdapter;
    MockERC20 quoteToken; // USDC
    MockERC20 token1;

    address owner = address(this);
    address maker = address(0x1);
    address taker = address(0x2);
    address treasury = address(0x3);

    bytes32 poolId;

    function setUp() public {
        // Deploy mock tokens
        quoteToken = new MockERC20("USDC", "USDC");
        token1 = new MockERC20("Token1", "TK1");

        // Deploy facets
        diamondCutFacet = new DiamondCutFacet();
        diamond = new Diamond(owner, address(diamondCutFacet));
        diamondLoupeFacet = new DiamondLoupeFacet();
        ownershipFacet = new OwnershipFacet();
        poolRegistryFacet = new PoolRegistryFacet();
        liquidityFacet = new LiquidityFacet();
        ytOrderbookFacet = new YTOrderbookFacet();
        yieldAccumulatorFacet = new YieldAccumulatorFacet();

        // Deploy mock adapter
        mockAdapter = new MockOrderbookAdapter(
            address(quoteToken),
            address(token1),
            address(diamond)
        );

        // Add facets to Diamond
        _addFacets();

        // Setup protocol state
        _setupProtocol();
    }

    function _addFacets() internal {
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](6);

        // DiamondLoupeFacet
        bytes4[] memory loupeSelectors = new bytes4[](5);
        loupeSelectors[0] = IDiamondLoupe.facets.selector;
        loupeSelectors[1] = IDiamondLoupe.facetFunctionSelectors.selector;
        loupeSelectors[2] = IDiamondLoupe.facetAddresses.selector;
        loupeSelectors[3] = IDiamondLoupe.facetAddress.selector;
        loupeSelectors[4] = IERC165.supportsInterface.selector;
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(diamondLoupeFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: loupeSelectors
        });

        // OwnershipFacet
        bytes4[] memory ownershipSelectors = new bytes4[](2);
        ownershipSelectors[0] = IERC173.owner.selector;
        ownershipSelectors[1] = IERC173.transferOwnership.selector;
        cut[1] = IDiamondCut.FacetCut({
            facetAddress: address(ownershipFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: ownershipSelectors
        });

        // PoolRegistryFacet
        bytes4[] memory registrySelectors = new bytes4[](7);
        registrySelectors[0] = PoolRegistryFacet.initialize.selector;
        registrySelectors[1] = PoolRegistryFacet.approveAdapter.selector;
        registrySelectors[2] = PoolRegistryFacet.approveQuoteToken.selector;
        registrySelectors[3] = PoolRegistryFacet.registerPool.selector;
        registrySelectors[4] = PoolRegistryFacet.getCurrentCycleId.selector;
        registrySelectors[5] = PoolRegistryFacet.getCycleInfo.selector;
        registrySelectors[6] = PoolRegistryFacet.setFeeRecipient.selector;
        cut[2] = IDiamondCut.FacetCut({
            facetAddress: address(poolRegistryFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: registrySelectors
        });

        // LiquidityFacet
        bytes4[] memory liquiditySelectors = new bytes4[](1);
        liquiditySelectors[0] = LiquidityFacet.addLiquidity.selector;
        cut[3] = IDiamondCut.FacetCut({
            facetAddress: address(liquidityFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: liquiditySelectors
        });

        // YTOrderbookFacet
        bytes4[] memory orderbookSelectors = new bytes4[](9);
        orderbookSelectors[0] = YTOrderbookFacet.placeSellOrder.selector;
        orderbookSelectors[1] = YTOrderbookFacet.placeBuyOrder.selector;
        orderbookSelectors[2] = YTOrderbookFacet.fillSellOrder.selector;
        orderbookSelectors[3] = YTOrderbookFacet.fillBuyOrder.selector;
        orderbookSelectors[4] = YTOrderbookFacet.cancelOrder.selector;
        orderbookSelectors[5] = YTOrderbookFacet.getOrder.selector;
        orderbookSelectors[6] = YTOrderbookFacet.getActiveOrders.selector;
        orderbookSelectors[7] = YTOrderbookFacet.getOrderEscrow.selector;
        orderbookSelectors[8] = YTOrderbookFacet.getOrderbookSummary.selector;
        cut[4] = IDiamondCut.FacetCut({
            facetAddress: address(ytOrderbookFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: orderbookSelectors
        });

        // YieldAccumulatorFacet (for syncCheckpoint)
        bytes4[] memory yieldSelectors = new bytes4[](1);
        yieldSelectors[0] = YieldAccumulatorFacet.syncCheckpoint.selector;
        cut[5] = IDiamondCut.FacetCut({
            facetAddress: address(yieldAccumulatorFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: yieldSelectors
        });

        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
    }

    function _setupProtocol() internal {
        // Initialize protocol
        PoolRegistryFacet(address(diamond)).initialize(treasury);

        // Approve adapter and quote token
        PoolRegistryFacet(address(diamond)).approveAdapter(
            address(mockAdapter)
        );
        PoolRegistryFacet(address(diamond)).approveQuoteToken(
            address(quoteToken)
        );

        // Register pool
        bytes memory poolParams = abi.encode(address(0xB001));
        poolId = PoolRegistryFacet(address(diamond)).registerPool(
            address(mockAdapter),
            poolParams,
            address(quoteToken)
        );

        // Mint tokens to users
        quoteToken.mint(maker, 100_000e18);
        token1.mint(maker, 100_000e18);
        quoteToken.mint(taker, 100_000e18);
        token1.mint(taker, 100_000e18);
    }

    // Shorthand
    function orderbook() internal view returns (YTOrderbookFacet) {
        return YTOrderbookFacet(address(diamond));
    }

    function registry() internal view returns (PoolRegistryFacet) {
        return PoolRegistryFacet(address(diamond));
    }

    function liquidity() internal view returns (LiquidityFacet) {
        return LiquidityFacet(address(diamond));
    }

    // ================================================================
    //                        HELPERS
    // ================================================================

    function _createCycleWithYT() internal {
        vm.startPrank(maker);
        quoteToken.approve(address(diamond), 10_000e18);
        token1.approve(address(diamond), 10_000e18);
        liquidity().addLiquidity(poolId, 10_000e18, 10_000e18);
        vm.stopPrank();
    }

    function _getYtToken() internal view returns (address) {
        return registry().getCycleInfo(poolId, 1).ytToken;
    }

    function _getPtToken() internal view returns (address) {
        return registry().getCycleInfo(poolId, 1).ptToken;
    }

    // ================================================================
    //                  SELL ORDER PLACEMENT TESTS
    // ================================================================

    function test_PlaceSellOrder_Success() public {
        _createCycleWithYT();
        address ytToken = _getYtToken();
        uint256 ytBalance = IERC20(ytToken).balanceOf(maker);

        vm.startPrank(maker);
        IERC20(ytToken).approve(address(diamond), ytBalance);

        uint256 orderId = orderbook().placeSellOrder(
            poolId,
            100e18, // ytAmount
            2e16, // pricePerYt (0.02 quote tokens per YT)
            0 // default TTL
        );
        vm.stopPrank();

        assertEq(orderId, 1);

        YTOrderbookFacet.Order memory order = orderbook().getOrder(orderId);
        assertEq(order.id, 1);
        assertEq(order.maker, maker);
        assertEq(order.poolId, poolId);
        assertEq(order.ytAmount, 100e18);
        assertEq(order.pricePerYt, 2e16);
        assertTrue(order.isSellOrder);
        assertTrue(order.isActive);
        assertEq(order.filledAmount, 0);
    }

    function test_PlaceSellOrder_RevertsOnZeroAmount() public {
        _createCycleWithYT();

        vm.prank(maker);
        vm.expectRevert(
            abi.encodeWithSelector(
                YTOrderbookFacet.AmountTooSmall.selector,
                0,
                1e15
            )
        );
        orderbook().placeSellOrder(poolId, 0, 200, 0);
    }

    function test_PlaceSellOrder_RevertsOnAmountBelowMin() public {
        _createCycleWithYT();

        vm.prank(maker);
        vm.expectRevert(
            abi.encodeWithSelector(
                YTOrderbookFacet.AmountTooSmall.selector,
                1e14, // below min
                1e15
            )
        );
        orderbook().placeSellOrder(poolId, 1e14, 200, 0);
    }

    function test_PlaceSellOrder_RevertsOnInvalidPrice() public {
        _createCycleWithYT();

        vm.startPrank(maker);
        // Price = 0
        vm.expectRevert(
            abi.encodeWithSelector(YTOrderbookFacet.InvalidPrice.selector, 0)
        );
        orderbook().placeSellOrder(poolId, 100e18, 0, 0);
        // Note: no upper limit on pricePerYt anymore (was BPS max 10000)
        vm.stopPrank();
    }

    function test_PlaceSellOrder_RevertsOnInsufficientYT() public {
        _createCycleWithYT();
        address ytToken = _getYtToken();
        uint256 ytBalance = IERC20(ytToken).balanceOf(maker);

        vm.prank(maker);
        vm.expectRevert(
            abi.encodeWithSelector(
                YTOrderbookFacet.InsufficientYTBalance.selector,
                ytBalance + 1,
                ytBalance
            )
        );
        orderbook().placeSellOrder(poolId, ytBalance + 1, 200, 0);
    }

    function test_PlaceSellOrder_CustomTTL() public {
        _createCycleWithYT();
        address ytToken = _getYtToken();

        vm.startPrank(maker);
        IERC20(ytToken).approve(address(diamond), 100e18);

        uint256 orderId = orderbook().placeSellOrder(
            poolId,
            100e18,
            200,
            1 days // custom TTL
        );
        vm.stopPrank();

        YTOrderbookFacet.Order memory order = orderbook().getOrder(orderId);
        assertEq(order.expiresAt, block.timestamp + 1 days);
    }

    // ================================================================
    //                  BUY ORDER PLACEMENT TESTS
    // ================================================================

    function test_PlaceBuyOrder_Success() public {
        _createCycleWithYT();

        vm.startPrank(maker);
        quoteToken.approve(address(diamond), 10e18);

        uint256 orderId = orderbook().placeBuyOrder(
            poolId,
            100e18, // want 100 YT
            3e16, // pricePerYt = 0.03 quote per YT
            0 // default TTL
        );
        vm.stopPrank();

        assertEq(orderId, 1);

        YTOrderbookFacet.Order memory order = orderbook().getOrder(orderId);
        assertFalse(order.isSellOrder);
        assertEq(order.ytAmount, 100e18);
        assertEq(order.pricePerYt, 3e16);
        assertTrue(order.isActive);

        // Check escrow
        // quoteAmount = 100e18 * 3e16 / 1e18 = 3e18
        uint256 expectedEscrow = 3e18;
        assertEq(orderbook().getOrderEscrow(orderId), expectedEscrow);
    }

    function test_PlaceBuyOrder_EscrowsQuote() public {
        _createCycleWithYT();

        uint256 balanceBefore = quoteToken.balanceOf(maker);

        vm.startPrank(maker);
        quoteToken.approve(address(diamond), 10e18);
        orderbook().placeBuyOrder(poolId, 100e18, 3e16, 0); // pricePerYt = 0.03
        vm.stopPrank();

        uint256 balanceAfter = quoteToken.balanceOf(maker);
        // quoteAmount = 100e18 * 3e16 / 1e18 = 3e18
        uint256 expectedEscrow = 3e18;
        assertEq(balanceBefore - balanceAfter, expectedEscrow);
    }

    // ================================================================
    //                  FILL SELL ORDER TESTS
    // ================================================================

    function test_FillSellOrder_FullFill() public {
        _createCycleWithYT();
        address ytToken = _getYtToken();

        // Maker places sell order at 0.02 quote per YT = 2e16
        vm.startPrank(maker);
        IERC20(ytToken).approve(address(diamond), 100e18);
        uint256 orderId = orderbook().placeSellOrder(poolId, 100e18, 2e16, 0);
        vm.stopPrank();

        // Taker fills
        uint256 takerQuoteBefore = quoteToken.balanceOf(taker);
        uint256 takerYtBefore = IERC20(ytToken).balanceOf(taker);

        vm.startPrank(taker);
        quoteToken.approve(address(diamond), 10e18);
        uint256 quotePaid = orderbook().fillSellOrder(orderId, 100e18);
        vm.stopPrank();

        // Verify transfer
        // quoteAmount = 100e18 * 2e16 / 1e18 = 2e18
        uint256 expectedQuote = 2e18;
        assertEq(quotePaid, expectedQuote);
        assertEq(IERC20(ytToken).balanceOf(taker), takerYtBefore + 100e18);
        assertLt(quoteToken.balanceOf(taker), takerQuoteBefore);

        // Order should be inactive
        YTOrderbookFacet.Order memory order = orderbook().getOrder(orderId);
        assertFalse(order.isActive);
        assertEq(order.filledAmount, 100e18);
    }

    function test_FillSellOrder_PartialFill() public {
        _createCycleWithYT();
        address ytToken = _getYtToken();

        vm.startPrank(maker);
        IERC20(ytToken).approve(address(diamond), 100e18);
        uint256 orderId = orderbook().placeSellOrder(poolId, 100e18, 2e16, 0);
        vm.stopPrank();

        // Partial fill (50%)
        vm.startPrank(taker);
        quoteToken.approve(address(diamond), 10e18);
        orderbook().fillSellOrder(orderId, 50e18);
        vm.stopPrank();

        // Order should still be active
        YTOrderbookFacet.Order memory order = orderbook().getOrder(orderId);
        assertTrue(order.isActive);
        assertEq(order.filledAmount, 50e18);
    }

    function test_FillSellOrder_RevertsOnExpiredOrder() public {
        _createCycleWithYT();
        address ytToken = _getYtToken();

        vm.startPrank(maker);
        IERC20(ytToken).approve(address(diamond), 100e18);
        uint256 orderId = orderbook().placeSellOrder(
            poolId,
            100e18,
            200,
            1 days
        );
        vm.stopPrank();

        // Fast forward past expiry
        vm.warp(block.timestamp + 2 days);

        vm.startPrank(taker);
        quoteToken.approve(address(diamond), 10e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                YTOrderbookFacet.OrderExpired.selector,
                orderId
            )
        );
        orderbook().fillSellOrder(orderId, 100e18);
        vm.stopPrank();
    }

    function test_FillSellOrder_RevertsOnFillExceedsRemaining() public {
        _createCycleWithYT();
        address ytToken = _getYtToken();

        vm.startPrank(maker);
        IERC20(ytToken).approve(address(diamond), 100e18);
        uint256 orderId = orderbook().placeSellOrder(poolId, 100e18, 200, 0);
        vm.stopPrank();

        vm.startPrank(taker);
        quoteToken.approve(address(diamond), 20e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                YTOrderbookFacet.FillExceedsRemaining.selector,
                101e18,
                100e18
            )
        );
        orderbook().fillSellOrder(orderId, 101e18);
        vm.stopPrank();
    }

    function test_FillSellOrder_TakerFeeDeducted() public {
        _createCycleWithYT();
        address ytToken = _getYtToken();

        vm.startPrank(maker);
        IERC20(ytToken).approve(address(diamond), 100e18);
        // pricePerYt = 0.1 quote per YT = 1e17
        uint256 orderId = orderbook().placeSellOrder(poolId, 100e18, 1e17, 0);
        vm.stopPrank();

        uint256 makerQuoteBefore = quoteToken.balanceOf(maker);
        uint256 treasuryBefore = quoteToken.balanceOf(treasury);

        vm.startPrank(taker);
        quoteToken.approve(address(diamond), 100e18);
        orderbook().fillSellOrder(orderId, 100e18);
        vm.stopPrank();

        // Quote paid = 100e18 * 1e17 / 1e18 = 10e18
        // Taker fee = 10e18 * 30 / 10000 = 0.03e18
        uint256 expectedFee = (10e18 * 30) / 10_000;
        assertEq(quoteToken.balanceOf(treasury) - treasuryBefore, expectedFee);
        assertEq(
            quoteToken.balanceOf(maker) - makerQuoteBefore,
            10e18 - expectedFee
        );
    }

    // ================================================================
    //                  FILL BUY ORDER TESTS
    // ================================================================

    function test_FillBuyOrder_FullFill() public {
        _createCycleWithYT();
        address ytToken = _getYtToken();

        // Maker places buy order at 0.05 quote per YT = 5e16
        vm.startPrank(maker);
        quoteToken.approve(address(diamond), 10e18);
        uint256 orderId = orderbook().placeBuyOrder(poolId, 100e18, 5e16, 0);
        vm.stopPrank();

        // Transfer YT to taker
        vm.prank(maker);
        IERC20(ytToken).transfer(taker, 100e18);

        // Taker fills
        uint256 takerQuoteBefore = quoteToken.balanceOf(taker);
        uint256 makerYtBefore = IERC20(ytToken).balanceOf(maker);

        vm.startPrank(taker);
        IERC20(ytToken).approve(address(diamond), 100e18);
        uint256 quoteReceived = orderbook().fillBuyOrder(orderId, 100e18);
        vm.stopPrank();

        // 100e18 * 5e16 / 1e18 = 5e18 quote
        // Minus 0.3% fee = 5e18 * 30 / 10000 = 0.015e18
        uint256 expectedQuote = 5e18;
        uint256 expectedFee = (expectedQuote * 30) / 10_000;
        assertEq(quoteReceived, expectedQuote - expectedFee);

        // Maker receives YT
        assertEq(IERC20(ytToken).balanceOf(maker), makerYtBefore + 100e18);

        // Order inactive
        YTOrderbookFacet.Order memory order = orderbook().getOrder(orderId);
        assertFalse(order.isActive);
    }

    function test_FillBuyOrder_PartialFill() public {
        _createCycleWithYT();
        address ytToken = _getYtToken();

        // pricePerYt = 0.05 quote per YT = 5e16
        vm.startPrank(maker);
        quoteToken.approve(address(diamond), 10e18);
        uint256 orderId = orderbook().placeBuyOrder(poolId, 100e18, 5e16, 0);
        vm.stopPrank();

        // Transfer YT to taker
        vm.prank(maker);
        IERC20(ytToken).transfer(taker, 50e18);

        vm.startPrank(taker);
        IERC20(ytToken).approve(address(diamond), 50e18);
        orderbook().fillBuyOrder(orderId, 50e18);
        vm.stopPrank();

        YTOrderbookFacet.Order memory order = orderbook().getOrder(orderId);
        assertTrue(order.isActive);
        assertEq(order.filledAmount, 50e18);

        // Escrow reduced
        // Original: 100e18 * 5e16 / 1e18 = 5e18
        // Used: 50e18 * 5e16 / 1e18 = 2.5e18
        uint256 originalEscrow = 5e18;
        uint256 usedEscrow = 25e17; // 2.5e18
        assertEq(
            orderbook().getOrderEscrow(orderId),
            originalEscrow - usedEscrow
        );
    }

    // ================================================================
    //                  CANCEL ORDER TESTS
    // ================================================================

    function test_CancelSellOrder_Success() public {
        _createCycleWithYT();
        address ytToken = _getYtToken();

        vm.startPrank(maker);
        IERC20(ytToken).approve(address(diamond), 100e18);
        uint256 orderId = orderbook().placeSellOrder(poolId, 100e18, 200, 0);

        orderbook().cancelOrder(orderId);
        vm.stopPrank();

        YTOrderbookFacet.Order memory order = orderbook().getOrder(orderId);
        assertFalse(order.isActive);
    }

    function test_CancelBuyOrder_ReturnsEscrow() public {
        _createCycleWithYT();

        uint256 balanceBefore = quoteToken.balanceOf(maker);

        vm.startPrank(maker);
        quoteToken.approve(address(diamond), 10e18);
        uint256 orderId = orderbook().placeBuyOrder(poolId, 100e18, 300, 0);

        uint256 balanceAfterPlace = quoteToken.balanceOf(maker);
        uint256 escrowed = balanceBefore - balanceAfterPlace;

        orderbook().cancelOrder(orderId);
        vm.stopPrank();

        // Escrow returned
        assertEq(quoteToken.balanceOf(maker), balanceAfterPlace + escrowed);
        assertEq(orderbook().getOrderEscrow(orderId), 0);
    }

    function test_CancelOrder_RevertsForNonMaker() public {
        _createCycleWithYT();
        address ytToken = _getYtToken();

        vm.startPrank(maker);
        IERC20(ytToken).approve(address(diamond), 100e18);
        uint256 orderId = orderbook().placeSellOrder(poolId, 100e18, 200, 0);
        vm.stopPrank();

        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSelector(
                YTOrderbookFacet.NotOrderMaker.selector,
                orderId,
                taker
            )
        );
        orderbook().cancelOrder(orderId);
    }

    function test_CancelOrder_RevertsForInactiveOrder() public {
        _createCycleWithYT();
        address ytToken = _getYtToken();

        vm.startPrank(maker);
        IERC20(ytToken).approve(address(diamond), 100e18);
        uint256 orderId = orderbook().placeSellOrder(poolId, 100e18, 200, 0);
        orderbook().cancelOrder(orderId);

        // Try to cancel again
        vm.expectRevert(
            abi.encodeWithSelector(
                YTOrderbookFacet.OrderNotActive.selector,
                orderId
            )
        );
        orderbook().cancelOrder(orderId);
        vm.stopPrank();
    }

    // ================================================================
    //                  VIEW FUNCTIONS TESTS
    // ================================================================

    function test_GetActiveOrders_ReturnsOnlyActive() public {
        _createCycleWithYT();
        address ytToken = _getYtToken();

        vm.startPrank(maker);
        IERC20(ytToken).approve(address(diamond), 300e18);

        // Place 3 orders
        orderbook().placeSellOrder(poolId, 100e18, 200, 0);
        orderbook().placeSellOrder(poolId, 100e18, 300, 0);
        orderbook().placeSellOrder(poolId, 100e18, 400, 0);

        // Cancel order 2
        orderbook().cancelOrder(2);
        vm.stopPrank();

        YTOrderbookFacet.Order[] memory activeOrders = orderbook()
            .getActiveOrders(poolId);
        assertEq(activeOrders.length, 2);
        assertEq(activeOrders[0].id, 1);
        assertEq(activeOrders[1].id, 3);
    }

    function test_GetActiveOrders_ExcludesExpired() public {
        _createCycleWithYT();
        address ytToken = _getYtToken();

        vm.startPrank(maker);
        IERC20(ytToken).approve(address(diamond), 200e18);

        orderbook().placeSellOrder(poolId, 100e18, 200, 1 hours); // short TTL
        orderbook().placeSellOrder(poolId, 100e18, 300, 7 days); // normal TTL
        vm.stopPrank();

        // Fast forward past first order's expiry
        vm.warp(block.timestamp + 2 hours);

        YTOrderbookFacet.Order[] memory activeOrders = orderbook()
            .getActiveOrders(poolId);
        assertEq(activeOrders.length, 1);
        assertEq(activeOrders[0].id, 2);
    }

    // ================================================================
    //                  EDGE CASES
    // ================================================================

    function test_MultiplePartialFills() public {
        _createCycleWithYT();
        address ytToken = _getYtToken();

        vm.startPrank(maker);
        IERC20(ytToken).approve(address(diamond), 100e18);
        uint256 orderId = orderbook().placeSellOrder(poolId, 100e18, 200, 0);
        vm.stopPrank();

        // First partial fill
        vm.startPrank(taker);
        quoteToken.approve(address(diamond), 10e18);
        orderbook().fillSellOrder(orderId, 25e18);
        vm.stopPrank();

        YTOrderbookFacet.Order memory order = orderbook().getOrder(orderId);
        assertTrue(order.isActive);
        assertEq(order.filledAmount, 25e18);

        // Second partial fill
        vm.startPrank(taker);
        orderbook().fillSellOrder(orderId, 25e18);
        vm.stopPrank();

        order = orderbook().getOrder(orderId);
        assertTrue(order.isActive);
        assertEq(order.filledAmount, 50e18);

        // Complete fill
        vm.startPrank(taker);
        orderbook().fillSellOrder(orderId, 50e18);
        vm.stopPrank();

        order = orderbook().getOrder(orderId);
        assertFalse(order.isActive);
        assertEq(order.filledAmount, 100e18);
    }

    function test_OrderIdIncrementsAcrossTypes() public {
        _createCycleWithYT();
        address ytToken = _getYtToken();

        vm.startPrank(maker);
        IERC20(ytToken).approve(address(diamond), 100e18);
        quoteToken.approve(address(diamond), 100e18);

        uint256 id1 = orderbook().placeSellOrder(poolId, 50e18, 200, 0);
        uint256 id2 = orderbook().placeBuyOrder(poolId, 50e18, 300, 0);
        uint256 id3 = orderbook().placeSellOrder(poolId, 50e18, 400, 0);

        vm.stopPrank();

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(id3, 3);
    }

    // ================================================================
    //                  NEW VALIDATION TESTS
    // ================================================================

    function test_FillSellOrder_RevertsOnSelfFill() public {
        _createCycleWithYT();
        address ytToken = _getYtToken();

        vm.startPrank(maker);
        IERC20(ytToken).approve(address(diamond), 100e18);
        uint256 orderId = orderbook().placeSellOrder(poolId, 100e18, 200, 0);

        quoteToken.approve(address(diamond), 10e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                YTOrderbookFacet.CannotFillOwnOrder.selector,
                orderId
            )
        );
        orderbook().fillSellOrder(orderId, 50e18);
        vm.stopPrank();
    }

    function test_FillBuyOrder_RevertsOnSelfFill() public {
        _createCycleWithYT();
        address ytToken = _getYtToken();

        vm.startPrank(maker);
        quoteToken.approve(address(diamond), 10e18);
        uint256 orderId = orderbook().placeBuyOrder(poolId, 100e18, 300, 0);

        IERC20(ytToken).approve(address(diamond), 100e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                YTOrderbookFacet.CannotFillOwnOrder.selector,
                orderId
            )
        );
        orderbook().fillBuyOrder(orderId, 50e18);
        vm.stopPrank();
    }

    function test_FillSellOrder_RevertsOnZeroQuoteAmount() public {
        _createCycleWithYT();
        address ytToken = _getYtToken();

        // Create order with very low price (1e14 = 0.0001 quote per YT)
        vm.startPrank(maker);
        IERC20(ytToken).approve(address(diamond), 100e18);
        uint256 orderId = orderbook().placeSellOrder(poolId, 100e18, 1e14, 0);
        vm.stopPrank();

        // Try to fill with amount that results in 0 quote
        // 9999 * 1e14 / 1e18 = 0 (integer division)
        vm.startPrank(taker);
        quoteToken.approve(address(diamond), 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                YTOrderbookFacet.QuoteAmountTooSmall.selector,
                9999, // fillAmount
                1e14 // pricePerYt
            )
        );
        orderbook().fillSellOrder(orderId, 9999);
        vm.stopPrank();
    }

    function test_FillSellOrder_RevertsOnCycleMatured() public {
        _createCycleWithYT();
        address ytToken = _getYtToken();

        vm.startPrank(maker);
        IERC20(ytToken).approve(address(diamond), 100e18);
        // Use long TTL so order doesn't expire before maturity
        uint256 orderId = orderbook().placeSellOrder(
            poolId,
            100e18,
            200,
            100 days
        );
        vm.stopPrank();

        // Fast forward past maturity (90 days default)
        vm.warp(block.timestamp + 91 days);

        vm.startPrank(taker);
        quoteToken.approve(address(diamond), 10e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                YTOrderbookFacet.CycleMatured.selector,
                poolId,
                1 // cycleId
            )
        );
        orderbook().fillSellOrder(orderId, 50e18);
        vm.stopPrank();
    }

    function test_FillBuyOrder_RevertsOnCycleMatured() public {
        _createCycleWithYT();
        address ytToken = _getYtToken();

        vm.startPrank(maker);
        quoteToken.approve(address(diamond), 10e18);
        // Use long TTL so order doesn't expire before maturity
        uint256 orderId = orderbook().placeBuyOrder(
            poolId,
            100e18,
            300,
            100 days
        );
        vm.stopPrank();

        // Transfer YT to taker
        vm.prank(maker);
        IERC20(ytToken).transfer(taker, 100e18);

        // Fast forward past maturity
        vm.warp(block.timestamp + 91 days);

        vm.startPrank(taker);
        IERC20(ytToken).approve(address(diamond), 100e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                YTOrderbookFacet.CycleMatured.selector,
                poolId,
                1
            )
        );
        orderbook().fillBuyOrder(orderId, 50e18);
        vm.stopPrank();
    }

    // ================================================================
    //                  ORDERBOOK SUMMARY TESTS
    // ================================================================

    function test_GetOrderbookSummary_Empty() public {
        _createCycleWithYT();

        (
            uint256 sellCount,
            uint256 buyCount,
            uint256 bestSell,
            uint256 bestBuy,
            uint256 sellVol,
            uint256 buyVol
        ) = orderbook().getOrderbookSummary(poolId);

        assertEq(sellCount, 0);
        assertEq(buyCount, 0);
        assertEq(bestSell, 0);
        assertEq(bestBuy, 0);
        assertEq(sellVol, 0);
        assertEq(buyVol, 0);
    }

    function test_GetOrderbookSummary_WithOrders() public {
        _createCycleWithYT();
        address ytToken = _getYtToken();

        vm.startPrank(maker);
        IERC20(ytToken).approve(address(diamond), 300e18);
        quoteToken.approve(address(diamond), 100e18);

        // Place sell orders at different prices
        orderbook().placeSellOrder(poolId, 100e18, 200, 0); // 2% - best ask
        orderbook().placeSellOrder(poolId, 50e18, 300, 0); // 3%

        // Place buy orders
        orderbook().placeBuyOrder(poolId, 80e18, 150, 0); // 1.5%
        orderbook().placeBuyOrder(poolId, 60e18, 100, 0); // 1% - best bid
        vm.stopPrank();

        (
            uint256 sellCount,
            uint256 buyCount,
            uint256 bestSell,
            uint256 bestBuy,
            uint256 sellVol,
            uint256 buyVol
        ) = orderbook().getOrderbookSummary(poolId);

        assertEq(sellCount, 2);
        assertEq(buyCount, 2);
        assertEq(bestSell, 200); // Lowest sell price
        assertEq(bestBuy, 150); // Highest buy price
        assertEq(sellVol, 150e18); // 100 + 50
        assertEq(buyVol, 140e18); // 80 + 60
    }

    function test_GetOrderbookSummary_ExcludesExpiredAndCancelled() public {
        _createCycleWithYT();
        address ytToken = _getYtToken();

        vm.startPrank(maker);
        IERC20(ytToken).approve(address(diamond), 200e18);

        orderbook().placeSellOrder(poolId, 100e18, 200, 1 hours); // Will expire
        orderbook().placeSellOrder(poolId, 100e18, 300, 7 days); // Will stay

        // Cancel first order doesn't matter, we expire it instead
        vm.stopPrank();

        // Fast forward past first order's expiry
        vm.warp(block.timestamp + 2 hours);

        (
            uint256 sellCount,
            ,
            uint256 bestSell,
            ,
            uint256 sellVol,

        ) = orderbook().getOrderbookSummary(poolId);

        assertEq(sellCount, 1);
        assertEq(bestSell, 300);
        assertEq(sellVol, 100e18);
    }
}

// ================================================================
//                     MOCK CONTRACTS
// ================================================================

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract MockOrderbookAdapter is ILiquidityAdapter {
    address public token0;
    address public token1;
    address public diamond;

    constructor(address _token0, address _token1, address _diamond) {
        token0 = _token0;
        token1 = _token1;
        diamond = _diamond;
    }

    function addLiquidity(
        bytes calldata
    )
        external
        override
        returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
    {
        // Simplified mock: just transfer fixed amounts
        amount0Used = 10_000e18;
        amount1Used = 10_000e18;
        liquidity = uint128(amount0Used + amount1Used);

        IERC20(token0).transferFrom(msg.sender, address(this), amount0Used);
        IERC20(token1).transferFrom(msg.sender, address(this), amount1Used);
    }

    function removeLiquidity(
        uint128,
        bytes calldata
    ) external pure override returns (uint256, uint256) {
        return (0, 0);
    }

    function collectYield(
        bytes calldata
    ) external pure override returns (uint256, uint256) {
        return (0, 0);
    }

    function getPoolTokens(
        bytes calldata
    ) external view override returns (address, address) {
        return (token0, token1);
    }

    function supportsPool(
        bytes calldata
    ) external pure override returns (bool) {
        return true;
    }

    function previewRemoveLiquidity(
        uint128,
        bytes calldata
    ) external pure override returns (uint256, uint256) {
        return (0, 0);
    }

    function getPositionLiquidity(
        bytes calldata
    ) external pure override returns (uint128) {
        return 0;
    }

    function protocolId() external pure override returns (string memory) {
        return "MOCK";
    }

    function protocolAddress() external view override returns (address) {
        return address(this);
    }

    function previewAddLiquidity(
        bytes calldata
    ) external pure override returns (uint128, uint256, uint256) {
        return (0, 0, 0);
    }

    function calculateOptimalAmount1(
        uint256,
        bytes calldata
    ) external pure override returns (uint256) {
        return 0;
    }

    function calculateOptimalAmount0(
        uint256,
        bytes calldata
    ) external pure override returns (uint256) {
        return 0;
    }

    function getPoolPrice(
        bytes calldata
    ) external pure override returns (uint160, int24) {
        return (0, 0);
    }

    function getPoolFee(
        bytes calldata
    ) external pure override returns (uint24) {
        return 0;
    }

    function getPositionValue(
        bytes calldata
    ) external pure override returns (uint256, uint256) {
        return (0, 0);
    }

    function getPoolTotalValue(
        bytes calldata
    ) external pure override returns (uint256, uint256) {
        return (0, 0);
    }
}
