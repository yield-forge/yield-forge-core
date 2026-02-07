// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Diamond} from "../src/Diamond.sol";
import {DiamondCutFacet} from "../src/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../src/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {PoolRegistryFacet} from "../src/facets/PoolRegistryFacet.sol";
import {LiquidityFacet} from "../src/facets/LiquidityFacet.sol";
import {YieldAccumulatorFacet} from "../src/facets/YieldAccumulatorFacet.sol";
import {RedemptionFacet} from "../src/facets/RedemptionFacet.sol";
import {YieldForgeMarketFacet} from "../src/facets/YieldForgeMarketFacet.sol";
import {PauseFacet} from "../src/facets/PauseFacet.sol";
import {LibAppStorage} from "../src/libraries/LibAppStorage.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {IERC165} from "../src/interfaces/IERC165.sol";
import {IERC173} from "../src/interfaces/IERC173.sol";
import {ILiquidityAdapter} from "../src/interfaces/ILiquidityAdapter.sol";
import {PrincipalToken} from "../src/tokens/PrincipalToken.sol";
import {YieldToken} from "../src/tokens/YieldToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title IntegrationTest
 * @notice End-to-end tests for full protocol lifecycle
 * @dev Tests complete user flows across multiple facets
 */
contract IntegrationTest is Test {
    Diamond diamond;
    DiamondCutFacet diamondCutFacet;
    DiamondLoupeFacet diamondLoupeFacet;
    OwnershipFacet ownershipFacet;
    PoolRegistryFacet poolRegistryFacet;
    LiquidityFacet liquidityFacet;
    YieldAccumulatorFacet yieldAccumulatorFacet;
    RedemptionFacet redemptionFacet;
    YieldForgeMarketFacet yieldForgeMarketFacet;
    PauseFacet pauseFacet;

    MockIntegrationAdapter mockAdapter;
    MockERC20I token0;
    MockERC20I token1;

    address owner = address(this);
    address user1 = address(0x1);
    address user2 = address(0x2);
    address treasury = address(0x3);

    bytes32 poolId;

    function setUp() public {
        // Deploy mock tokens
        token0 = new MockERC20I("USD Coin", "USDC");
        token1 = new MockERC20I("Wrapped ETH", "WETH");

        // Deploy Diamond with all facets
        _deployDiamond();

        // Deploy mock adapter
        mockAdapter = new MockIntegrationAdapter(address(token0), address(token1), address(diamond));

        // Setup protocol
        _setupProtocol();
    }

    function _deployDiamond() internal {
        diamondCutFacet = new DiamondCutFacet();
        diamond = new Diamond(owner, address(diamondCutFacet));
        diamondLoupeFacet = new DiamondLoupeFacet();
        ownershipFacet = new OwnershipFacet();
        poolRegistryFacet = new PoolRegistryFacet();
        liquidityFacet = new LiquidityFacet();
        yieldAccumulatorFacet = new YieldAccumulatorFacet();
        redemptionFacet = new RedemptionFacet();
        yieldForgeMarketFacet = new YieldForgeMarketFacet();
        pauseFacet = new PauseFacet();

        _addFacets();
    }

    function _addFacets() internal {
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](9);

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
        bytes4[] memory registrySelectors = new bytes4[](8);
        registrySelectors[0] = PoolRegistryFacet.initialize.selector;
        registrySelectors[1] = PoolRegistryFacet.approveAdapter.selector;
        registrySelectors[2] = PoolRegistryFacet.approveQuoteToken.selector;
        registrySelectors[3] = PoolRegistryFacet.registerPool.selector;
        registrySelectors[4] = PoolRegistryFacet.getCurrentCycleId.selector;
        registrySelectors[5] = PoolRegistryFacet.getCycleInfo.selector;
        registrySelectors[6] = PoolRegistryFacet.banPool.selector;
        registrySelectors[7] = PoolRegistryFacet.getPoolInfo.selector;
        cut[2] = IDiamondCut.FacetCut({
            facetAddress: address(poolRegistryFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: registrySelectors
        });

        // LiquidityFacet
        bytes4[] memory liquiditySelectors = new bytes4[](2);
        liquiditySelectors[0] = LiquidityFacet.addLiquidity.selector;
        liquiditySelectors[1] = LiquidityFacet.timeToMaturity.selector;
        cut[3] = IDiamondCut.FacetCut({
            facetAddress: address(liquidityFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: liquiditySelectors
        });

        // YieldAccumulatorFacet
        bytes4[] memory yieldSelectors = new bytes4[](4);
        yieldSelectors[0] = YieldAccumulatorFacet.syncCheckpoint.selector;
        yieldSelectors[1] = YieldAccumulatorFacet.harvestYield.selector;
        yieldSelectors[2] = YieldAccumulatorFacet.claimYield.selector;
        yieldSelectors[3] = YieldAccumulatorFacet.getPendingYield.selector;
        cut[4] = IDiamondCut.FacetCut({
            facetAddress: address(yieldAccumulatorFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: yieldSelectors
        });

        // RedemptionFacet
        bytes4[] memory redemptionSelectors = new bytes4[](3);
        redemptionSelectors[0] = RedemptionFacet.redeemPT.selector;
        redemptionSelectors[1] = RedemptionFacet.hasMatured.selector;
        redemptionSelectors[2] = RedemptionFacet.previewRedemption.selector;
        cut[5] = IDiamondCut.FacetCut({
            facetAddress: address(redemptionFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: redemptionSelectors
        });

        // YieldForgeMarketFacet
        bytes4[] memory marketSelectors = new bytes4[](6);
        marketSelectors[0] = YieldForgeMarketFacet.addYieldForgeLiquidity.selector;
        marketSelectors[1] = YieldForgeMarketFacet.swapExactQuoteForPT.selector;
        marketSelectors[2] = YieldForgeMarketFacet.swapExactPTForQuote.selector;
        marketSelectors[3] = YieldForgeMarketFacet.getYieldForgeMarketInfo.selector;
        marketSelectors[4] = YieldForgeMarketFacet.getPtPrice.selector;
        marketSelectors[5] = YieldForgeMarketFacet.removeYieldForgeLiquidity.selector;
        cut[6] = IDiamondCut.FacetCut({
            facetAddress: address(yieldForgeMarketFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: marketSelectors
        });

        // PauseFacet
        bytes4[] memory pauseSelectors = new bytes4[](2);
        pauseSelectors[0] = PauseFacet.pause.selector;
        pauseSelectors[1] = PauseFacet.paused.selector;
        cut[7] = IDiamondCut.FacetCut({
            facetAddress: address(pauseFacet), action: IDiamondCut.FacetCutAction.Add, functionSelectors: pauseSelectors
        });

        // Empty cut for 9th slot
        bytes4[] memory emptySelectors = new bytes4[](0);
        cut[8] = IDiamondCut.FacetCut({
            facetAddress: address(0), action: IDiamondCut.FacetCutAction.Add, functionSelectors: emptySelectors
        });

        // Resize array to remove empty cut
        IDiamondCut.FacetCut[] memory finalCut = new IDiamondCut.FacetCut[](8);
        for (uint256 i = 0; i < 8; i++) {
            finalCut[i] = cut[i];
        }

        IDiamondCut(address(diamond)).diamondCut(finalCut, address(0), "");
    }

    function _setupProtocol() internal {
        // Initialize protocol
        PoolRegistryFacet(address(diamond)).initialize(treasury);

        // Approve adapter and quote token
        PoolRegistryFacet(address(diamond)).approveAdapter(address(mockAdapter));
        PoolRegistryFacet(address(diamond)).approveQuoteToken(address(token0));

        // Register pool
        bytes memory poolParams = abi.encode(address(0xB001));
        poolId = PoolRegistryFacet(address(diamond)).registerPool(address(mockAdapter), poolParams, address(token0));

        // Mint tokens to users
        token0.mint(user1, 100000e18);
        token1.mint(user1, 100000e18);
        token0.mint(user2, 100000e18);
        token1.mint(user2, 100000e18);
    }

    // ================================================================
    //                 FULL LIFECYCLE INTEGRATION TESTS
    // ================================================================

    /**
     * @notice Test complete lifecycle: add liquidity → maturity → redeem
     */
    function test_FullLifecycle_AddLiquidityThenRedeem() public {
        // Step 1: User adds liquidity
        vm.startPrank(user1);
        token0.approve(address(diamond), 1000e18);
        token1.approve(address(diamond), 1000e18);

        (uint256 liquidity, uint256 ptAmount, uint256 ytAmount) =
            LiquidityFacet(address(diamond)).addLiquidity(poolId, 1000e18, 1000e18);
        vm.stopPrank();

        // Verify PT/YT minted
        assertGt(ptAmount, 0, "PT amount should be > 0");
        assertEq(ptAmount, ytAmount, "PT and YT should be equal");

        // Step 2: Time passes to maturity
        LibAppStorage.CycleInfo memory cycleInfo = PoolRegistryFacet(address(diamond)).getCycleInfo(poolId, 1);
        vm.warp(cycleInfo.maturityDate + 1);

        // Step 3: User redeems PT
        PrincipalToken pt = PrincipalToken(cycleInfo.ptToken);
        uint256 ptBalance = pt.balanceOf(user1);

        // Mint tokens to adapter to simulate redemption returns
        token0.mint(address(mockAdapter), 1000e18);
        token1.mint(address(mockAdapter), 1000e18);

        vm.prank(user1);
        (uint256 amount0, uint256 amount1) =
            RedemptionFacet(address(diamond))
                .redeemPT(
                    poolId,
                    1,
                    ptBalance,
                    1000 // 10% max slippage
                );

        // Verify redemption
        assertGt(amount0 + amount1, 0, "Should receive tokens on redemption");
        assertEq(pt.balanceOf(user1), 0, "All PT should be burned");
    }

    /**
     * @notice Test multi-user liquidity with yield distribution
     */
    function test_MultiUser_YieldDistribution() public {
        // User1 adds liquidity
        vm.startPrank(user1);
        token0.approve(address(diamond), 1000e18);
        token1.approve(address(diamond), 1000e18);
        LiquidityFacet(address(diamond)).addLiquidity(poolId, 1000e18, 1000e18);
        vm.stopPrank();

        // User2 adds liquidity
        vm.startPrank(user2);
        token0.approve(address(diamond), 1000e18);
        token1.approve(address(diamond), 1000e18);
        LiquidityFacet(address(diamond)).addLiquidity(poolId, 1000e18, 1000e18);
        vm.stopPrank();

        // Simulate yield in adapter
        mockAdapter.setYield(100e18, 50e18);

        // Harvest yield
        YieldAccumulatorFacet(address(diamond)).harvestYield(poolId);

        // Get cycle info for YT token
        LibAppStorage.CycleInfo memory cycleInfo = PoolRegistryFacet(address(diamond)).getCycleInfo(poolId, 1);
        YieldToken yt = YieldToken(cycleInfo.ytToken);

        // Check pending yield for both users
        (uint256 pending0User1, uint256 pending1User1) =
            YieldAccumulatorFacet(address(diamond)).getPendingYield(poolId, 1, user1);
        (uint256 pending0User2, uint256 pending1User2) =
            YieldAccumulatorFacet(address(diamond)).getPendingYield(poolId, 1, user2);

        // Both users should have pending yield (proportional to YT holdings)
        assertGt(pending0User1 + pending1User1, 0, "User1 should have pending yield");
        assertGt(pending0User2 + pending1User2, 0, "User2 should have pending yield");
    }

    /**
     * @notice Test secondary market trading flow
     */
    function test_SecondaryMarket_Trading() public {
        // Step 1: User adds liquidity
        vm.startPrank(user1);
        token0.approve(address(diamond), 1000e18);
        token1.approve(address(diamond), 1000e18);
        LiquidityFacet(address(diamond)).addLiquidity(poolId, 1000e18, 1000e18);
        vm.stopPrank();

        // Step 2: Activate secondary market with PT
        LibAppStorage.CycleInfo memory cycleInfo = PoolRegistryFacet(address(diamond)).getCycleInfo(poolId, 1);
        PrincipalToken pt = PrincipalToken(cycleInfo.ptToken);
        uint256 ptBalance = pt.balanceOf(user1);

        vm.startPrank(user1);
        pt.approve(address(diamond), ptBalance / 2);
        uint256 lpTokens = YieldForgeMarketFacet(address(diamond))
            .addYieldForgeLiquidity(
                poolId,
                ptBalance / 2,
                500 // 5% discount
            );
        vm.stopPrank();

        // Verify market activated
        (LibAppStorage.YieldForgeMarketStatus status,,,,,,) =
            YieldForgeMarketFacet(address(diamond)).getYieldForgeMarketInfo(poolId);
        assertEq(uint256(status), uint256(LibAppStorage.YieldForgeMarketStatus.ACTIVE), "Market should be active");
        assertGt(lpTokens, 0, "LP tokens should be minted");

        // Step 3: User2 buys PT with quote token
        uint256 quoteAmount = 100e18;
        token0.mint(address(diamond), 1000e18); // Mint for swap output

        vm.startPrank(user2);
        token0.approve(address(diamond), quoteAmount);
        uint256 ptReceived = YieldForgeMarketFacet(address(diamond))
            .swapExactQuoteForPT(
                poolId,
                quoteAmount,
                0 // no min out for test
            );
        vm.stopPrank();

        // Verify PT received
        assertGt(ptReceived, 0, "Should receive PT from swap");
        assertGt(pt.balanceOf(user2), 0, "User2 should have PT");
    }

    /**
     * @notice Test pause mechanism affects all operations
     */
    function test_PauseBlocksAllOperations() public {
        // Pause protocol
        PauseFacet(address(diamond)).pause();

        // Try to add liquidity - should fail
        vm.startPrank(user1);
        token0.approve(address(diamond), 1000e18);
        token1.approve(address(diamond), 1000e18);

        vm.expectRevert();
        LiquidityFacet(address(diamond)).addLiquidity(poolId, 1000e18, 1000e18);
        vm.stopPrank();
    }

    /**
     * @notice Test cycle transition after maturity
     */
    function test_CycleTransition_NewCycleAfterMaturity() public {
        // Cycle 1: Add liquidity
        vm.startPrank(user1);
        token0.approve(address(diamond), 2000e18);
        token1.approve(address(diamond), 2000e18);
        LiquidityFacet(address(diamond)).addLiquidity(poolId, 1000e18, 1000e18);
        vm.stopPrank();

        // Get cycle 1 info
        uint256 cycle1Id = PoolRegistryFacet(address(diamond)).getCurrentCycleId(poolId);
        LibAppStorage.CycleInfo memory cycle1Info = PoolRegistryFacet(address(diamond)).getCycleInfo(poolId, cycle1Id);
        assertEq(cycle1Id, 1, "Should be cycle 1");

        // Warp past maturity
        vm.warp(cycle1Info.maturityDate + 1);

        // Add liquidity again - should create cycle 2
        vm.startPrank(user1);
        LiquidityFacet(address(diamond)).addLiquidity(poolId, 1000e18, 1000e18);
        vm.stopPrank();

        // Verify new cycle created
        uint256 cycle2Id = PoolRegistryFacet(address(diamond)).getCurrentCycleId(poolId);
        assertEq(cycle2Id, 2, "Should be cycle 2");

        // Cycle 1 PT should still be redeemable
        PrincipalToken pt1 = PrincipalToken(cycle1Info.ptToken);
        assertGt(pt1.balanceOf(user1), 0, "User should still have cycle 1 PT");
    }
}

// ================================================================
//                     MOCK CONTRACTS
// ================================================================

contract MockERC20I is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockIntegrationAdapter is ILiquidityAdapter {
    address public immutable token0;
    address public immutable token1;
    address public immutable diamond;

    uint256 public yield0;
    uint256 public yield1;

    constructor(address _token0, address _token1, address _diamond) {
        token0 = _token0;
        token1 = _token1;
        diamond = _diamond;
    }

    function setYield(uint256 _yield0, uint256 _yield1) external {
        yield0 = _yield0;
        yield1 = _yield1;
    }

    function addLiquidity(bytes calldata params)
        external
        override
        returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
    {
        // Params are bytes.concat(poolParams, abi.encode(amount0, amount1))
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

    function removeLiquidity(uint128 liquidity, bytes calldata)
        external
        override
        returns (uint256 amount0, uint256 amount1)
    {
        amount0 = uint256(liquidity);
        amount1 = uint256(liquidity);

        // Transfer tokens back
        if (IERC20(token0).balanceOf(address(this)) >= amount0) {
            IERC20(token0).transfer(diamond, amount0);
        }
        if (IERC20(token1).balanceOf(address(this)) >= amount1) {
            IERC20(token1).transfer(diamond, amount1);
        }

        return (amount0, amount1);
    }

    function collectYield(bytes calldata) external override returns (uint256, uint256) {
        uint256 y0 = yield0;
        uint256 y1 = yield1;
        yield0 = 0;
        yield1 = 0;
        return (y0, y1);
    }

    function getPoolTokens(bytes calldata) external view override returns (address, address) {
        return (token0, token1);
    }

    function supportsPool(bytes calldata) external pure override returns (bool) {
        return true;
    }

    function previewRemoveLiquidity(uint128 liquidity, bytes calldata)
        external
        pure
        override
        returns (uint256, uint256)
    {
        return (uint256(liquidity), uint256(liquidity));
    }

    function getPositionLiquidity(bytes calldata) external pure override returns (uint128) {
        return 1000e18;
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
