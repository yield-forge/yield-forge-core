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
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {IERC165} from "../src/interfaces/IERC165.sol";
import {IERC173} from "../src/interfaces/IERC173.sol";
import {ILiquidityAdapter} from "../src/interfaces/ILiquidityAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title YieldAccumulatorFacetTest
 * @notice Tests for yield harvesting, distribution, and claiming
 */
contract YieldAccumulatorFacetTest is Test {
    Diamond diamond;
    DiamondCutFacet diamondCutFacet;
    DiamondLoupeFacet diamondLoupeFacet;
    OwnershipFacet ownershipFacet;
    PoolRegistryFacet poolRegistryFacet;
    LiquidityFacet liquidityFacet;
    YieldAccumulatorFacet yieldAccumulatorFacet;

    MockYieldAdapter mockAdapter;
    MockERC20Y token0;
    MockERC20Y token1;

    address owner = address(this);
    address user1 = address(0x1);
    address user2 = address(0x2);
    address treasury = address(0x3);

    bytes32 poolId;

    function setUp() public {
        // Deploy mock tokens
        token0 = new MockERC20Y("Token0", "TK0");
        token1 = new MockERC20Y("Token1", "TK1");

        // Deploy facets
        diamondCutFacet = new DiamondCutFacet();
        diamond = new Diamond(owner, address(diamondCutFacet));
        diamondLoupeFacet = new DiamondLoupeFacet();
        ownershipFacet = new OwnershipFacet();
        poolRegistryFacet = new PoolRegistryFacet();
        liquidityFacet = new LiquidityFacet();
        yieldAccumulatorFacet = new YieldAccumulatorFacet();

        // Deploy mock adapter (with yield)
        mockAdapter = new MockYieldAdapter(
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
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](5);

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
        registrySelectors[4] = PoolRegistryFacet.poolExists.selector;
        registrySelectors[5] = PoolRegistryFacet.getCurrentCycleId.selector;
        registrySelectors[6] = PoolRegistryFacet.getCycleInfo.selector;
        registrySelectors[7] = PoolRegistryFacet.feeRecipient.selector;
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

        // YieldAccumulatorFacet
        bytes4[] memory yieldSelectors = new bytes4[](7);
        yieldSelectors[0] = YieldAccumulatorFacet.harvestYield.selector;
        yieldSelectors[1] = YieldAccumulatorFacet.claimYield.selector;
        yieldSelectors[2] = YieldAccumulatorFacet.syncCheckpoint.selector;
        yieldSelectors[3] = YieldAccumulatorFacet.getPendingYield.selector;
        yieldSelectors[4] = YieldAccumulatorFacet.getYieldState.selector;
        yieldSelectors[5] = YieldAccumulatorFacet.withdrawProtocolFees.selector;
        yieldSelectors[6] = YieldAccumulatorFacet
            .getPendingProtocolFees
            .selector;
        cut[4] = IDiamondCut.FacetCut({
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

        // Mint tokens to users
        token0.mint(user1, 10000e18);
        token1.mint(user1, 10000e18);
        token0.mint(user2, 10000e18);
        token1.mint(user2, 10000e18);
    }

    // Shorthand for facet calls
    function yieldAcc() internal view returns (YieldAccumulatorFacet) {
        return YieldAccumulatorFacet(address(diamond));
    }

    function liquidity() internal view returns (LiquidityFacet) {
        return LiquidityFacet(address(diamond));
    }

    function registry() internal view returns (PoolRegistryFacet) {
        return PoolRegistryFacet(address(diamond));
    }

    // ================================================================
    //                    HELPER FUNCTIONS
    // ================================================================

    function _addLiquidityAsUser(address user, uint256 amount) internal {
        vm.startPrank(user);
        token0.approve(address(diamond), amount);
        token1.approve(address(diamond), amount);
        liquidity().addLiquidity(poolId, amount, amount);
        vm.stopPrank();
    }

    // ================================================================
    //                    HARVEST TESTS
    // ================================================================

    function test_HarvestYield_CollectsFromAdapter() public {
        _addLiquidityAsUser(user1, 1000e18);

        // Set yield in adapter
        mockAdapter.setYield(100e18, 50e18);

        // Mint yield tokens to Diamond to simulate real scenario
        token0.mint(address(diamond), 100e18);
        token1.mint(address(diamond), 50e18);

        // Harvest
        (uint256 y0, uint256 y1) = yieldAcc().harvestYield(poolId);

        assertEq(y0, 100e18);
        assertEq(y1, 50e18);
    }

    function test_HarvestYield_TakesProtocolFee() public {
        _addLiquidityAsUser(user1, 1000e18);

        // Set yield in adapter
        mockAdapter.setYield(1000e18, 0);
        token0.mint(address(diamond), 1000e18);

        // Harvest
        yieldAcc().harvestYield(poolId);

        // 5% protocol fee = 50e18
        (uint256 fee0, uint256 fee1) = yieldAcc().getPendingProtocolFees(
            poolId,
            1
        );
        assertEq(fee0, 50e18);
        assertEq(fee1, 0);
    }

    function test_HarvestYield_AnyoneCanCall() public {
        _addLiquidityAsUser(user1, 1000e18);
        mockAdapter.setYield(100e18, 0);
        token0.mint(address(diamond), 100e18);

        // Random address can harvest
        vm.prank(address(0xDEAD));
        (uint256 y0, ) = yieldAcc().harvestYield(poolId);

        assertEq(y0, 100e18);
    }

    // ================================================================
    //                    CLAIM TESTS
    // ================================================================

    function test_ClaimYield_UserGetsTheirShare() public {
        _addLiquidityAsUser(user1, 1000e18);

        // Set yield and harvest
        mockAdapter.setYield(1000e18, 500e18);
        token0.mint(address(diamond), 1000e18);
        token1.mint(address(diamond), 500e18);
        yieldAcc().harvestYield(poolId);

        // Claim as user1
        vm.prank(user1);
        (uint256 amount0, uint256 amount1) = yieldAcc().claimYield(poolId, 1);

        // User gets 95% (after 5% protocol fee)
        assertEq(amount0, 950e18);
        assertEq(amount1, 475e18);
    }

    function test_ClaimYield_RevertsIfNoYield() public {
        _addLiquidityAsUser(user1, 1000e18);

        vm.prank(user1);
        vm.expectRevert(YieldAccumulatorFacet.NoYieldToClaim.selector);
        yieldAcc().claimYield(poolId, 1);
    }

    function test_ClaimYield_DoubleClaim_SecondFails() public {
        _addLiquidityAsUser(user1, 1000e18);

        // Set yield and harvest
        mockAdapter.setYield(1000e18, 0);
        token0.mint(address(diamond), 1000e18);
        yieldAcc().harvestYield(poolId);

        // First claim succeeds
        vm.prank(user1);
        yieldAcc().claimYield(poolId, 1);

        // Second claim reverts
        vm.prank(user1);
        vm.expectRevert(YieldAccumulatorFacet.NoYieldToClaim.selector);
        yieldAcc().claimYield(poolId, 1);
    }

    // ================================================================
    //                    PROTOCOL FEE TESTS
    // ================================================================

    function test_WithdrawProtocolFees_OnlyFeeRecipient() public {
        _addLiquidityAsUser(user1, 1000e18);
        mockAdapter.setYield(1000e18, 0);
        token0.mint(address(diamond), 1000e18);
        yieldAcc().harvestYield(poolId);

        // Non-recipient cannot withdraw
        vm.prank(user1);
        vm.expectRevert(YieldAccumulatorFacet.NotAuthorized.selector);
        yieldAcc().withdrawProtocolFees(poolId, 1);

        // Fee recipient can withdraw
        uint256 balanceBefore = token0.balanceOf(treasury);
        vm.prank(treasury);
        (uint256 fee0, ) = yieldAcc().withdrawProtocolFees(poolId, 1);

        assertEq(fee0, 50e18);
        assertEq(token0.balanceOf(treasury), balanceBefore + 50e18);
    }

    // ================================================================
    //                    VIEW FUNCTION TESTS
    // ================================================================

    function test_GetPendingYield_ReturnsCorrect() public {
        _addLiquidityAsUser(user1, 1000e18);
        mockAdapter.setYield(1000e18, 500e18);
        token0.mint(address(diamond), 1000e18);
        token1.mint(address(diamond), 500e18);
        yieldAcc().harvestYield(poolId);

        (uint256 pending0, uint256 pending1) = yieldAcc().getPendingYield(
            poolId,
            1,
            user1
        );

        assertEq(pending0, 950e18);
        assertEq(pending1, 475e18);
    }
}

// ================================================================
//                     MOCK CONTRACTS
// ================================================================

contract MockERC20Y is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockYieldAdapter is ILiquidityAdapter {
    address public immutable token0;
    address public immutable token1;
    address public immutable diamond;

    uint256 public yieldAmount0;
    uint256 public yieldAmount1;

    constructor(address _token0, address _token1, address _diamond) {
        token0 = _token0;
        token1 = _token1;
        diamond = _diamond;
    }

    function setYield(uint256 y0, uint256 y1) external {
        yieldAmount0 = y0;
        yieldAmount1 = y1;
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

        IERC20(token0).transferFrom(msg.sender, address(this), amount0Used);
        IERC20(token1).transferFrom(msg.sender, address(this), amount1Used);

        return (liquidity, amount0Used, amount1Used);
    }

    function collectYield(
        bytes calldata
    ) external override returns (uint256, uint256) {
        uint256 y0 = yieldAmount0;
        uint256 y1 = yieldAmount1;
        yieldAmount0 = 0;
        yieldAmount1 = 0;
        return (y0, y1);
    }

    function removeLiquidity(
        uint128,
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
