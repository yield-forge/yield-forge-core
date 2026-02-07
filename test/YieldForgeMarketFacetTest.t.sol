// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Diamond} from "../src/Diamond.sol";
import {DiamondCutFacet} from "../src/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../src/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {PoolRegistryFacet} from "../src/facets/PoolRegistryFacet.sol";
import {LiquidityFacet} from "../src/facets/LiquidityFacet.sol";
import {YieldForgeMarketFacet} from "../src/facets/YieldForgeMarketFacet.sol";
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
 * @title YieldForgeMarketFacetTest
 * @notice Tests for internal AMM: liquidity, swaps, market status
 */
contract YieldForgeMarketFacetTest is Test {
    Diamond diamond;
    DiamondCutFacet diamondCutFacet;
    DiamondLoupeFacet diamondLoupeFacet;
    OwnershipFacet ownershipFacet;
    PoolRegistryFacet poolRegistryFacet;
    LiquidityFacet liquidityFacet;
    YieldForgeMarketFacet yieldForgeMarketFacet;
    YieldAccumulatorFacet yieldAccumulatorFacet;

    MockMarketAdapter mockAdapter;
    MockERC20M quoteToken; // e.g., USDC
    MockERC20M token1;

    address owner = address(this);
    address user = address(0x1);
    address lpProvider = address(0x2);
    address treasury = address(0x3);

    bytes32 poolId;

    function setUp() public {
        // Deploy mock tokens
        quoteToken = new MockERC20M("USDC", "USDC");
        token1 = new MockERC20M("Token1", "TK1");

        // Deploy facets
        diamondCutFacet = new DiamondCutFacet();
        diamond = new Diamond(owner, address(diamondCutFacet));
        diamondLoupeFacet = new DiamondLoupeFacet();
        ownershipFacet = new OwnershipFacet();
        poolRegistryFacet = new PoolRegistryFacet();
        liquidityFacet = new LiquidityFacet();
        yieldForgeMarketFacet = new YieldForgeMarketFacet();
        yieldAccumulatorFacet = new YieldAccumulatorFacet();

        // Deploy mock adapter
        mockAdapter = new MockMarketAdapter(address(quoteToken), address(token1), address(diamond));

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
        bytes4[] memory registrySelectors = new bytes4[](6);
        registrySelectors[0] = PoolRegistryFacet.initialize.selector;
        registrySelectors[1] = PoolRegistryFacet.approveAdapter.selector;
        registrySelectors[2] = PoolRegistryFacet.approveQuoteToken.selector;
        registrySelectors[3] = PoolRegistryFacet.registerPool.selector;
        registrySelectors[4] = PoolRegistryFacet.getCurrentCycleId.selector;
        registrySelectors[5] = PoolRegistryFacet.getCycleInfo.selector;
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

        // YieldForgeMarketFacet
        bytes4[] memory marketSelectors = new bytes4[](8);
        marketSelectors[0] = YieldForgeMarketFacet.addYieldForgeLiquidity.selector;
        marketSelectors[1] = YieldForgeMarketFacet.removeYieldForgeLiquidity.selector;
        marketSelectors[2] = YieldForgeMarketFacet.swapExactQuoteForPT.selector;
        marketSelectors[3] = YieldForgeMarketFacet.swapExactPTForQuote.selector;
        marketSelectors[4] = YieldForgeMarketFacet.getYieldForgeMarketInfo.selector;
        marketSelectors[5] = YieldForgeMarketFacet.getUserLpBalance.selector;
        marketSelectors[6] = YieldForgeMarketFacet.getPtPrice.selector;
        marketSelectors[7] = YieldForgeMarketFacet.getCurrentSwapFee.selector;
        cut[4] = IDiamondCut.FacetCut({
            facetAddress: address(yieldForgeMarketFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: marketSelectors
        });

        // YieldAccumulatorFacet (for syncCheckpoint during YT mint)
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
        PoolRegistryFacet(address(diamond)).approveAdapter(address(mockAdapter));
        PoolRegistryFacet(address(diamond)).approveQuoteToken(address(quoteToken));

        // Register pool
        bytes memory poolParams = abi.encode(address(0xB001));
        poolId = PoolRegistryFacet(address(diamond)).registerPool(address(mockAdapter), poolParams, address(quoteToken));

        // Mint tokens to users
        quoteToken.mint(user, 10000e18);
        token1.mint(user, 10000e18);
        quoteToken.mint(lpProvider, 10000e18);
        token1.mint(lpProvider, 10000e18);
    }

    // Shorthand functions
    function market() internal view returns (YieldForgeMarketFacet) {
        return YieldForgeMarketFacet(address(diamond));
    }

    function liquidity() internal view returns (LiquidityFacet) {
        return LiquidityFacet(address(diamond));
    }

    function registry() internal view returns (PoolRegistryFacet) {
        return PoolRegistryFacet(address(diamond));
    }

    // ================================================================
    //                        HELPERS
    // ================================================================

    function _createCycleWithLiquidity() internal {
        vm.startPrank(user);
        quoteToken.approve(address(diamond), 1000e18);
        token1.approve(address(diamond), 1000e18);
        liquidity().addLiquidity(poolId, 1000e18, 1000e18);
        vm.stopPrank();
    }

    function _activateMarket(uint256 ptAmount, uint256 discountBps) internal {
        _createCycleWithLiquidity();

        address ptToken = registry().getCycleInfo(poolId, 1).ptToken;

        vm.startPrank(lpProvider);
        // lpProvider needs PT tokens to add to market
        // We transfer PT from user who got them from addLiquidity
        vm.stopPrank();

        // Use user to add liquidity to market
        vm.startPrank(user);
        IERC20(ptToken).approve(address(diamond), ptAmount);
        market().addYieldForgeLiquidity(poolId, ptAmount, discountBps);
        vm.stopPrank();
    }

    // ================================================================
    //                    LIQUIDITY TESTS
    // ================================================================

    function test_AddYieldForgeLiquidity_FirstLPActivatesMarket() public {
        _createCycleWithLiquidity();

        address ptToken = registry().getCycleInfo(poolId, 1).ptToken;
        uint256 ptBalance = IERC20(ptToken).balanceOf(user);

        vm.startPrank(user);
        IERC20(ptToken).approve(address(diamond), ptBalance);

        uint256 lpTokens = market().addYieldForgeLiquidity(poolId, ptBalance, 500); // 5% discount
        vm.stopPrank();

        // Market should be active
        (LibAppStorage.YieldForgeMarketStatus status,,,,,,) = market().getYieldForgeMarketInfo(poolId);
        assertEq(uint256(status), uint256(LibAppStorage.YieldForgeMarketStatus.ACTIVE));
        assertGt(lpTokens, 0);
    }

    function test_AddYieldForgeLiquidity_RevertsZeroAmount() public {
        _createCycleWithLiquidity();

        vm.prank(user);
        vm.expectRevert(YieldForgeMarketFacet.ZeroAmount.selector);
        market().addYieldForgeLiquidity(poolId, 0, 500);
    }

    function test_AddYieldForgeLiquidity_RevertsInvalidDiscount() public {
        _createCycleWithLiquidity();

        address ptToken = registry().getCycleInfo(poolId, 1).ptToken;

        vm.startPrank(user);
        IERC20(ptToken).approve(address(diamond), 100e18);

        // Discount = 0 is invalid
        vm.expectRevert(abi.encodeWithSelector(YieldForgeMarketFacet.InvalidDiscount.selector, 0));
        market().addYieldForgeLiquidity(poolId, 100e18, 0);

        // Discount >= 10000 is invalid (100%)
        vm.expectRevert(abi.encodeWithSelector(YieldForgeMarketFacet.InvalidDiscount.selector, 10000));
        market().addYieldForgeLiquidity(poolId, 100e18, 10000);
        vm.stopPrank();
    }

    function test_RemoveYieldForgeLiquidity_ReturnsProportionalPT() public {
        _activateMarket(500e18, 500);

        uint256 lpBalance = market().getUserLpBalance(poolId, user);
        address ptToken = registry().getCycleInfo(poolId, 1).ptToken;
        uint256 ptBefore = IERC20(ptToken).balanceOf(user);

        vm.prank(user);
        (uint256 ptReturned,) = market().removeYieldForgeLiquidity(poolId, lpBalance / 2);

        assertGt(ptReturned, 0);
        assertEq(IERC20(ptToken).balanceOf(user), ptBefore + ptReturned);
        // Allow 1 wei rounding difference
        assertApproxEqAbs(market().getUserLpBalance(poolId, user), lpBalance / 2, 1);
    }

    // ================================================================
    //                    SWAP TESTS
    // ================================================================

    function test_SwapExactQuoteForPT_Success() public {
        _activateMarket(500e18, 500);

        address ptToken = registry().getCycleInfo(poolId, 1).ptToken;
        uint256 ptBefore = IERC20(ptToken).balanceOf(user);
        uint256 quoteBefore = quoteToken.balanceOf(user);

        vm.startPrank(user);
        quoteToken.approve(address(diamond), 100e18);

        // Mint quote to diamond for the swap output
        quoteToken.mint(address(diamond), 1000e18);

        uint256 ptOut = market().swapExactQuoteForPT(poolId, 100e18, 0);
        vm.stopPrank();

        assertGt(ptOut, 0);
        assertEq(IERC20(ptToken).balanceOf(user), ptBefore + ptOut);
        assertEq(quoteToken.balanceOf(user), quoteBefore - 100e18);
    }

    function test_SwapExactQuoteForPT_RevertsOnSlippage() public {
        _activateMarket(500e18, 500);

        vm.startPrank(user);
        quoteToken.approve(address(diamond), 100e18);

        // Request unreasonably high minimum
        vm.expectRevert();
        market().swapExactQuoteForPT(poolId, 100e18, 1000000e18);
        vm.stopPrank();
    }

    function test_SwapExactPTForQuote_Success() public {
        _activateMarket(500e18, 500);

        // User needs extra PT to swap
        _createCycleWithLiquidity(); // Creates more PT for user

        address ptToken = registry().getCycleInfo(poolId, 1).ptToken;

        // First, buy some PT with quote to create realQuoteReserve in the pool
        vm.startPrank(user);
        quoteToken.approve(address(diamond), 200e18);
        market().swapExactQuoteForPT(poolId, 200e18, 0);
        vm.stopPrank();

        // Now we can sell PT for quote (there's quote in the pool)
        uint256 quoteBefore = quoteToken.balanceOf(user);

        vm.startPrank(user);
        IERC20(ptToken).approve(address(diamond), 50e18);

        uint256 quoteOut = market().swapExactPTForQuote(poolId, 50e18, 0);
        vm.stopPrank();

        assertGt(quoteOut, 0);
        assertEq(quoteToken.balanceOf(user), quoteBefore + quoteOut);
    }

    // ================================================================
    //                    VIEW FUNCTION TESTS
    // ================================================================

    function test_GetPtPrice_ReturnsValidPrice() public {
        _activateMarket(500e18, 500);

        uint256 priceBps = market().getPtPrice(poolId);

        // With 5% discount, price should be ~9500 bps (0.95)
        assertGt(priceBps, 9000);
        assertLt(priceBps, 10000);
    }

    function test_GetCurrentSwapFee_ReturnsValidFee() public {
        _activateMarket(500e18, 500);

        uint256 feeBps = market().getCurrentSwapFee(poolId);

        // Fee should be reasonable (typically 10-50 bps)
        assertGt(feeBps, 0);
        assertLt(feeBps, 500);
    }
}

// ================================================================
//                     MOCK CONTRACTS
// ================================================================

contract MockERC20M is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockMarketAdapter is ILiquidityAdapter {
    address public immutable token0;
    address public immutable token1;
    address public immutable diamond;

    constructor(address _token0, address _token1, address _diamond) {
        token0 = _token0;
        token1 = _token1;
        diamond = _diamond;
    }

    function addLiquidity(bytes calldata params)
        external
        override
        returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
    {
        // Params are bytes.concat(poolParams, abi.encode(amount0, amount1))
        // amounts are the last 64 bytes
        uint256 amount0;
        uint256 amount1;
        assembly {
            let len := params.length
            amount1 := calldataload(add(params.offset, sub(len, 32)))
            amount0 := calldataload(add(params.offset, sub(len, 64)))
        }
        amount0Used = amount0 / 2;
        amount1Used = amount1 / 2;
        liquidity = uint128((amount0Used + amount1Used) / 2);

        IERC20(token0).transferFrom(msg.sender, address(this), amount0Used);
        IERC20(token1).transferFrom(msg.sender, address(this), amount1Used);

        return (liquidity, amount0Used, amount1Used);
    }

    function removeLiquidity(uint128, bytes calldata) external pure override returns (uint256, uint256) {
        return (0, 0);
    }

    function collectYield(bytes calldata) external pure override returns (uint256, uint256) {
        return (0, 0);
    }

    function getPoolTokens(bytes calldata) external view override returns (address, address) {
        return (token0, token1);
    }

    function supportsPool(bytes calldata) external pure override returns (bool) {
        return true;
    }

    function previewRemoveLiquidity(uint128, bytes calldata) external pure override returns (uint256, uint256) {
        return (0, 0);
    }

    function getPositionLiquidity(bytes calldata) external pure override returns (uint128) {
        return 0;
    }

    function protocolId() external pure override returns (string memory) {
        return "MOCK";
    }

    function protocolAddress() external view override returns (address) {
        return address(this);
    }

    // New interface stubs
    function previewAddLiquidity(bytes calldata) external pure override returns (uint128, uint256, uint256) {
        return (0, 0, 0);
    }

    function calculateOptimalAmount1(uint256, bytes calldata) external pure override returns (uint256) {
        return 0;
    }

    function calculateOptimalAmount0(uint256, bytes calldata) external pure override returns (uint256) {
        return 0;
    }

    function getPoolPrice(bytes calldata) external pure override returns (uint160, int24) {
        return (0, 0);
    }

    function getPoolFee(bytes calldata) external pure override returns (uint24) {
        return 0;
    }

    function getPositionValue(bytes calldata) external pure override returns (uint256, uint256) {
        return (0, 0);
    }

    function getPoolTotalValue(bytes calldata) external pure override returns (uint256, uint256) {
        return (0, 0);
    }
}
