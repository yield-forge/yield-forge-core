// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {PrincipalToken} from "../src/tokens/PrincipalToken.sol";
import {YieldToken} from "../src/tokens/YieldToken.sol";
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
import {LibAppStorage} from "../src/libraries/LibAppStorage.sol";

/**
 * @title TokenTest
 * @notice Tests for PT/YT tokens: access control, naming, immutable state
 */
contract TokenTest is Test {
    Diamond diamond;
    DiamondCutFacet diamondCutFacet;
    DiamondLoupeFacet diamondLoupeFacet;
    OwnershipFacet ownershipFacet;
    PoolRegistryFacet poolRegistryFacet;
    LiquidityFacet liquidityFacet;
    YieldAccumulatorFacet yieldAccumulatorFacet;

    MockTokenAdapter mockAdapter;
    MockERC20T token0;
    MockERC20T token1;

    address owner = address(this);
    address user = address(0x1);
    address attacker = address(0xBAD);
    address treasury = address(0x3);

    bytes32 poolId;
    PrincipalToken ptToken;
    YieldToken ytToken;

    function setUp() public {
        // Deploy mock tokens
        token0 = new MockERC20T("Token0", "TK0");
        token1 = new MockERC20T("Token1", "TK1");

        // Deploy facets
        diamondCutFacet = new DiamondCutFacet();
        diamond = new Diamond(owner, address(diamondCutFacet));
        diamondLoupeFacet = new DiamondLoupeFacet();
        ownershipFacet = new OwnershipFacet();
        poolRegistryFacet = new PoolRegistryFacet();
        liquidityFacet = new LiquidityFacet();
        yieldAccumulatorFacet = new YieldAccumulatorFacet();

        // Deploy mock adapter
        mockAdapter = new MockTokenAdapter(address(token0), address(token1), address(diamond));

        // Add facets to Diamond
        _addFacets();

        // Setup protocol state and create cycle (which creates PT/YT)
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

        // YieldAccumulatorFacet
        bytes4[] memory yieldSelectors = new bytes4[](2);
        yieldSelectors[0] = YieldAccumulatorFacet.syncCheckpoint.selector;
        yieldSelectors[1] = YieldAccumulatorFacet.getPendingYield.selector;
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
        PoolRegistryFacet(address(diamond)).approveAdapter(address(mockAdapter));
        PoolRegistryFacet(address(diamond)).approveQuoteToken(address(token0));

        // Register pool
        bytes memory poolParams = abi.encode(address(0xB001));
        poolId = PoolRegistryFacet(address(diamond)).registerPool(address(mockAdapter), poolParams, address(token0));

        // Mint tokens to user and add liquidity to create cycle
        token0.mint(user, 10000e18);
        token1.mint(user, 10000e18);

        vm.startPrank(user);
        token0.approve(address(diamond), 1000e18);
        token1.approve(address(diamond), 1000e18);
        LiquidityFacet(address(diamond)).addLiquidity(poolId, 1000e18, 1000e18);
        vm.stopPrank();

        // Get deployed PT/YT tokens from cycle info
        LibAppStorage.CycleInfo memory cycleInfo = PoolRegistryFacet(address(diamond)).getCycleInfo(poolId, 1);
        ptToken = PrincipalToken(cycleInfo.ptToken);
        ytToken = YieldToken(cycleInfo.ytToken);
    }

    // ================================================================
    //                    ACCESS CONTROL TESTS
    // ================================================================

    function test_PT_MintRevertsForNonDiamond() public {
        vm.prank(attacker);
        vm.expectRevert();
        ptToken.mint(attacker, 100e18);
    }

    function test_PT_BurnRevertsForNonDiamond() public {
        vm.prank(attacker);
        vm.expectRevert();
        ptToken.burn(user, 100e18);
    }

    function test_YT_MintRevertsForNonDiamond() public {
        vm.prank(attacker);
        vm.expectRevert();
        ytToken.mint(attacker, 100e18);
    }

    function test_YT_BurnRevertsForNonDiamond() public {
        vm.prank(attacker);
        vm.expectRevert();
        ytToken.burn(user, 100e18);
    }

    // ================================================================
    //                    IMMUTABLE STATE TESTS
    // ================================================================

    function test_PT_HasCorrectDiamond() public view {
        assertEq(ptToken.diamond(), address(diamond));
    }

    function test_PT_HasCorrectPoolId() public view {
        assertEq(ptToken.poolId(), poolId);
    }

    function test_PT_HasCorrectCycleId() public view {
        assertEq(ptToken.cycleId(), 1);
    }

    function test_PT_HasFutureMaturity() public view {
        assertGt(ptToken.maturityDate(), block.timestamp);
    }

    function test_YT_HasCorrectDiamond() public view {
        assertEq(ytToken.diamond(), address(diamond));
    }

    function test_YT_HasCorrectPoolId() public view {
        assertEq(ytToken.poolId(), poolId);
    }

    // ================================================================
    //                    VIEW FUNCTION TESTS
    // ================================================================

    function test_PT_IsMatureReturnsFalseBeforeMaturity() public view {
        assertFalse(ptToken.isMature());
    }

    function test_PT_IsMatureReturnsTrueAfterMaturity() public {
        vm.warp(block.timestamp + 91 days);
        assertTrue(ptToken.isMature());
    }

    function test_TimeUntilMaturity_ReturnsCorrectValue() public view {
        uint256 ttm = ptToken.timeUntilMaturity();
        assertGt(ttm, 89 days);
        assertLt(ttm, 91 days);
    }

    function test_TimeUntilMaturity_ReturnsZeroAfterMaturity() public {
        vm.warp(block.timestamp + 91 days);
        assertEq(ptToken.timeUntilMaturity(), 0);
    }

    // ================================================================
    //                    TOKEN NAMING TESTS
    // ================================================================

    function test_PT_NameStartsWithYFPT() public view {
        string memory name = ptToken.name();
        // Name should start with "YF-PT-"
        bytes memory nameBytes = bytes(name);
        assertGe(nameBytes.length, 6);
        assertEq(nameBytes[0], "Y");
        assertEq(nameBytes[1], "F");
        assertEq(nameBytes[2], "-");
        assertEq(nameBytes[3], "P");
        assertEq(nameBytes[4], "T");
    }

    function test_YT_NameStartsWithYFYT() public view {
        string memory name = ytToken.name();
        // Name should start with "YF-YT-"
        bytes memory nameBytes = bytes(name);
        assertGe(nameBytes.length, 6);
        assertEq(nameBytes[0], "Y");
        assertEq(nameBytes[1], "F");
        assertEq(nameBytes[2], "-");
        assertEq(nameBytes[3], "Y");
        assertEq(nameBytes[4], "T");
    }

    // ================================================================
    //                    TRANSFER TESTS
    // ================================================================

    function test_PT_TransferSucceeds() public {
        uint256 balance = ptToken.balanceOf(user);
        address recipient = address(0x999);

        vm.prank(user);
        ptToken.transfer(recipient, balance / 2);

        assertEq(ptToken.balanceOf(recipient), balance / 2);
    }

    function test_YT_TransferSucceeds() public {
        uint256 balance = ytToken.balanceOf(user);
        address recipient = address(0x999);

        vm.prank(user);
        ytToken.transfer(recipient, balance / 2);

        assertEq(ytToken.balanceOf(recipient), balance / 2);
    }
}

// ================================================================
//                     MOCK CONTRACTS
// ================================================================

contract MockERC20T is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockTokenAdapter is ILiquidityAdapter {
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
