// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Diamond} from "../src/Diamond.sol";
import {DiamondCutFacet} from "../src/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../src/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {PoolRegistryFacet} from "../src/facets/PoolRegistryFacet.sol";
import {LiquidityFacet} from "../src/facets/LiquidityFacet.sol";
import {RedemptionFacet} from "../src/facets/RedemptionFacet.sol";
import {YieldAccumulatorFacet} from "../src/facets/YieldAccumulatorFacet.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {IERC165} from "../src/interfaces/IERC165.sol";
import {IERC173} from "../src/interfaces/IERC173.sol";
import {ILiquidityAdapter} from "../src/interfaces/ILiquidityAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title RedemptionFacetTest
 * @notice Tests for PT redemption: maturity, proportional share, slippage
 */
contract RedemptionFacetTest is Test {
    Diamond diamond;
    DiamondCutFacet diamondCutFacet;
    DiamondLoupeFacet diamondLoupeFacet;
    OwnershipFacet ownershipFacet;
    PoolRegistryFacet poolRegistryFacet;
    LiquidityFacet liquidityFacet;
    RedemptionFacet redemptionFacet;
    YieldAccumulatorFacet yieldAccumulatorFacet;

    MockRedemptionAdapter mockAdapter;
    MockERC20R token0;
    MockERC20R token1;

    address owner = address(this);
    address user = address(0x1);
    address treasury = address(0x3);

    bytes32 poolId;

    function setUp() public {
        // Deploy mock tokens
        token0 = new MockERC20R("Token0", "TK0");
        token1 = new MockERC20R("Token1", "TK1");

        // Deploy facets
        diamondCutFacet = new DiamondCutFacet();
        diamond = new Diamond(owner, address(diamondCutFacet));
        diamondLoupeFacet = new DiamondLoupeFacet();
        ownershipFacet = new OwnershipFacet();
        poolRegistryFacet = new PoolRegistryFacet();
        liquidityFacet = new LiquidityFacet();
        redemptionFacet = new RedemptionFacet();
        yieldAccumulatorFacet = new YieldAccumulatorFacet();

        // Deploy mock adapter
        mockAdapter = new MockRedemptionAdapter(
            address(token0),
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
        registrySelectors[4] = PoolRegistryFacet.poolExists.selector;
        registrySelectors[5] = PoolRegistryFacet.getCurrentCycleId.selector;
        registrySelectors[6] = PoolRegistryFacet.getCycleInfo.selector;
        cut[2] = IDiamondCut.FacetCut({
            facetAddress: address(poolRegistryFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: registrySelectors
        });

        // LiquidityFacet
        bytes4[] memory liquiditySelectors = new bytes4[](2);
        liquiditySelectors[0] = LiquidityFacet.addLiquidity.selector;
        liquiditySelectors[1] = LiquidityFacet.getTotalLiquidity.selector;
        cut[3] = IDiamondCut.FacetCut({
            facetAddress: address(liquidityFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: liquiditySelectors
        });

        // RedemptionFacet
        bytes4[] memory redemptionSelectors = new bytes4[](4);
        redemptionSelectors[0] = RedemptionFacet.redeemPT.selector;
        redemptionSelectors[1] = RedemptionFacet.redeemPTWithZap.selector;
        redemptionSelectors[2] = RedemptionFacet.hasMatured.selector;
        redemptionSelectors[3] = RedemptionFacet.previewRedemption.selector;
        cut[4] = IDiamondCut.FacetCut({
            facetAddress: address(redemptionFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: redemptionSelectors
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
        PoolRegistryFacet(address(diamond)).approveAdapter(
            address(mockAdapter)
        );
        PoolRegistryFacet(address(diamond)).approveQuoteToken(address(token0));

        // Register pool
        bytes memory poolParams = abi.encode(address(0xB001));
        poolId = PoolRegistryFacet(address(diamond)).registerPool(
            address(mockAdapter),
            poolParams,
            address(token0)
        );

        // Mint tokens to user
        token0.mint(user, 10000e18);
        token1.mint(user, 10000e18);
    }

    // Shorthand functions
    function redemption() internal view returns (RedemptionFacet) {
        return RedemptionFacet(address(diamond));
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

    function _addLiquidityAsUser(uint256 amount) internal {
        vm.startPrank(user);
        token0.approve(address(diamond), amount);
        token1.approve(address(diamond), amount);
        liquidity().addLiquidity(poolId, amount, amount);
        vm.stopPrank();
    }

    function _warpToMaturity() internal {
        // Warp 91 days forward (past 90-day maturity)
        vm.warp(block.timestamp + 91 days);
    }

    // ================================================================
    //                    MATURITY TESTS
    // ================================================================

    function test_RedeemPT_RevertsBeforeMaturity() public {
        _addLiquidityAsUser(1000e18);

        vm.prank(user);
        vm.expectRevert(); // CycleNotMatured
        redemption().redeemPT(poolId, 1, 100e18, 100);
    }

    function test_RedeemPT_SucceedsAfterMaturity() public {
        _addLiquidityAsUser(1000e18);
        _warpToMaturity();

        // Mint tokens to Diamond for redemption
        token0.mint(address(diamond), 1000e18);
        token1.mint(address(diamond), 1000e18);

        // Get PT address
        address ptToken = registry().getCycleInfo(poolId, 1).ptToken;
        uint256 ptBalance = IERC20(ptToken).balanceOf(user);

        vm.prank(user);
        (uint256 amount0, uint256 amount1) = redemption().redeemPT(
            poolId,
            1,
            ptBalance,
            1000 // 10% slippage
        );

        assertGt(amount0, 0);
        assertGt(amount1, 0);
    }

    function test_HasMatured_ReturnsFalseBeforeMaturity() public {
        _addLiquidityAsUser(1000e18);
        assertFalse(redemption().hasMatured(poolId, 1));
    }

    function test_HasMatured_ReturnsTrueAfterMaturity() public {
        _addLiquidityAsUser(1000e18);
        _warpToMaturity();
        assertTrue(redemption().hasMatured(poolId, 1));
    }

    // ================================================================
    //                    REDEMPTION LOGIC TESTS
    // ================================================================

    function test_RedeemPT_BurnsPTTokens() public {
        _addLiquidityAsUser(1000e18);
        _warpToMaturity();
        token0.mint(address(diamond), 1000e18);
        token1.mint(address(diamond), 1000e18);

        address ptToken = registry().getCycleInfo(poolId, 1).ptToken;
        uint256 ptBefore = IERC20(ptToken).balanceOf(user);

        vm.prank(user);
        redemption().redeemPT(poolId, 1, ptBefore / 2, 1000);

        assertEq(IERC20(ptToken).balanceOf(user), ptBefore / 2);
    }

    function test_RedeemPT_RevertsOnZeroAmount() public {
        _addLiquidityAsUser(1000e18);
        _warpToMaturity();

        vm.prank(user);
        vm.expectRevert(RedemptionFacet.ZeroAmount.selector);
        redemption().redeemPT(poolId, 1, 0, 100);
    }

    function test_RedeemPT_RevertsForNonExistentPool() public {
        bytes32 fakePoolId = keccak256("fake");

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                RedemptionFacet.PoolDoesNotExist.selector,
                fakePoolId
            )
        );
        redemption().redeemPT(fakePoolId, 1, 100e18, 100);
    }

    function test_RedeemPT_RevertsForNonExistentCycle() public {
        _addLiquidityAsUser(1000e18);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                RedemptionFacet.CycleDoesNotExist.selector,
                poolId,
                99
            )
        );
        redemption().redeemPT(poolId, 99, 100e18, 100);
    }

    // ================================================================
    //                    VIEW FUNCTION TESTS
    // ================================================================

    function test_PreviewRedemption_ReturnsLiquidity() public {
        _addLiquidityAsUser(1000e18);

        address ptToken = registry().getCycleInfo(poolId, 1).ptToken;
        uint256 ptBalance = IERC20(ptToken).balanceOf(user);

        uint128 liquidityPreview = redemption().previewRedemption(
            poolId,
            1,
            ptBalance
        );

        assertGt(liquidityPreview, 0);
    }
}

// ================================================================
//                     MOCK CONTRACTS
// ================================================================

contract MockERC20R is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockRedemptionAdapter is ILiquidityAdapter {
    address public immutable token0;
    address public immutable token1;
    address public immutable diamond;

    uint128 public totalLiquidity;

    constructor(address _token0, address _token1, address _diamond) {
        token0 = _token0;
        token1 = _token1;
        diamond = _diamond;
    }

    function addLiquidity(
        bytes calldata params
    )
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
        totalLiquidity += liquidity;

        IERC20(token0).transferFrom(msg.sender, address(this), amount0Used);
        IERC20(token1).transferFrom(msg.sender, address(this), amount1Used);

        return (liquidity, amount0Used, amount1Used);
    }

    function removeLiquidity(
        uint128 liquidity,
        bytes calldata
    ) external override returns (uint256 amount0, uint256 amount1) {
        // Return proportional amounts
        amount0 = liquidity * 2;
        amount1 = liquidity * 2;
        totalLiquidity -= liquidity;

        // Tokens are in Diamond, transfer happens in facet
        return (amount0, amount1);
    }

    function previewRemoveLiquidity(
        uint128 liquidity,
        bytes calldata
    ) external pure override returns (uint256, uint256) {
        return (liquidity * 2, liquidity * 2);
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

    // New interface stubs
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
