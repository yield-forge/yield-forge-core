// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Diamond} from "../src/Diamond.sol";
import {DiamondCutFacet} from "../src/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../src/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {PoolRegistryFacet} from "../src/facets/PoolRegistryFacet.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {IERC165} from "../src/interfaces/IERC165.sol";
import {IERC173} from "../src/interfaces/IERC173.sol";
import {ILiquidityAdapter} from "../src/interfaces/ILiquidityAdapter.sol";

/**
 * @title PoolRegistryFacetTest
 * @notice Tests for PoolRegistryFacet access control and core functionality
 */
contract PoolRegistryFacetTest is Test {
    Diamond diamond;
    DiamondCutFacet diamondCutFacet;
    DiamondLoupeFacet diamondLoupeFacet;
    OwnershipFacet ownershipFacet;
    PoolRegistryFacet poolRegistryFacet;

    // Mock adapter for testing
    MockAdapter mockAdapter;

    address owner = address(this);
    address user = address(0x1);
    address guardian = address(0x2);
    address treasury = address(0x3);

    // Mock tokens
    MockToken mockToken0;
    MockToken mockToken1;

    function setUp() public {
        // Deploy mock tokens
        mockToken0 = new MockToken("Token0", "TKN0", 6);
        mockToken1 = new MockToken("Token1", "TKN1", 18);

        // Deploy facets
        diamondCutFacet = new DiamondCutFacet();
        diamond = new Diamond(owner, address(diamondCutFacet));
        diamondLoupeFacet = new DiamondLoupeFacet();
        ownershipFacet = new OwnershipFacet();
        poolRegistryFacet = new PoolRegistryFacet();

        // Deploy mock adapter
        mockAdapter = new MockAdapter(address(mockToken0), address(mockToken1));

        // Add facets to Diamond
        _addFacets();
    }

    function _addFacets() internal {
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](3);

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
        bytes4[] memory registrySelectors = new bytes4[](22);
        registrySelectors[0] = PoolRegistryFacet.initialize.selector;
        registrySelectors[1] = PoolRegistryFacet.isInitialized.selector;
        registrySelectors[2] = PoolRegistryFacet.approveAdapter.selector;
        registrySelectors[3] = PoolRegistryFacet.revokeAdapter.selector;
        registrySelectors[4] = PoolRegistryFacet.isAdapterApproved.selector;
        registrySelectors[5] = PoolRegistryFacet.approveQuoteToken.selector;
        registrySelectors[6] = PoolRegistryFacet.revokeQuoteToken.selector;
        registrySelectors[7] = PoolRegistryFacet.isQuoteTokenApproved.selector;
        registrySelectors[8] = PoolRegistryFacet.registerPool.selector;
        registrySelectors[9] = PoolRegistryFacet.setPoolGuardian.selector;
        registrySelectors[10] = PoolRegistryFacet.poolGuardian.selector;
        registrySelectors[11] = PoolRegistryFacet.banPool.selector;
        registrySelectors[12] = PoolRegistryFacet.unbanPool.selector;
        registrySelectors[13] = PoolRegistryFacet.isPoolBanned.selector;
        registrySelectors[14] = PoolRegistryFacet.setPoolQuoteToken.selector;
        registrySelectors[15] = PoolRegistryFacet.setFeeRecipient.selector;
        registrySelectors[16] = PoolRegistryFacet.feeRecipient.selector;
        registrySelectors[17] = PoolRegistryFacet.getPoolInfo.selector;
        registrySelectors[18] = PoolRegistryFacet.poolExists.selector;
        registrySelectors[19] = PoolRegistryFacet.getCurrentCycleId.selector;
        registrySelectors[20] = PoolRegistryFacet.getCycleInfo.selector;
        registrySelectors[21] = PoolRegistryFacet.getPoolTokens.selector;
        cut[2] = IDiamondCut.FacetCut({
            facetAddress: address(poolRegistryFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: registrySelectors
        });

        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
    }

    // Shorthand for registry calls through Diamond
    function registry() internal view returns (PoolRegistryFacet) {
        return PoolRegistryFacet(address(diamond));
    }

    // ================================================================
    //                    INITIALIZATION TESTS
    // ================================================================

    function test_Initialize_SetsState() public {
        registry().initialize(treasury);

        assertTrue(registry().isInitialized());
        assertEq(registry().feeRecipient(), treasury);
    }

    function test_Initialize_RevertsOnZeroAddress() public {
        vm.expectRevert(PoolRegistryFacet.ZeroAddress.selector);
        registry().initialize(address(0));
    }

    function test_Initialize_RevertsOnSecondCall() public {
        registry().initialize(treasury);

        vm.expectRevert(PoolRegistryFacet.AlreadyInitialized.selector);
        registry().initialize(treasury);
    }

    function test_Initialize_RevertsForNonOwner() public {
        vm.prank(user);
        vm.expectRevert("LibDiamond: Must be contract owner");
        registry().initialize(treasury);
    }

    // ================================================================
    //                 ADAPTER MANAGEMENT TESTS
    // ================================================================

    function test_ApproveAdapter_Success() public {
        registry().approveAdapter(address(mockAdapter));
        assertTrue(registry().isAdapterApproved(address(mockAdapter)));
    }

    function test_ApproveAdapter_RevertsForNonOwner() public {
        vm.prank(user);
        vm.expectRevert("LibDiamond: Must be contract owner");
        registry().approveAdapter(address(mockAdapter));
    }

    function test_ApproveAdapter_RevertsOnZeroAddress() public {
        vm.expectRevert(PoolRegistryFacet.ZeroAddress.selector);
        registry().approveAdapter(address(0));
    }

    function test_ApproveAdapter_RevertsIfAlreadyApproved() public {
        registry().approveAdapter(address(mockAdapter));

        vm.expectRevert(abi.encodeWithSelector(PoolRegistryFacet.AdapterAlreadyApproved.selector, address(mockAdapter)));
        registry().approveAdapter(address(mockAdapter));
    }

    function test_RevokeAdapter_Success() public {
        registry().approveAdapter(address(mockAdapter));
        registry().revokeAdapter(address(mockAdapter));
        assertFalse(registry().isAdapterApproved(address(mockAdapter)));
    }

    function test_RevokeAdapter_RevertsForNonOwner() public {
        registry().approveAdapter(address(mockAdapter));

        vm.prank(user);
        vm.expectRevert("LibDiamond: Must be contract owner");
        registry().revokeAdapter(address(mockAdapter));
    }

    // ================================================================
    //                 QUOTE TOKEN MANAGEMENT TESTS
    // ================================================================

    function test_ApproveQuoteToken_Success() public {
        registry().approveQuoteToken(address(mockToken0));
        assertTrue(registry().isQuoteTokenApproved(address(mockToken0)));
    }

    function test_ApproveQuoteToken_RevertsForNonOwner() public {
        vm.prank(user);
        vm.expectRevert("LibDiamond: Must be contract owner");
        registry().approveQuoteToken(address(mockToken0));
    }

    function test_RevokeQuoteToken_Success() public {
        registry().approveQuoteToken(address(mockToken0));
        registry().revokeQuoteToken(address(mockToken0));
        assertFalse(registry().isQuoteTokenApproved(address(mockToken0)));
    }

    // ================================================================
    //                    POOL REGISTRATION TESTS
    // ================================================================

    function test_RegisterPool_Success() public {
        _setupForPoolRegistration();

        bytes memory poolParams = abi.encode(address(0xB001));
        bytes32 poolId = registry().registerPool(address(mockAdapter), poolParams, address(mockToken0));

        assertTrue(registry().poolExists(poolId));
        (address t0, address t1) = registry().getPoolTokens(poolId);
        assertEq(t0, address(mockToken0));
        assertEq(t1, address(mockToken1));
    }

    function test_RegisterPool_AllowsAnyUser() public {
        _setupForPoolRegistration();

        bytes memory poolParams = abi.encode(address(0xC001));

        // Any user can register a pool
        vm.prank(user);
        bytes32 poolId = registry().registerPool(address(mockAdapter), poolParams, address(mockToken0));

        assertTrue(registry().poolExists(poolId));
    }

    function test_RegisterPool_RevertsIfNotInitialized() public {
        registry().approveAdapter(address(mockAdapter));
        registry().approveQuoteToken(address(mockToken0));

        vm.expectRevert(PoolRegistryFacet.NotInitialized.selector);
        registry().registerPool(address(mockAdapter), "", address(mockToken0));
    }

    function test_RegisterPool_RevertsIfAdapterNotApproved() public {
        registry().initialize(treasury);
        registry().approveQuoteToken(address(mockToken0));

        vm.expectRevert(abi.encodeWithSelector(PoolRegistryFacet.AdapterNotApproved.selector, address(mockAdapter)));
        registry().registerPool(address(mockAdapter), "", address(mockToken0));
    }

    function test_RegisterPool_RevertsIfQuoteTokenNotApproved() public {
        registry().initialize(treasury);
        registry().approveAdapter(address(mockAdapter));

        vm.expectRevert(abi.encodeWithSelector(PoolRegistryFacet.QuoteTokenNotApproved.selector, address(mockToken0)));
        registry().registerPool(address(mockAdapter), "", address(mockToken0));
    }

    function test_RegisterPool_RevertsIfPoolAlreadyExists() public {
        _setupForPoolRegistration();

        bytes memory poolParams = abi.encode(address(0xB001));
        bytes32 poolId = registry().registerPool(address(mockAdapter), poolParams, address(mockToken0));

        vm.expectRevert(abi.encodeWithSelector(PoolRegistryFacet.PoolAlreadyExists.selector, poolId));
        registry().registerPool(address(mockAdapter), poolParams, address(mockToken0));
    }

    function test_RegisterPool_RevertsIfPoolPreviouslyBanned() public {
        _setupForPoolRegistration();

        bytes memory poolParams = abi.encode(address(0xB002));
        bytes32 poolId = registry().registerPool(address(mockAdapter), poolParams, address(mockToken0));

        // Ban the pool
        registry().banPool(poolId);
        assertTrue(registry().isPoolBanned(poolId));

        // Try to re-register the banned pool (with different adapter to test the logic)
        // Actually, same poolId means same adapter + poolParams, so we just test that a banned pool
        // cannot be re-registered
        vm.expectRevert(abi.encodeWithSelector(PoolRegistryFacet.PoolAlreadyExists.selector, poolId));
        registry().registerPool(address(mockAdapter), poolParams, address(mockToken0));
    }

    function test_RegisterPool_AnyoneCanRegister_ButBannedPoolsBlocked() public {
        _setupForPoolRegistration();

        // User registers a pool
        bytes memory poolParams = abi.encode(address(0xB003));
        vm.prank(user);
        bytes32 poolId = registry().registerPool(address(mockAdapter), poolParams, address(mockToken0));

        assertTrue(registry().poolExists(poolId));

        // Owner bans the pool
        registry().banPool(poolId);

        // Another user tries to re-register - should fail
        vm.prank(address(0x4));
        vm.expectRevert(abi.encodeWithSelector(PoolRegistryFacet.PoolAlreadyExists.selector, poolId));
        registry().registerPool(address(mockAdapter), poolParams, address(mockToken0));
    }

    // ================================================================
    //                     GUARDIAN TESTS
    // ================================================================

    function test_SetPoolGuardian_Success() public {
        registry().setPoolGuardian(guardian);
        assertEq(registry().poolGuardian(), guardian);
    }

    function test_SetPoolGuardian_RevertsForNonOwner() public {
        vm.prank(user);
        vm.expectRevert("LibDiamond: Must be contract owner");
        registry().setPoolGuardian(guardian);
    }

    function test_BanPool_ByOwner() public {
        bytes32 poolId = _registerTestPool();

        registry().banPool(poolId);
        assertTrue(registry().isPoolBanned(poolId));
    }

    function test_BanPool_ByGuardian() public {
        bytes32 poolId = _registerTestPool();
        registry().setPoolGuardian(guardian);

        vm.prank(guardian);
        registry().banPool(poolId);
        assertTrue(registry().isPoolBanned(poolId));
    }

    function test_BanPool_RevertsForNonGuardian() public {
        bytes32 poolId = _registerTestPool();

        vm.prank(user);
        vm.expectRevert(PoolRegistryFacet.NotPoolGuardian.selector);
        registry().banPool(poolId);
    }

    function test_UnbanPool_ByOwner() public {
        bytes32 poolId = _registerTestPool();
        registry().banPool(poolId);

        registry().unbanPool(poolId);
        assertFalse(registry().isPoolBanned(poolId));
    }

    function test_UnbanPool_ByGuardian() public {
        bytes32 poolId = _registerTestPool();
        registry().setPoolGuardian(guardian);
        registry().banPool(poolId);

        vm.prank(guardian);
        registry().unbanPool(poolId);
        assertFalse(registry().isPoolBanned(poolId));
    }

    // ================================================================
    //                    FEE RECIPIENT TESTS
    // ================================================================

    function test_SetFeeRecipient_Success() public {
        registry().initialize(treasury);

        address newRecipient = address(0x999);
        registry().setFeeRecipient(newRecipient);
        assertEq(registry().feeRecipient(), newRecipient);
    }

    function test_SetFeeRecipient_RevertsForNonOwner() public {
        registry().initialize(treasury);

        vm.prank(user);
        vm.expectRevert("LibDiamond: Must be contract owner");
        registry().setFeeRecipient(address(0x999));
    }

    function test_SetFeeRecipient_RevertsOnZeroAddress() public {
        registry().initialize(treasury);

        vm.expectRevert(PoolRegistryFacet.ZeroAddress.selector);
        registry().setFeeRecipient(address(0));
    }

    function test_SetFeeRecipient_RevertOnDiamondAddress() public {
        registry().initialize(treasury);

        vm.expectRevert(abi.encodeWithSelector(PoolRegistryFacet.InvalidRecipient.selector, address(diamond)));
        registry().setFeeRecipient(address(diamond));
    }

    // ================================================================
    //                        HELPERS
    // ================================================================

    function _setupForPoolRegistration() internal {
        registry().initialize(treasury);
        registry().approveAdapter(address(mockAdapter));
        registry().approveQuoteToken(address(mockToken0));
    }

    function _registerTestPool() internal returns (bytes32) {
        _setupForPoolRegistration();
        bytes memory poolParams = abi.encode(address(0xB001));
        return registry().registerPool(address(mockAdapter), poolParams, address(mockToken0));
    }
}

// ================================================================
//                     MOCK CONTRACTS
// ================================================================

/**
 * @notice Mock adapter for testing pool registration
 */
contract MockAdapter is ILiquidityAdapter {
    address public immutable token0;
    address public immutable token1;

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    function addLiquidity(bytes calldata) external pure override returns (uint128, uint256, uint256) {
        return (0, 0, 0);
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

/**
 * @notice Mock ERC20 token for testing
 */
contract MockToken {
    string public name;
    string public symbol;
    uint8 public decimals;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }
}
