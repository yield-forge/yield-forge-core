// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibLiquidity} from "../libraries/LibLiquidity.sol";
import {LibPause} from "../libraries/LibPause.sol";
import {LibReentrancyGuard} from "../libraries/LibReentrancyGuard.sol";
import {ILiquidityAdapter} from "../interfaces/ILiquidityAdapter.sol";
import {PrincipalToken} from "../tokens/PrincipalToken.sol";
import {YieldToken} from "../tokens/YieldToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal ERC721 interface for NFT transfers
interface IERC721Minimal {
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/**
 * @title LPTokenizeFacet
 * @author Yield Forge Team
 * @notice Converts existing LP positions to PT/YT tokens in one transaction
 * @dev Thin coordinator facet that orchestrates:
 *      1. Auto-registration of the pool (if not yet registered)
 *      2. Active cycle management
 *      3. NFT transfer from user to adapter
 *      4. adapter.tokenizePosition() call
 *      5. PT/YT minting
 *      6. Dust token refunds
 *
 * USE CASES:
 * - Young projects: tokenize treasury LP capital (sell PT for working capital)
 * - Market makers: get tradeable PT/YT instruments without closing positions
 * - Regular LPs: monetize locked positions via secondary markets
 *
 * REQUIREMENTS:
 * - User must approve their LP NFT to the Diamond contract before calling
 * - Only full-range positions are supported
 * - Supports partial tokenization via percentBps (1-10000)
 *
 * FLOW:
 * 1. User approves NFT to Diamond
 * 2. User calls tokenizePosition(adapter, poolParams, quoteToken, tokenId, percentBps)
 * 3. Facet auto-registers pool if needed (self-call through Diamond dispatch)
 * 4. Facet ensures active cycle exists
 * 5. Facet transfers NFT from user to adapter
 * 6. Adapter: withdraws from user's position, deposits into protocol position
 * 7. Adapter: returns NFT to user (full or reduced position)
 * 8. Facet: mints PT/YT based on value deposited
 * 9. Facet: refunds any dust tokens to user
 */
contract LPTokenizeFacet {
    using SafeERC20 for IERC20;

    // ============================================================
    //                          EVENTS
    // ============================================================

    /**
     * @notice Emitted when an LP position is tokenized into PT/YT
     * @param poolId Pool identifier
     * @param cycleId Active cycle number
     * @param user Address that tokenized their position
     * @param userTokenId NFT token ID of the LP position
     * @param percentBps Percentage of position tokenized (1-10000)
     * @param liquidity LP units added to protocol position
     * @param ptMinted PT tokens minted to user
     * @param ytMinted YT tokens minted to user
     */
    event LPTokenized(
        bytes32 indexed poolId,
        uint256 indexed cycleId,
        address indexed user,
        uint256 userTokenId,
        uint16 percentBps,
        uint256 liquidity,
        uint256 ptMinted,
        uint256 ytMinted
    );

    // ============================================================
    //                          ERRORS
    // ============================================================

    /// @notice Invalid percentage (must be 1-10000)
    error InvalidPercentBps(uint16 percentBps);

    /// @notice Pool is banned
    error PoolBanned(bytes32 poolId);

    /// @notice Adapter returned zero liquidity
    error ZeroLiquidityReturned();

    /// @notice Auto-registration of pool failed
    error PoolRegistrationFailed(bytes returnData);

    // ============================================================
    //                     MAIN FUNCTIONS
    // ============================================================

    /**
     * @notice Tokenize an existing LP position into PT/YT tokens
     * @dev One-click conversion: auto-registers pool, manages cycles, mints tokens
     *
     * IMPORTANT: User must approve their LP NFT to the Diamond before calling!
     *
     * @param adapter Address of the liquidity adapter (V3 or V4)
     * @param poolParams Encoded pool parameters (adapter-specific)
     * @param quoteToken Quote token address (used for auto-registration if pool not exists)
     * @param userTokenId NFT token ID of the user's LP position
     * @param percentBps Percentage of position to tokenize (1 = 0.01%, 10000 = 100%)
     * @return ptAmount PT tokens minted to user
     * @return ytAmount YT tokens minted to user
     */
    function tokenizePosition(
        address adapter,
        bytes calldata poolParams,
        address quoteToken,
        uint256 userTokenId,
        uint16 percentBps
    ) external returns (uint256 ptAmount, uint256 ytAmount) {
        // ===== SECURITY CHECKS =====
        LibPause.requireNotPaused();
        LibReentrancyGuard._nonReentrantBefore();

        // ===== VALIDATION =====
        if (percentBps == 0 || percentBps > 10000) {
            revert InvalidPercentBps(percentBps);
        }

        // ===== COMPUTE POOL ID =====
        bytes32 poolId = keccak256(abi.encode(adapter, poolParams));

        // ===== AUTO-REGISTER POOL IF NEEDED =====
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        LibAppStorage.PoolInfo storage pool = s.pools[poolId];

        if (!pool.exists) {
            // Self-call through Diamond dispatch to registerPool
            // This preserves all validation: adapter approved, pool supported, quoteToken whitelisted
            (bool success, bytes memory returnData) = address(this).call(
                abi.encodeWithSignature(
                    "registerPool(address,bytes,address)",
                    adapter,
                    poolParams,
                    quoteToken
                )
            );
            if (!success) {
                revert PoolRegistrationFailed(returnData);
            }

            // Re-read pool storage after registration
            pool = s.pools[poolId];
        }

        // ===== CHECK POOL NOT BANNED =====
        if (pool.isBanned) {
            revert PoolBanned(poolId);
        }

        // ===== ENSURE ACTIVE CYCLE =====
        LibLiquidity.ensureActiveCycle(poolId);

        // ===== TRANSFER NFT FROM USER TO ADAPTER =====
        address nftContract = ILiquidityAdapter(adapter).positionNftAddress();
        IERC721Minimal(nftContract).transferFrom(msg.sender, adapter, userTokenId);

        // ===== CALL ADAPTER =====
        bytes memory tokenizeParams = abi.encode(poolParams, userTokenId, percentBps, msg.sender);
        (uint128 liquidityReceived, uint256 amount0, uint256 amount1) =
            ILiquidityAdapter(adapter).tokenizePosition(tokenizeParams);

        if (liquidityReceived == 0) {
            revert ZeroLiquidityReturned();
        }

        // ===== UPDATE CYCLE STATE =====
        uint256 cycleId = s.currentCycleId[poolId];
        LibAppStorage.CycleInfo storage cycle = s.cycles[poolId][cycleId];
        cycle.totalLiquidity += liquidityReceived;

        // ===== CALCULATE VALUE AND MINT TOKENS =====
        uint256 valueInQuote = LibLiquidity.calculateValueInQuote(amount0, amount1, pool);

        PrincipalToken(cycle.ptToken).mint(msg.sender, valueInQuote);
        YieldToken(cycle.ytToken).mint(msg.sender, valueInQuote);

        ptAmount = valueInQuote;
        ytAmount = valueInQuote;

        // ===== REFUND DUST TOKENS ON DIAMOND =====
        _refundDust(pool.token0, msg.sender);
        _refundDust(pool.token1, msg.sender);

        // ===== EMIT EVENTS =====
        emit LPTokenized(poolId, cycleId, msg.sender, userTokenId, percentBps, uint256(liquidityReceived), ptAmount, ytAmount);
        LibLiquidity.emitTvlUpdated(poolId, cycleId, pool);

        // ===== REENTRANCY GUARD EXIT =====
        LibReentrancyGuard._nonReentrantAfter();
    }

    // ============================================================
    //                      VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Preview PT/YT tokens that would be minted for tokenizing a position
     * @dev Read-only estimation based on current pool price
     *
     * @param adapter Address of the liquidity adapter
     * @param poolParams Encoded pool parameters
     * @param userTokenId NFT token ID of the user's LP position
     * @param percentBps Percentage of position to tokenize (1-10000)
     * @return expectedPT Expected PT tokens (value in quote, 18 decimals)
     * @return expectedYT Expected YT tokens (value in quote, 18 decimals)
     */
    function previewTokenizePosition(
        address adapter,
        bytes calldata poolParams,
        uint256 userTokenId,
        uint16 percentBps
    ) external view returns (uint256 expectedPT, uint256 expectedYT) {
        bytes32 poolId = keccak256(abi.encode(adapter, poolParams));
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        LibAppStorage.PoolInfo storage pool = s.pools[poolId];

        // If pool is not registered, we can still estimate using adapter's preview
        ILiquidityAdapter adapterContract = ILiquidityAdapter(adapter);

        // Get user's position liquidity
        uint128 posLiquidity = adapterContract.getPositionLiquidity(abi.encode(userTokenId));

        uint128 liquidityToTokenize = uint128(uint256(posLiquidity) * percentBps / 10000);

        // Preview token amounts from removing this liquidity
        (uint256 amount0, uint256 amount1) = adapterContract.previewRemoveLiquidity(
            liquidityToTokenize,
            poolParams
        );

        // Calculate value in quote token
        // If pool is registered, use stored pool info; otherwise estimate from adapter
        if (pool.exists) {
            uint256 valueInQuote = LibLiquidity.calculateValueInQuote(amount0, amount1, pool);
            expectedPT = valueInQuote;
            expectedYT = valueInQuote;
        } else {
            // Pool not registered yet — we need token info from adapter to estimate
            // Return raw amounts as a rough estimate (exact value requires pool registration)
            adapterContract.getPoolTokens(poolParams);
            (uint160 sqrtPriceX96,) = adapterContract.getPoolPrice(poolParams);

            uint256 sqrtPrice = uint256(sqrtPriceX96);

            // Estimate: convert both amounts to token1 terms (simple heuristic)
            // For accurate preview, register the pool first
            uint256 amount0InToken1;
            if (amount0 > 0 && sqrtPrice > 0) {
                uint256 intermediate = (amount0 * sqrtPrice) / (1 << 96);
                amount0InToken1 = (intermediate * sqrtPrice) / (1 << 96);
            }

            // This is a rough estimate — normalized to 18 decimals
            expectedPT = amount1 + amount0InToken1;
            expectedYT = expectedPT;
        }
    }

    // ============================================================
    //                     INTERNAL HELPERS
    // ============================================================

    /**
     * @notice Refund any dust token balance on Diamond to user
     * @param token Token address
     * @param user Recipient address
     */
    function _refundDust(address token, address user) internal {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).safeTransfer(user, balance);
        }
    }
}
