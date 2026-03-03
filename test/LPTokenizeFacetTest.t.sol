// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Diamond} from "../src/Diamond.sol";
import {DiamondCutFacet} from "../src/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../src/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {PoolRegistryFacet} from "../src/facets/PoolRegistryFacet.sol";
import {LiquidityFacet} from "../src/facets/LiquidityFacet.sol";
import {LPTokenizeFacet} from "../src/facets/LPTokenizeFacet.sol";
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
 * @title LPTokenizeFacetTest
 * @notice Tests for LPTokenizeFacet — LP position to PT/YT conversion
 */
contract LPTokenizeFacetTest is Test {
    Diamond diamond;
    DiamondCutFacet diamondCutFacet;
    DiamondLoupeFacet diamondLoupeFacet;
    OwnershipFacet ownershipFacet;
    PoolRegistryFacet poolRegistryFacet;
    LiquidityFacet liquidityFacet;
    LPTokenizeFacet lpTokenizeFacet;
    PauseFacet pauseFacet;
    YieldAccumulatorFacet yieldAccumulatorFacet;

    MockTokenizeAdapter mockAdapter;
    MockNFT mockNft;
    MockERC20Unlock token0;
    MockERC20Unlock token1;

    address owner = address(this);
    address user = address(0x1);
    address treasury = address(0x3);

    bytes poolParams;
    bytes32 poolId;
    uint256 constant USER_TOKEN_ID = 42;

    function setUp() public {
        // Deploy mock tokens
        token0 = new MockERC20Unlock("Token0", "TK0");
        token1 = new MockERC20Unlock("Token1", "TK1");

        // Deploy mock NFT
        mockNft = new MockNFT();

        // Deploy facets
        diamondCutFacet = new DiamondCutFacet();
        diamond = new Diamond(owner, address(diamondCutFacet));
        diamondLoupeFacet = new DiamondLoupeFacet();
        ownershipFacet = new OwnershipFacet();
        poolRegistryFacet = new PoolRegistryFacet();
        liquidityFacet = new LiquidityFacet();
        lpTokenizeFacet = new LPTokenizeFacet();
        pauseFacet = new PauseFacet();
        yieldAccumulatorFacet = new YieldAccumulatorFacet();

        // Deploy mock adapter
        mockAdapter = new MockTokenizeAdapter(
            address(token0), address(token1), address(diamond), address(mockNft)
        );

        // Add facets to Diamond
        _addFacets();

        // Setup protocol state
        _setupProtocol();
    }

    function _addFacets() internal {
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](7);

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

        // LPTokenizeFacet
        bytes4[] memory unlockSelectors = new bytes4[](2);
        unlockSelectors[0] = LPTokenizeFacet.tokenizePosition.selector;
        unlockSelectors[1] = LPTokenizeFacet.previewTokenizePosition.selector;
        cut[4] = IDiamondCut.FacetCut({
            facetAddress: address(lpTokenizeFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: unlockSelectors
        });

        // PauseFacet
        bytes4[] memory pauseSelectors = new bytes4[](3);
        pauseSelectors[0] = PauseFacet.pause.selector;
        pauseSelectors[1] = PauseFacet.unpause.selector;
        pauseSelectors[2] = PauseFacet.paused.selector;
        cut[5] = IDiamondCut.FacetCut({
            facetAddress: address(pauseFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: pauseSelectors
        });

        // YieldAccumulatorFacet (syncCheckpoint is called by YT token on mint)
        bytes4[] memory yieldSelectors = new bytes4[](1);
        yieldSelectors[0] = YieldAccumulatorFacet.syncCheckpoint.selector;
        cut[6] = IDiamondCut.FacetCut({
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

        // Pool params (used for both registration and unlock)
        poolParams = abi.encode(address(0xB001));
        poolId = keccak256(abi.encode(address(mockAdapter), poolParams));

        // Mint NFT to user
        mockNft.mint(user, USER_TOKEN_ID);

        // Give adapter some tokens to return (simulates withdrawal from position)
        token0.mint(address(mockAdapter), 10000e18);
        token1.mint(address(mockAdapter), 10000e18);
    }

    // Shorthand helpers
    function tokenize() internal view returns (LPTokenizeFacet) {
        return LPTokenizeFacet(address(diamond));
    }

    function pause() internal view returns (PauseFacet) {
        return PauseFacet(address(diamond));
    }

    function registry() internal view returns (PoolRegistryFacet) {
        return PoolRegistryFacet(address(diamond));
    }

    function liquidity() internal view returns (LiquidityFacet) {
        return LiquidityFacet(address(diamond));
    }

    // ================================================================
    //                    VALIDATION TESTS
    // ================================================================

    function test_TokenizePosition_RevertsWhenPaused() public {
        // Register pool first so we can test pause
        registry().registerPool(address(mockAdapter), poolParams, address(token0));

        pause().pause();

        vm.startPrank(user);
        mockNft.approve(address(diamond), USER_TOKEN_ID);

        vm.expectRevert(); // LibPause reverts
        tokenize().tokenizePosition(address(mockAdapter), poolParams, address(token0), USER_TOKEN_ID, 10000);
        vm.stopPrank();
    }

    function test_TokenizePosition_RevertsOnZeroPercent() public {
        vm.startPrank(user);
        mockNft.approve(address(diamond), USER_TOKEN_ID);

        vm.expectRevert(abi.encodeWithSelector(LPTokenizeFacet.InvalidPercentBps.selector, uint16(0)));
        tokenize().tokenizePosition(address(mockAdapter), poolParams, address(token0), USER_TOKEN_ID, 0);
        vm.stopPrank();
    }

    function test_TokenizePosition_RevertsOnPercentOver10000() public {
        vm.startPrank(user);
        mockNft.approve(address(diamond), USER_TOKEN_ID);

        vm.expectRevert(abi.encodeWithSelector(LPTokenizeFacet.InvalidPercentBps.selector, uint16(10001)));
        tokenize().tokenizePosition(address(mockAdapter), poolParams, address(token0), USER_TOKEN_ID, 10001);
        vm.stopPrank();
    }

    function test_TokenizePosition_RevertsOnBannedPool() public {
        // Register and ban pool
        registry().registerPool(address(mockAdapter), poolParams, address(token0));
        registry().banPool(poolId);

        vm.startPrank(user);
        mockNft.approve(address(diamond), USER_TOKEN_ID);

        vm.expectRevert(abi.encodeWithSelector(LPTokenizeFacet.PoolBanned.selector, poolId));
        tokenize().tokenizePosition(address(mockAdapter), poolParams, address(token0), USER_TOKEN_ID, 10000);
        vm.stopPrank();
    }

    function test_TokenizePosition_RevertsOnZeroLiquidityReturned() public {
        // Create adapter that returns zero liquidity
        MockTokenizeAdapterZeroLiq zeroAdapter =
            new MockTokenizeAdapterZeroLiq(address(token0), address(token1), address(diamond), address(mockNft));
        PoolRegistryFacet(address(diamond)).approveAdapter(address(zeroAdapter));

        bytes memory zeroPoolParams = abi.encode(address(0xC001));
        PoolRegistryFacet(address(diamond)).registerPool(address(zeroAdapter), zeroPoolParams, address(token0));

        vm.startPrank(user);
        mockNft.approve(address(diamond), USER_TOKEN_ID);

        vm.expectRevert(LPTokenizeFacet.ZeroLiquidityReturned.selector);
        tokenize().tokenizePosition(address(zeroAdapter), zeroPoolParams, address(token0), USER_TOKEN_ID, 10000);
        vm.stopPrank();
    }

    // ================================================================
    //                  AUTO-REGISTRATION TESTS
    // ================================================================

    function test_TokenizePosition_AutoRegistersPool() public {
        // Pool should NOT exist yet
        assertFalse(registry().poolExists(poolId));

        vm.startPrank(user);
        mockNft.approve(address(diamond), USER_TOKEN_ID);

        (uint256 pt, uint256 yt) =
            tokenize().tokenizePosition(address(mockAdapter), poolParams, address(token0), USER_TOKEN_ID, 10000);
        vm.stopPrank();

        // Pool should now exist
        assertTrue(registry().poolExists(poolId));
        assertGt(pt, 0);
        assertGt(yt, 0);
    }

    function test_TokenizePosition_SkipsRegistrationIfPoolExists() public {
        // Pre-register pool
        registry().registerPool(address(mockAdapter), poolParams, address(token0));
        assertTrue(registry().poolExists(poolId));

        vm.startPrank(user);
        mockNft.approve(address(diamond), USER_TOKEN_ID);

        // Should succeed without trying to re-register
        (uint256 pt, uint256 yt) =
            tokenize().tokenizePosition(address(mockAdapter), poolParams, address(token0), USER_TOKEN_ID, 10000);
        vm.stopPrank();

        assertGt(pt, 0);
        assertGt(yt, 0);
    }

    function test_TokenizePosition_AutoRegistrationFailsBubbles() public {
        // Use an unapproved adapter — registration should fail
        MockTokenizeAdapter unapprovedAdapter =
            new MockTokenizeAdapter(address(token0), address(token1), address(diamond), address(mockNft));

        vm.startPrank(user);
        mockNft.approve(address(diamond), USER_TOKEN_ID);

        vm.expectRevert(); // PoolRegistrationFailed wrapping AdapterNotApproved
        tokenize().tokenizePosition(address(unapprovedAdapter), poolParams, address(token0), USER_TOKEN_ID, 10000);
        vm.stopPrank();
    }

    // ================================================================
    //                    CORE FLOW TESTS
    // ================================================================

    function test_TokenizePosition_FullUnlock_CreatesCycleAndMints() public {
        vm.startPrank(user);
        mockNft.approve(address(diamond), USER_TOKEN_ID);

        (uint256 ptAmount, uint256 ytAmount) =
            tokenize().tokenizePosition(address(mockAdapter), poolParams, address(token0), USER_TOKEN_ID, 10000);
        vm.stopPrank();

        // Should have created cycle 1
        assertEq(registry().getCurrentCycleId(poolId), 1);
        assertTrue(liquidity().hasActiveCycle(poolId));

        // Get PT/YT addresses
        address ptToken = registry().getCycleInfo(poolId, 1).ptToken;
        address ytToken = registry().getCycleInfo(poolId, 1).ytToken;

        // User should hold PT and YT
        assertEq(IERC20(ptToken).balanceOf(user), ptAmount);
        assertEq(IERC20(ytToken).balanceOf(user), ytAmount);
        assertEq(ptAmount, ytAmount); // PT and YT minted equally
    }

    function test_TokenizePosition_PartialUnlock_50Percent() public {
        vm.startPrank(user);
        mockNft.approve(address(diamond), USER_TOKEN_ID);

        (uint256 ptFull,) =
            tokenize().tokenizePosition(address(mockAdapter), poolParams, address(token0), USER_TOKEN_ID, 10000);
        vm.stopPrank();

        // Deploy a second test with 50%
        MockNFT mockNft2 = new MockNFT();
        MockTokenizeAdapter mockAdapter2 =
            new MockTokenizeAdapter(address(token0), address(token1), address(diamond), address(mockNft2));

        PoolRegistryFacet(address(diamond)).approveAdapter(address(mockAdapter2));
        token0.mint(address(mockAdapter2), 10000e18);
        token1.mint(address(mockAdapter2), 10000e18);

        bytes memory poolParams2 = abi.encode(address(0xB002));
        address user2 = address(0x2);
        mockNft2.mint(user2, 99);

        vm.startPrank(user2);
        mockNft2.approve(address(diamond), 99);

        (uint256 ptHalf,) =
            tokenize().tokenizePosition(address(mockAdapter2), poolParams2, address(token0), 99, 5000);
        vm.stopPrank();

        // 50% should give approximately half the PT (mock returns proportional amounts)
        assertEq(ptHalf, ptFull / 2);
    }

    function test_TokenizePosition_UpdatesTotalLiquidity() public {
        // Pre-register pool
        registry().registerPool(address(mockAdapter), poolParams, address(token0));

        vm.startPrank(user);
        mockNft.approve(address(diamond), USER_TOKEN_ID);

        tokenize().tokenizePosition(address(mockAdapter), poolParams, address(token0), USER_TOKEN_ID, 10000);
        vm.stopPrank();

        // Total liquidity should be updated
        uint128 total = liquidity().getTotalLiquidity(poolId);
        assertGt(total, 0);
    }

    function test_TokenizePosition_NFTTransferredBackToUser() public {
        vm.startPrank(user);
        mockNft.approve(address(diamond), USER_TOKEN_ID);

        tokenize().tokenizePosition(address(mockAdapter), poolParams, address(token0), USER_TOKEN_ID, 10000);
        vm.stopPrank();

        // NFT should be back with the user (mock adapter returns it)
        assertEq(mockNft.ownerOf(USER_TOKEN_ID), user);
    }

    function test_TokenizePosition_DustRefundedToUser() public {
        // Adapter leaves some dust on Diamond
        // After unlock, dust should be refunded to user
        uint256 userToken0Before = token0.balanceOf(user);
        uint256 userToken1Before = token1.balanceOf(user);

        vm.startPrank(user);
        mockNft.approve(address(diamond), USER_TOKEN_ID);

        tokenize().tokenizePosition(address(mockAdapter), poolParams, address(token0), USER_TOKEN_ID, 10000);
        vm.stopPrank();

        // Mock adapter sends 1e18 dust to Diamond for each token
        // User should receive the dust
        uint256 userToken0After = token0.balanceOf(user);
        uint256 userToken1After = token1.balanceOf(user);

        assertEq(userToken0After - userToken0Before, 1e18); // dust refunded
        assertEq(userToken1After - userToken1Before, 1e18); // dust refunded
    }

    // ================================================================
    //                      EVENT TESTS
    // ================================================================

    function test_TokenizePosition_EmitsLPTokenizedEvent() public {
        // Pre-register pool
        registry().registerPool(address(mockAdapter), poolParams, address(token0));

        vm.startPrank(user);
        mockNft.approve(address(diamond), USER_TOKEN_ID);

        vm.expectEmit(true, true, true, false);
        emit LPTokenizeFacet.LPTokenized(poolId, 1, user, USER_TOKEN_ID, 10000, 0, 0, 0);

        tokenize().tokenizePosition(address(mockAdapter), poolParams, address(token0), USER_TOKEN_ID, 10000);
        vm.stopPrank();
    }

    // ================================================================
    //                  CRITICAL EDGE CASES
    // ================================================================

    function test_TokenizePosition_RevertsWhenNFTNotApproved() public {
        registry().registerPool(address(mockAdapter), poolParams, address(token0));

        vm.startPrank(user);
        // Deliberately NOT approving the NFT

        vm.expectRevert(); // transferFrom should revert
        tokenize().tokenizePosition(address(mockAdapter), poolParams, address(token0), USER_TOKEN_ID, 10000);
        vm.stopPrank();
    }

    function test_TokenizePosition_RevertsWhenCallerDoesNotOwnNFT() public {
        registry().registerPool(address(mockAdapter), poolParams, address(token0));

        address attacker = address(0xBAD);

        vm.startPrank(attacker);
        // Attacker approves Diamond but doesn't own the NFT (user does)
        // transferFrom(attacker -> adapter) should fail because attacker != owner

        vm.expectRevert(); // "Not owner" from MockNFT
        tokenize().tokenizePosition(address(mockAdapter), poolParams, address(token0), USER_TOKEN_ID, 10000);
        vm.stopPrank();
    }

    function test_TokenizePosition_MultipleUnlocksAccumulateLiquidity() public {
        registry().registerPool(address(mockAdapter), poolParams, address(token0));

        // First unlock
        vm.startPrank(user);
        mockNft.approve(address(diamond), USER_TOKEN_ID);
        tokenize().tokenizePosition(address(mockAdapter), poolParams, address(token0), USER_TOKEN_ID, 10000);
        vm.stopPrank();

        uint128 totalAfterFirst = liquidity().getTotalLiquidity(poolId);

        // Second unlock (different user, different NFT, same pool)
        address user2 = address(0x2);
        uint256 tokenId2 = 99;
        mockNft.mint(user2, tokenId2);

        vm.startPrank(user2);
        mockNft.approve(address(diamond), tokenId2);
        tokenize().tokenizePosition(address(mockAdapter), poolParams, address(token0), tokenId2, 10000);
        vm.stopPrank();

        uint128 totalAfterSecond = liquidity().getTotalLiquidity(poolId);

        // Total liquidity should have doubled
        assertEq(totalAfterSecond, totalAfterFirst * 2);
    }

    function test_TokenizePosition_CreatesNewCycleAfterMaturity() public {
        registry().registerPool(address(mockAdapter), poolParams, address(token0));

        // First unlock — creates cycle 1
        vm.startPrank(user);
        mockNft.approve(address(diamond), USER_TOKEN_ID);
        tokenize().tokenizePosition(address(mockAdapter), poolParams, address(token0), USER_TOKEN_ID, 10000);
        vm.stopPrank();

        assertEq(registry().getCurrentCycleId(poolId), 1);
        address ptCycle1 = registry().getCycleInfo(poolId, 1).ptToken;

        // Fast forward past maturity (90+ days)
        vm.warp(block.timestamp + 91 days);

        // Second unlock — should create cycle 2
        uint256 tokenId2 = 77;
        address user2 = address(0x2);
        mockNft.mint(user2, tokenId2);

        vm.startPrank(user2);
        mockNft.approve(address(diamond), tokenId2);
        tokenize().tokenizePosition(address(mockAdapter), poolParams, address(token0), tokenId2, 10000);
        vm.stopPrank();

        assertEq(registry().getCurrentCycleId(poolId), 2);
        address ptCycle2 = registry().getCycleInfo(poolId, 2).ptToken;

        // Different PT tokens for different cycles
        assertTrue(ptCycle1 != ptCycle2);
    }

    function test_TokenizePosition_MinimumPercent_1Bps() public {
        registry().registerPool(address(mockAdapter), poolParams, address(token0));

        vm.startPrank(user);
        mockNft.approve(address(diamond), USER_TOKEN_ID);

        // 1 bps = 0.01% — should succeed but return very small amounts
        (uint256 pt, uint256 yt) =
            tokenize().tokenizePosition(address(mockAdapter), poolParams, address(token0), USER_TOKEN_ID, 1);
        vm.stopPrank();

        // With FULL_LIQUIDITY = 1000e6, 0.01% = 100000 (100_000 units)
        // Amounts should be proportionally tiny but non-zero
        assertGt(pt, 0);
        assertGt(yt, 0);
    }

    function test_TokenizePosition_AutoRegistrationFailsWithUnapprovedQuoteToken() public {
        // token1 is NOT an approved quote token
        vm.startPrank(user);
        mockNft.approve(address(diamond), USER_TOKEN_ID);

        // Auto-registration with unapproved quoteToken should fail
        vm.expectRevert(); // PoolRegistrationFailed wrapping QuoteTokenNotApproved
        tokenize().tokenizePosition(address(mockAdapter), poolParams, address(token1), USER_TOKEN_ID, 10000);
        vm.stopPrank();
    }

    function test_TokenizePosition_PTYTAmountsAreConsistentWithValueCalculation() public {
        registry().registerPool(address(mockAdapter), poolParams, address(token0));

        vm.startPrank(user);
        mockNft.approve(address(diamond), USER_TOKEN_ID);

        (uint256 ptAmount, uint256 ytAmount) =
            tokenize().tokenizePosition(address(mockAdapter), poolParams, address(token0), USER_TOKEN_ID, 10000);
        vm.stopPrank();

        // MockAdapter returns 500e18 of each token at 1:1 price (sqrtPriceX96 = 2^96)
        // Value in quote (token0) = amount0 + amount1 * (1/price) = 500e18 + 500e18 = 1000e18
        // Both PT and YT should be 1000e18
        assertEq(ptAmount, 1000e18);
        assertEq(ytAmount, 1000e18);
        assertEq(ptAmount, ytAmount);
    }

    function test_TokenizePosition_CombinedWithAddLiquidity_SamePool() public {
        registry().registerPool(address(mockAdapter), poolParams, address(token0));

        // First: regular addLiquidity
        token0.mint(user, 10000e18);
        token1.mint(user, 10000e18);

        vm.startPrank(user);
        token0.approve(address(diamond), 100e18);
        token1.approve(address(diamond), 100e18);
        liquidity().addLiquidity(poolId, 100e18, 100e18);
        vm.stopPrank();

        uint128 totalAfterAdd = liquidity().getTotalLiquidity(poolId);
        assertGt(totalAfterAdd, 0);

        // Second: unlock position into same pool
        vm.startPrank(user);
        mockNft.approve(address(diamond), USER_TOKEN_ID);
        tokenize().tokenizePosition(address(mockAdapter), poolParams, address(token0), USER_TOKEN_ID, 10000);
        vm.stopPrank();

        uint128 totalAfterUnlock = liquidity().getTotalLiquidity(poolId);

        // Total liquidity should have increased
        assertGt(totalAfterUnlock, totalAfterAdd);
    }

    // ================================================================
    //                    REENTRANCY TEST
    // ================================================================

    function test_TokenizePosition_RevertsOnReentrantCall() public {
        // Deploy reentrant adapter
        ReentrantTokenizeAdapter reentrantAdapter =
            new ReentrantTokenizeAdapter(address(token0), address(token1), address(diamond), address(mockNft));
        PoolRegistryFacet(address(diamond)).approveAdapter(address(reentrantAdapter));
        token0.mint(address(reentrantAdapter), 10000e18);
        token1.mint(address(reentrantAdapter), 10000e18);

        bytes memory rePoolParams = abi.encode(address(0xD001));

        vm.startPrank(user);
        mockNft.approve(address(diamond), USER_TOKEN_ID);

        vm.expectRevert(); // Reentrancy guard should catch it
        tokenize().tokenizePosition(address(reentrantAdapter), rePoolParams, address(token0), USER_TOKEN_ID, 10000);
        vm.stopPrank();
    }
}

// ================================================================
//                     MOCK CONTRACTS
// ================================================================

contract MockERC20Unlock is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @notice Minimal ERC721 mock for LP position NFTs
 */
contract MockNFT {
    mapping(uint256 => address) private _owners;
    mapping(uint256 => address) private _approvals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    function mint(address to, uint256 tokenId) external {
        _owners[tokenId] = to;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return _owners[tokenId];
    }

    function approve(address to, uint256 tokenId) external {
        require(_owners[tokenId] == msg.sender || _operatorApprovals[_owners[tokenId]][msg.sender], "Not authorized");
        _approvals[tokenId] = to;
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operatorApprovals[msg.sender][operator] = approved;
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(
            _owners[tokenId] == from,
            "Not owner"
        );
        require(
            msg.sender == from || msg.sender == _approvals[tokenId] || _operatorApprovals[from][msg.sender],
            "Not approved"
        );
        _owners[tokenId] = to;
        _approvals[tokenId] = address(0);
    }
}

/**
 * @notice Mock adapter that simulates tokenize operations
 * @dev Returns configurable liquidity/amounts, transfers NFT back, sends dust
 */
contract MockTokenizeAdapter is ILiquidityAdapter {
    address public immutable token0;
    address public immutable token1;
    address public immutable diamond;
    address public immutable nft;

    // Default return values for 100% tokenize
    uint128 public constant FULL_LIQUIDITY = 1000e6;
    uint256 public constant FULL_AMOUNT0 = 500e18;
    uint256 public constant FULL_AMOUNT1 = 500e18;
    uint256 public constant DUST_AMOUNT = 1e18;

    constructor(address _token0, address _token1, address _diamond, address _nft) {
        token0 = _token0;
        token1 = _token1;
        diamond = _diamond;
        nft = _nft;
    }

    function tokenizePosition(bytes calldata tokenizeParams)
        external
        override
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        (, uint256 userTokenId, uint16 percentBps, address user) =
            abi.decode(tokenizeParams, (bytes, uint256, uint16, address));

        // Calculate proportional amounts based on percent
        liquidity = uint128(uint256(FULL_LIQUIDITY) * percentBps / 10000);
        amount0 = FULL_AMOUNT0 * percentBps / 10000;
        amount1 = FULL_AMOUNT1 * percentBps / 10000;

        // Transfer NFT back to user
        MockNFT(nft).transferFrom(address(this), user, userTokenId);

        // Transfer amounts to Diamond (simulating deposit into protocol position)
        // In real adapter, tokens go into the pool. Diamond gets nothing except dust.
        // But for value calculation, we need the adapter to report amount0/amount1.

        // Send dust to Diamond to test refund
        IERC20(token0).transfer(diamond, DUST_AMOUNT);
        IERC20(token1).transfer(diamond, DUST_AMOUNT);

        return (liquidity, amount0, amount1);
    }

    // Required ILiquidityAdapter stubs
    function addLiquidity(bytes calldata, uint256 amount0, uint256 amount1)
        external
        override
        returns (uint128, uint256, uint256)
    {
        uint256 a0 = amount0 / 2;
        uint256 a1 = amount1 / 2;
        IERC20(token0).transferFrom(msg.sender, address(this), a0);
        IERC20(token1).transferFrom(msg.sender, address(this), a1);
        return (uint128((a0 + a1) / 2), a0, a1);
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
        return FULL_LIQUIDITY;
    }

    function protocolId() external pure override returns (string memory) {
        return "MOCK";
    }

    function protocolAddress() external view override returns (address) {
        return address(this);
    }

    function positionNftAddress() external view override returns (address) {
        return nft;
    }

    function previewAddLiquidity(bytes calldata, uint256, uint256)
        external
        pure
        override
        returns (uint128, uint256, uint256)
    {
        return (0, 0, 0);
    }

    function calculateOptimalAmount1(uint256, bytes calldata) external pure override returns (uint256) {
        return 0;
    }

    function calculateOptimalAmount0(uint256, bytes calldata) external pure override returns (uint256) {
        return 0;
    }

    function getPoolPrice(bytes calldata) external pure override returns (uint160, int24) {
        // Return a reasonable sqrtPriceX96 for 1:1 price
        // sqrtPriceX96 = sqrt(1) * 2^96 = 2^96 = 79228162514264337593543950336
        return (79228162514264337593543950336, 0);
    }

    function getPoolFee(bytes calldata) external pure override returns (uint24) {
        return 3000;
    }

    function getPositionValue(bytes calldata) external pure override returns (uint256, uint256) {
        return (FULL_AMOUNT0, FULL_AMOUNT1);
    }

    function getPoolTotalValue(bytes calldata) external pure override returns (uint256, uint256) {
        return (FULL_AMOUNT0 * 10, FULL_AMOUNT1 * 10);
    }
}

/**
 * @notice Mock adapter that returns zero liquidity (for error testing)
 */
contract MockTokenizeAdapterZeroLiq is ILiquidityAdapter {
    address public immutable token0;
    address public immutable token1;
    address public immutable diamond;
    address public immutable nft;

    constructor(address _token0, address _token1, address _diamond, address _nft) {
        token0 = _token0;
        token1 = _token1;
        diamond = _diamond;
        nft = _nft;
    }

    function tokenizePosition(bytes calldata tokenizeParams)
        external
        override
        returns (uint128, uint256, uint256)
    {
        (, uint256 userTokenId,, address user) =
            abi.decode(tokenizeParams, (bytes, uint256, uint16, address));
        MockNFT(nft).transferFrom(address(this), user, userTokenId);
        return (0, 0, 0); // Zero liquidity
    }

    function addLiquidity(bytes calldata, uint256, uint256) external pure override returns (uint128, uint256, uint256) {
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
    function positionNftAddress() external view override returns (address) {
        return nft;
    }
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
        return (79228162514264337593543950336, 0);
    }
    function getPoolFee(bytes calldata) external pure override returns (uint24) {
        return 3000;
    }
    function getPositionValue(bytes calldata) external pure override returns (uint256, uint256) {
        return (0, 0);
    }
    function getPoolTotalValue(bytes calldata) external pure override returns (uint256, uint256) {
        return (0, 0);
    }
}

/**
 * @notice Adapter that attempts to re-enter the Diamond during tokenize
 */
contract ReentrantTokenizeAdapter is ILiquidityAdapter {
    address public immutable token0;
    address public immutable token1;
    address public immutable diamond;
    address public immutable nft;

    constructor(address _token0, address _token1, address _diamond, address _nft) {
        token0 = _token0;
        token1 = _token1;
        diamond = _diamond;
        nft = _nft;
    }

    function tokenizePosition(bytes calldata tokenizeParams)
        external
        override
        returns (uint128, uint256, uint256)
    {
        // Attempt to re-enter the Diamond
        bytes memory rePoolParams = abi.encode(address(0xD001));
        LPTokenizeFacet(diamond).tokenizePosition(
            address(this), rePoolParams, token0, 99, 10000
        );
        return (1000, 500e18, 500e18);
    }

    function addLiquidity(bytes calldata, uint256, uint256) external pure override returns (uint128, uint256, uint256) {
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
    function positionNftAddress() external view override returns (address) {
        return nft;
    }
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
        return (79228162514264337593543950336, 0);
    }
    function getPoolFee(bytes calldata) external pure override returns (uint24) {
        return 3000;
    }
    function getPositionValue(bytes calldata) external pure override returns (uint256, uint256) {
        return (0, 0);
    }
    function getPoolTotalValue(bytes calldata) external pure override returns (uint256, uint256) {
        return (0, 0);
    }
}
