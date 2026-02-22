// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Diamond} from "../src/Diamond.sol";
import {DiamondCutFacet} from "../src/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../src/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {PoolRegistryFacet} from "../src/facets/PoolRegistryFacet.sol";
import {LiquidityFacet} from "../src/facets/LiquidityFacet.sol";
import {PauseFacet} from "../src/facets/PauseFacet.sol";
import {YieldAccumulatorFacet} from "../src/facets/YieldAccumulatorFacet.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {IERC165} from "../src/interfaces/IERC165.sol";
import {IERC173} from "../src/interfaces/IERC173.sol";
import {ILiquidityAdapter} from "../src/interfaces/ILiquidityAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title LiquidityFacetTest
 * @notice Tests for LiquidityFacet core functionality
 */
contract LiquidityFacetTest is Test {
    Diamond diamond;
    DiamondCutFacet diamondCutFacet;
    DiamondLoupeFacet diamondLoupeFacet;
    OwnershipFacet ownershipFacet;
    PoolRegistryFacet poolRegistryFacet;
    LiquidityFacet liquidityFacet;
    PauseFacet pauseFacet;
    YieldAccumulatorFacet yieldAccumulatorFacet;

    MockAdapterWithLiquidity mockAdapter;
    MockERC20 token0;
    MockERC20 token1;

    address owner = address(this);
    address user = address(0x1);
    address treasury = address(0x3);

    bytes32 poolId;

    function setUp() public {
        // Deploy mock tokens
        token0 = new MockERC20("Token0", "TK0");
        token1 = new MockERC20("Token1", "TK1");

        // Deploy facets
        diamondCutFacet = new DiamondCutFacet();
        diamond = new Diamond(owner, address(diamondCutFacet));
        diamondLoupeFacet = new DiamondLoupeFacet();
        ownershipFacet = new OwnershipFacet();
        poolRegistryFacet = new PoolRegistryFacet();
        liquidityFacet = new LiquidityFacet();
        pauseFacet = new PauseFacet();
        yieldAccumulatorFacet = new YieldAccumulatorFacet();

        // Deploy mock adapter
        mockAdapter = new MockAdapterWithLiquidity(address(token0), address(token1), address(diamond));

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

        // PoolRegistryFacet (key selectors)
        bytes4[] memory registrySelectors = new bytes4[](10);
        registrySelectors[0] = PoolRegistryFacet.initialize.selector;
        registrySelectors[1] = PoolRegistryFacet.approveAdapter.selector;
        registrySelectors[2] = PoolRegistryFacet.approveQuoteToken.selector;
        registrySelectors[3] = PoolRegistryFacet.registerPool.selector;
        registrySelectors[4] = PoolRegistryFacet.banPool.selector;
        registrySelectors[5] = PoolRegistryFacet.poolExists.selector;
        registrySelectors[6] = PoolRegistryFacet.getPoolInfo.selector;
        registrySelectors[7] = PoolRegistryFacet.getCurrentCycleId.selector;
        registrySelectors[8] = PoolRegistryFacet.getCycleInfo.selector;
        registrySelectors[9] = PoolRegistryFacet.isPoolBanned.selector;
        cut[2] = IDiamondCut.FacetCut({
            facetAddress: address(poolRegistryFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: registrySelectors
        });

        // LiquidityFacet
        bytes4[] memory liquiditySelectors = new bytes4[](4);
        liquiditySelectors[0] = LiquidityFacet.addLiquidity.selector;
        liquiditySelectors[1] = LiquidityFacet.hasActiveCycle.selector;
        liquiditySelectors[2] = LiquidityFacet.timeToMaturity.selector;
        liquiditySelectors[3] = LiquidityFacet.getTotalLiquidity.selector;
        cut[3] = IDiamondCut.FacetCut({
            facetAddress: address(liquidityFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: liquiditySelectors
        });

        // PauseFacet
        bytes4[] memory pauseSelectors = new bytes4[](3);
        pauseSelectors[0] = PauseFacet.pause.selector;
        pauseSelectors[1] = PauseFacet.unpause.selector;
        pauseSelectors[2] = PauseFacet.paused.selector;
        cut[4] = IDiamondCut.FacetCut({
            facetAddress: address(pauseFacet), action: IDiamondCut.FacetCutAction.Add, functionSelectors: pauseSelectors
        });

        // YieldAccumulatorFacet (syncCheckpoint is called by YT token on mint)
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
        PoolRegistryFacet(address(diamond)).approveQuoteToken(address(token0));

        // Register pool
        bytes memory poolParams = abi.encode(address(0xB001));
        poolId = PoolRegistryFacet(address(diamond)).registerPool(address(mockAdapter), poolParams, address(token0));

        // Mint tokens to user
        token0.mint(user, 10000e18);
        token1.mint(user, 10000e18);
    }

    // Shorthand for facet calls
    function liquidity() internal view returns (LiquidityFacet) {
        return LiquidityFacet(address(diamond));
    }

    function pause() internal view returns (PauseFacet) {
        return PauseFacet(address(diamond));
    }

    function registry() internal view returns (PoolRegistryFacet) {
        return PoolRegistryFacet(address(diamond));
    }

    // ================================================================
    //                    VALIDATION TESTS
    // ================================================================

    function test_AddLiquidity_RevertsWhenPaused() public {
        pause().pause();

        vm.startPrank(user);
        token0.approve(address(diamond), 100e18);
        token1.approve(address(diamond), 100e18);

        vm.expectRevert(); // LibPause reverts
        liquidity().addLiquidity(poolId, 100e18, 100e18);
        vm.stopPrank();
    }

    function test_AddLiquidity_RevertsForNonExistentPool() public {
        bytes32 fakePoolId = keccak256("fake");

        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(LiquidityFacet.PoolDoesNotExist.selector, fakePoolId));
        liquidity().addLiquidity(fakePoolId, 100e18, 100e18);
        vm.stopPrank();
    }

    function test_AddLiquidity_RevertsForBannedPool() public {
        registry().banPool(poolId);

        vm.startPrank(user);
        token0.approve(address(diamond), 100e18);
        token1.approve(address(diamond), 100e18);

        vm.expectRevert(abi.encodeWithSelector(LiquidityFacet.PoolBanned.selector, poolId));
        liquidity().addLiquidity(poolId, 100e18, 100e18);
        vm.stopPrank();
    }

    function test_AddLiquidity_RevertsOnZeroAmounts() public {
        vm.startPrank(user);

        vm.expectRevert(LiquidityFacet.ZeroAmount.selector);
        liquidity().addLiquidity(poolId, 0, 0);
        vm.stopPrank();
    }

    // ================================================================
    //                    CORE FLOW TESTS
    // ================================================================

    function test_AddLiquidity_CreatesFirstCycle() public {
        // Before: no cycle
        assertEq(registry().getCurrentCycleId(poolId), 0);
        assertFalse(liquidity().hasActiveCycle(poolId));

        vm.startPrank(user);
        token0.approve(address(diamond), 100e18);
        token1.approve(address(diamond), 100e18);

        (uint256 liq, uint256 pt, uint256 yt) = liquidity().addLiquidity(poolId, 100e18, 100e18);
        vm.stopPrank();

        // After: cycle 1 created
        assertEq(registry().getCurrentCycleId(poolId), 1);
        assertTrue(liquidity().hasActiveCycle(poolId));
        assertGt(liq, 0);
        assertGt(pt, 0);
        assertGt(yt, 0);
    }

    function test_AddLiquidity_MintsPTAndYTToUser() public {
        vm.startPrank(user);
        token0.approve(address(diamond), 100e18);
        token1.approve(address(diamond), 100e18);

        (uint256 liq, uint256 ptAmount, uint256 ytAmount) = liquidity().addLiquidity(poolId, 100e18, 100e18);
        vm.stopPrank();

        // Get PT/YT addresses
        address ptToken = registry().getCycleInfo(poolId, 1).ptToken;
        address ytToken = registry().getCycleInfo(poolId, 1).ytToken;

        // User should hold PT and YT
        assertEq(IERC20(ptToken).balanceOf(user), ptAmount);
        assertEq(IERC20(ytToken).balanceOf(user), ytAmount);
        assertEq(ptAmount, liq);
        assertEq(ytAmount, liq);
    }

    function test_AddLiquidity_UpdatesTotalLiquidity() public {
        vm.startPrank(user);
        token0.approve(address(diamond), 200e18);
        token1.approve(address(diamond), 200e18);

        // First add
        (uint256 liq1,,) = liquidity().addLiquidity(poolId, 100e18, 100e18);

        // Second add
        (uint256 liq2,,) = liquidity().addLiquidity(poolId, 100e18, 100e18);
        vm.stopPrank();

        // Total liquidity should be sum
        uint128 total = liquidity().getTotalLiquidity(poolId);
        assertEq(total, liq1 + liq2);
    }

    function test_AddLiquidity_TransfersTokensFromUser() public {
        uint256 balanceBefore0 = token0.balanceOf(user);
        uint256 balanceBefore1 = token1.balanceOf(user);

        vm.startPrank(user);
        token0.approve(address(diamond), 100e18);
        token1.approve(address(diamond), 100e18);

        liquidity().addLiquidity(poolId, 100e18, 100e18);
        vm.stopPrank();

        // MockAdapter uses 50% of requested amounts
        assertEq(token0.balanceOf(user), balanceBefore0 - 50e18);
        assertEq(token1.balanceOf(user), balanceBefore1 - 50e18);
    }

    // ================================================================
    //                    VIEW FUNCTION TESTS
    // ================================================================

    function test_TimeToMaturity_Returns90Days() public {
        vm.startPrank(user);
        token0.approve(address(diamond), 100e18);
        token1.approve(address(diamond), 100e18);
        liquidity().addLiquidity(poolId, 100e18, 100e18);
        vm.stopPrank();

        uint256 ttm = liquidity().timeToMaturity(poolId);
        // Should be approximately 90 days
        assertGt(ttm, 89 days);
        assertLt(ttm, 91 days);
    }
}

// ================================================================
//                     MOCK CONTRACTS
// ================================================================

/**
 * @notice Simple ERC20 mock for testing
 */
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @notice Mock adapter that simulates liquidity operations
 */
contract MockAdapterWithLiquidity is ILiquidityAdapter {
    address public immutable token0;
    address public immutable token1;
    address public immutable diamond;

    constructor(address _token0, address _token1, address _diamond) {
        token0 = _token0;
        token1 = _token1;
        diamond = _diamond;
    }

    function addLiquidity(bytes calldata, uint256 amount0, uint256 amount1)
        external
        override
        returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
    {
        // Simulate using 50% of provided amounts
        amount0Used = amount0 / 2;
        amount1Used = amount1 / 2;
        liquidity = uint128((amount0Used + amount1Used) / 2);

        // Transfer tokens from Diamond to adapter (simulating add to pool)
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
    function previewAddLiquidity(bytes calldata, uint256, uint256) external pure override returns (uint128, uint256, uint256) {
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
