// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibPause} from "../libraries/LibPause.sol";
import {LibReentrancyGuard} from "../libraries/LibReentrancyGuard.sol";
import {ILiquidityAdapter} from "../interfaces/ILiquidityAdapter.sol";
import {PrincipalToken} from "../tokens/PrincipalToken.sol";
import {YieldToken} from "../tokens/YieldToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title RedemptionFacet
 * @author Yield Forge Team
 * @notice Handles PT redemption and token upgrades between cycles
 * @dev Works with any liquidity adapter (V4, V3, Curve, etc.)
 *
 * ARCHITECTURE OVERVIEW:
 * ----------------------
 * This facet handles:
 * 1. PT Redemption - Exchange matured PT for underlying tokens
 * 2. PT Upgrade - Convert old cycle PT to new cycle PT
 *
 * REDEMPTION FLOW:
 * ----------------
 * User has PT from cycle N (now matured):
 * 1. User calls redeemPT(poolId, cycleId, amount)
 * 2. Facet verifies cycle has matured
 * 3. PT tokens are burned
 * 4. Adapter removes liquidity from underlying protocol
 * 5. Underlying tokens are transferred to user
 *
 * UPGRADE FLOW:
 * -------------
 * User has PT from cycle N, wants to continue in cycle N+1:
 * 1. User calls upgradePT(poolId, oldCycleId, amount)
 * 2. Old PT is burned
 * 3. Liquidity remains in underlying protocol
 * 4. New cycle PT is minted to user
 *
 * IMPORTANT NOTES:
 * ----------------
 * - Can only redeem AFTER maturity (not before)
 * - Upgrade is only possible if new cycle exists
 * - YT is NOT upgraded - each cycle's yield is separate
 * - User should claim yield before upgrading
 *
 * LIQUIDITY CALCULATION:
 * ----------------------
 * PT amount represents a share of total liquidity:
 *   userLiquidity = (ptAmount * cycle.totalLiquidity) / totalPTSupply
 *
 * This ensures proportional redemption even if liquidity was added
 * at different times during the cycle.
 */
contract RedemptionFacet {
    using SafeERC20 for IERC20;

    // ============================================================
    //                          EVENTS
    // ============================================================

    /**
     * @notice Emitted when PT is redeemed for underlying tokens
     * @param poolId Pool identifier
     * @param cycleId Cycle that was redeemed
     * @param redeemer Address that redeemed
     * @param ptAmount PT tokens burned
     * @param amount0 Token0 received
     * @param amount1 Token1 received
     */
    event PTRedeemed(
        bytes32 indexed poolId,
        uint256 indexed cycleId,
        address indexed redeemer,
        uint256 ptAmount,
        uint256 amount0,
        uint256 amount1
    );

    /**
     * @notice Emitted when PT is upgraded to new cycle
     * @param poolId Pool identifier
     * @param oldCycleId Original cycle
     * @param newCycleId New cycle
     * @param upgrader Address that upgraded
     * @param amount PT tokens upgraded
     */
    event PTUpgraded(
        bytes32 indexed poolId,
        uint256 indexed oldCycleId,
        uint256 indexed newCycleId,
        address upgrader,
        uint256 amount
    );

    // ============================================================
    //                          ERRORS
    // ============================================================

    /// @notice Pool does not exist
    error PoolDoesNotExist(bytes32 poolId);

    /// @notice Cycle does not exist
    error CycleDoesNotExist(bytes32 poolId, uint256 cycleId);

    /// @notice Cycle has not matured yet
    error CycleNotMatured(
        bytes32 poolId,
        uint256 cycleId,
        uint256 maturityDate
    );

    /// @notice No new cycle available for upgrade
    error NoNewCycleAvailable(bytes32 poolId);

    /// @notice Cannot upgrade to same cycle
    error CannotUpgradeToSameCycle();

    /// @notice Zero amount provided
    error ZeroAmount();

    /// @notice Insufficient PT balance
    error InsufficientPTBalance(uint256 requested, uint256 available);

    /// @notice Slippage tolerance exceeded
    error SlippageExceeded(uint256 expected, uint256 received);

    // ============================================================
    //                     MAIN FUNCTIONS
    // ============================================================

    /**
     * @notice Redeem PT tokens for underlying liquidity
     * @dev Only works after cycle maturity
     *
     * FLOW:
     * 1. Verify cycle has matured
     * 2. Calculate user's share of liquidity
     * 3. Preview expected amounts via adapter
     * 4. Burn PT tokens
     * 5. Remove liquidity via adapter
     * 6. Verify slippage and transfer tokens
     *
     * @param poolId Pool identifier
     * @param cycleId Cycle to redeem from
     * @param ptAmount Amount of PT to redeem
     * @param maxSlippageBps Maximum acceptable slippage in basis points (e.g., 100 = 1%)
     * @return amount0 Token0 received
     * @return amount1 Token1 received
     *
     * Example:
     *   // After maturity, with 1% slippage tolerance
     *   (uint256 token0, uint256 token1) = redemption.redeemPT(
     *       poolId,
     *       1,        // cycle 1
     *       100e18,   // redeem 100 PT
     *       100       // 1% slippage (100 bps)
     *   );
     */
    function redeemPT(
        bytes32 poolId,
        uint256 cycleId,
        uint256 ptAmount,
        uint256 maxSlippageBps
    ) external returns (uint256 amount0, uint256 amount1) {
        // ===== SECURITY CHECKS =====
        LibPause.requireNotPaused();
        LibReentrancyGuard._nonReentrantBefore();

        // ===== VALIDATION =====

        if (ptAmount == 0) revert ZeroAmount();

        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        LibAppStorage.PoolInfo storage pool = s.pools[poolId];

        if (!pool.exists) {
            revert PoolDoesNotExist(poolId);
        }

        LibAppStorage.CycleInfo storage cycle = s.cycles[poolId][cycleId];

        if (cycle.cycleId == 0) {
            revert CycleDoesNotExist(poolId, cycleId);
        }

        // Check maturity
        if (block.timestamp < cycle.maturityDate) {
            revert CycleNotMatured(poolId, cycleId, cycle.maturityDate);
        }

        // ===== CALCULATE LIQUIDITY SHARE =====

        PrincipalToken pt = PrincipalToken(cycle.ptToken);
        uint256 totalPTSupply = pt.totalSupply();

        // Check user has enough PT
        uint256 userBalance = pt.balanceOf(msg.sender);
        if (userBalance < ptAmount) {
            revert InsufficientPTBalance(ptAmount, userBalance);
        }

        // Calculate liquidity to remove
        // userLiquidity = (ptAmount * totalLiquidity) / totalPTSupply
        uint128 liquidityToRemove = uint128(
            (ptAmount * uint256(cycle.totalLiquidity)) / totalPTSupply
        );

        // ===== BURN PT =====

        pt.burn(msg.sender, ptAmount);

        // ===== REMOVE LIQUIDITY VIA ADAPTER =====

        ILiquidityAdapter adapter = ILiquidityAdapter(pool.adapter);

        // ===== PREVIEW EXPECTED AMOUNTS =====
        (uint256 expectedAmount0, uint256 expectedAmount1) = adapter
            .previewRemoveLiquidity(liquidityToRemove, pool.poolParams);

        // Calculate minimum amounts based on slippage
        uint256 minAmount0 = (expectedAmount0 * (10000 - maxSlippageBps)) /
            10000;
        uint256 minAmount1 = (expectedAmount1 * (10000 - maxSlippageBps)) /
            10000;

        // ===== REMOVE LIQUIDITY =====
        (amount0, amount1) = adapter.removeLiquidity(
            liquidityToRemove,
            pool.poolParams
        );

        // ===== SLIPPAGE CHECK =====
        if (amount0 < minAmount0) {
            revert SlippageExceeded(minAmount0, amount0);
        }
        if (amount1 < minAmount1) {
            revert SlippageExceeded(minAmount1, amount1);
        }

        // ===== UPDATE CYCLE STATE =====

        cycle.totalLiquidity -= liquidityToRemove;

        // ===== TRANSFER TOKENS TO USER =====

        if (amount0 > 0) {
            IERC20(pool.token0).safeTransfer(msg.sender, amount0);
        }
        if (amount1 > 0) {
            IERC20(pool.token1).safeTransfer(msg.sender, amount1);
        }

        emit PTRedeemed(
            poolId,
            cycleId,
            msg.sender,
            ptAmount,
            amount0,
            amount1
        );

        // ===== REENTRANCY GUARD EXIT =====
        LibReentrancyGuard._nonReentrantAfter();
    }

    /**
     * @notice Redeem PT and receive only the pool's quoteToken
     * @dev Convenience function that redeems PT and swaps non-quote token to quoteToken
     *
     * USE CASE:
     * User wants to exit to a single token (e.g., USDC) without manual swapping.
     * This function:
     * 1. Redeems PT for underlying tokens (token0 + token1)
     * 2. Returns quoteToken portion directly
     * 3. Non-quote token needs to be swapped externally (future: integrate DEX)
     *
     * CURRENT LIMITATION:
     * For MVP, this function only consolidates by returning both tokens
     * with a flag indicating which is the quoteToken.
     * Full zap functionality would require DEX integration.
     *
     * @param poolId Pool identifier
     * @param cycleId Cycle to redeem from
     * @param ptAmount Amount of PT to redeem
     * @return quoteAmount Amount of quoteToken received
     * @return nonQuoteAmount Amount of non-quote token received
     * @return quoteToken Address of the quote token
     * @return nonQuoteToken Address of the non-quote token
     *
     * Example:
     *   // Redeem PT and know which token is quote
     *   (uint256 quote, uint256 other, address quoteAddr, address otherAddr) =
     *       redemption.redeemPTWithZap(poolId, 1, 100e18);
     */
    function redeemPTWithZap(
        bytes32 poolId,
        uint256 cycleId,
        uint256 ptAmount
    )
        external
        returns (
            uint256 quoteAmount,
            uint256 nonQuoteAmount,
            address quoteToken,
            address nonQuoteToken
        )
    {
        // ===== SECURITY CHECKS =====
        LibPause.requireNotPaused();
        LibReentrancyGuard._nonReentrantBefore();

        // ===== VALIDATION =====

        if (ptAmount == 0) revert ZeroAmount();

        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        LibAppStorage.PoolInfo storage pool = s.pools[poolId];

        if (!pool.exists) {
            revert PoolDoesNotExist(poolId);
        }

        LibAppStorage.CycleInfo storage cycle = s.cycles[poolId][cycleId];

        if (cycle.cycleId == 0) {
            revert CycleDoesNotExist(poolId, cycleId);
        }

        // Check maturity
        if (block.timestamp < cycle.maturityDate) {
            revert CycleNotMatured(poolId, cycleId, cycle.maturityDate);
        }

        // ===== CALCULATE LIQUIDITY SHARE =====

        PrincipalToken pt = PrincipalToken(cycle.ptToken);
        uint256 totalPTSupply = pt.totalSupply();

        // Check user has enough PT
        uint256 userBalance = pt.balanceOf(msg.sender);
        if (userBalance < ptAmount) {
            revert InsufficientPTBalance(ptAmount, userBalance);
        }

        // Calculate liquidity to remove
        uint128 liquidityToRemove = uint128(
            (ptAmount * uint256(cycle.totalLiquidity)) / totalPTSupply
        );

        // ===== BURN PT =====

        pt.burn(msg.sender, ptAmount);

        // ===== REMOVE LIQUIDITY VIA ADAPTER =====

        ILiquidityAdapter adapter = ILiquidityAdapter(pool.adapter);

        (uint256 amount0, uint256 amount1) = adapter.removeLiquidity(
            liquidityToRemove,
            pool.poolParams
        );

        // ===== UPDATE CYCLE STATE =====

        cycle.totalLiquidity -= liquidityToRemove;

        // ===== DETERMINE QUOTE AND NON-QUOTE TOKENS =====

        quoteToken = pool.quoteToken;

        if (pool.token0 == quoteToken) {
            // token0 is quote
            quoteAmount = amount0;
            nonQuoteAmount = amount1;
            nonQuoteToken = pool.token1;
        } else {
            // token1 is quote
            quoteAmount = amount1;
            nonQuoteAmount = amount0;
            nonQuoteToken = pool.token0;
        }

        // ===== TRANSFER TOKENS TO USER =====

        if (quoteAmount > 0) {
            IERC20(quoteToken).safeTransfer(msg.sender, quoteAmount);
        }
        if (nonQuoteAmount > 0) {
            IERC20(nonQuoteToken).safeTransfer(msg.sender, nonQuoteAmount);
        }

        emit PTRedeemed(
            poolId,
            cycleId,
            msg.sender,
            ptAmount,
            amount0,
            amount1
        );

        // ===== REENTRANCY GUARD EXIT =====
        LibReentrancyGuard._nonReentrantAfter();
    }

    /**
     * @notice Upgrade PT from old cycle to current cycle
     * @dev Allows users to roll their position without withdrawing
     *
     * IMPORTANT:
     * - YT is NOT upgraded (claim yield separately before upgrading)
     * - Liquidity stays in the underlying protocol
     * - Only works if new cycle exists
     *
     * FLOW:
     * 1. Verify old cycle has matured
     * 2. Verify new cycle exists
     * 3. Burn old PT
     * 4. Mint new PT (same amount)
     * 5. Mint new YT (same amount)
     *
     * @param poolId Pool identifier
     * @param oldCycleId Cycle to upgrade from
     * @param ptAmount Amount of PT to upgrade
     * @return newPtAmount New PT tokens received
     * @return newYtAmount New YT tokens received
     *
     * Example:
     *   // Upgrade from cycle 1 to cycle 2
     *   (uint256 newPT, uint256 newYT) = redemption.upgradePT(
     *       poolId,
     *       1,        // old cycle
     *       100e18    // upgrade 100 PT
     *   );
     */
    function upgradePT(
        bytes32 poolId,
        uint256 oldCycleId,
        uint256 ptAmount
    ) external returns (uint256 newPtAmount, uint256 newYtAmount) {
        // ===== SECURITY CHECKS =====
        LibPause.requireNotPaused();
        LibReentrancyGuard._nonReentrantBefore();

        // ===== VALIDATION =====

        if (ptAmount == 0) revert ZeroAmount();

        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        LibAppStorage.PoolInfo storage pool = s.pools[poolId];

        if (!pool.exists) {
            revert PoolDoesNotExist(poolId);
        }

        LibAppStorage.CycleInfo storage oldCycle = s.cycles[poolId][oldCycleId];

        if (oldCycle.cycleId == 0) {
            revert CycleDoesNotExist(poolId, oldCycleId);
        }

        // Check old cycle has matured
        if (block.timestamp < oldCycle.maturityDate) {
            revert CycleNotMatured(poolId, oldCycleId, oldCycle.maturityDate);
        }

        // Get current cycle
        uint256 currentCycleId = s.currentCycleId[poolId];

        if (currentCycleId == 0 || currentCycleId == oldCycleId) {
            revert NoNewCycleAvailable(poolId);
        }

        LibAppStorage.CycleInfo storage newCycle = s.cycles[poolId][
            currentCycleId
        ];

        // ===== CHECK PT BALANCE =====

        PrincipalToken oldPT = PrincipalToken(oldCycle.ptToken);
        uint256 userBalance = oldPT.balanceOf(msg.sender);

        if (userBalance < ptAmount) {
            revert InsufficientPTBalance(ptAmount, userBalance);
        }

        // ===== BURN OLD PT =====

        oldPT.burn(msg.sender, ptAmount);

        // ===== MINT NEW PT AND YT =====

        // User gets same amount in new cycle
        // No fee for upgrades (fee was already paid on initial mint)
        PrincipalToken(newCycle.ptToken).mint(msg.sender, ptAmount);
        YieldToken(newCycle.ytToken).mint(msg.sender, ptAmount);

        newPtAmount = ptAmount;
        newYtAmount = ptAmount;

        emit PTUpgraded(
            poolId,
            oldCycleId,
            currentCycleId,
            msg.sender,
            ptAmount
        );

        // ===== REENTRANCY GUARD EXIT =====
        LibReentrancyGuard._nonReentrantAfter();
    }

    // ============================================================
    //                      VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Check if a cycle has matured
     * @param poolId Pool identifier
     * @param cycleId Cycle to check
     * @return True if cycle exists and has matured
     */
    function hasMatured(
        bytes32 poolId,
        uint256 cycleId
    ) external view returns (bool) {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        LibAppStorage.CycleInfo storage cycle = s.cycles[poolId][cycleId];

        if (cycle.cycleId == 0) return false;

        return block.timestamp >= cycle.maturityDate;
    }

    /**
     * @notice Calculate how much underlying tokens user would receive
     * @dev Preview function for UI
     *
     * @param poolId Pool identifier
     * @param cycleId Cycle to redeem from
     * @param ptAmount Amount of PT to redeem
     * @return liquidity Amount of liquidity that would be removed
     *
     * NOTE: Actual token amounts depend on pool state at redemption time.
     * Use adapter.getPoolTokens() and pool math for estimates.
     */
    function previewRedemption(
        bytes32 poolId,
        uint256 cycleId,
        uint256 ptAmount
    ) external view returns (uint128 liquidity) {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        LibAppStorage.CycleInfo storage cycle = s.cycles[poolId][cycleId];

        if (cycle.cycleId == 0) return 0;

        PrincipalToken pt = PrincipalToken(cycle.ptToken);
        uint256 totalPTSupply = pt.totalSupply();

        if (totalPTSupply == 0) return 0;

        // Calculate proportional liquidity
        liquidity = uint128(
            (ptAmount * uint256(cycle.totalLiquidity)) / totalPTSupply
        );
    }

    /**
     * @notice Check if upgrade is available for a cycle
     * @param poolId Pool identifier
     * @param oldCycleId Cycle to check
     * @return canUpgrade_ True if upgrade is possible
     * @return newCycleId Target cycle ID (0 if no upgrade available)
     */
    function canUpgrade(
        bytes32 poolId,
        uint256 oldCycleId
    ) external view returns (bool canUpgrade_, uint256 newCycleId) {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        LibAppStorage.CycleInfo storage oldCycle = s.cycles[poolId][oldCycleId];

        // Check old cycle exists and has matured
        if (oldCycle.cycleId == 0) return (false, 0);
        if (block.timestamp < oldCycle.maturityDate) return (false, 0);

        // Check new cycle exists
        uint256 currentCycleId = s.currentCycleId[poolId];
        if (currentCycleId == 0 || currentCycleId == oldCycleId) {
            return (false, 0);
        }

        return (true, currentCycleId);
    }

    /**
     * @notice Get maturity timestamp for a cycle
     * @param poolId Pool identifier
     * @param cycleId Cycle to check
     * @return Maturity timestamp (0 if cycle doesn't exist)
     */
    function getMaturityDate(
        bytes32 poolId,
        uint256 cycleId
    ) external view returns (uint256) {
        return
            LibAppStorage.diamondStorage().cycles[poolId][cycleId].maturityDate;
    }
}
