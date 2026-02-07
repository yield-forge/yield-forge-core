// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibPause} from "../libraries/LibPause.sol";
import {LibReentrancyGuard} from "../libraries/LibReentrancyGuard.sol";
import {ILiquidityAdapter} from "../interfaces/ILiquidityAdapter.sol";
import {ProtocolFees} from "../libraries/ProtocolFees.sol";
import {YieldToken} from "../tokens/YieldToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title YieldAccumulatorFacet
 * @author Yield Forge Team
 * @notice Manages yield collection and distribution to YT holders
 * @dev Works with any liquidity adapter (V4, V3, Curve, etc.)
 *
 * ARCHITECTURE OVERVIEW:
 * ----------------------
 * This facet handles:
 * 1. Yield Harvesting - Collect fees/rewards from underlying protocols
 * 2. Yield Distribution - Track per-share yield for YT holders
 * 3. Yield Claiming - Allow YT holders to claim their share
 * 4. Checkpoint Sync - Prevent claiming yield from before YT acquisition
 *
 * YIELD PER SHARE MECHANISM:
 * --------------------------
 * Uses a standard "reward per token" pattern:
 *
 * 1. When yield is harvested:
 *    yieldPerShare += (harvestedAmount * PRECISION) / totalYTSupply
 *
 * 2. When user claims:
 *    pending = (yieldPerShare - userCheckpoint) * ytBalance / PRECISION
 *    userCheckpoint = yieldPerShare
 *
 * PRECISION = 1e30 to handle small yields with large supplies.
 *
 * CHECKPOINT SYSTEM:
 * ------------------
 * When a user receives YT (mint or transfer), their checkpoint is set
 * to current yieldPerShare. This prevents claiming yield that accumulated
 * before they held the tokens.
 *
 * Example:
 * - yieldPerShare = 100 (from earlier yields)
 * - User buys YT, checkpoint set to 100
 * - More yield: yieldPerShare = 150
 * - User can claim: (150 - 100) * balance = their share of NEW yield only
 *
 * TWO-TOKEN YIELD:
 * ----------------
 * Uniswap pools earn fees in both tokens. We track separately:
 * - yieldPerShare0 for token0
 * - yieldPerShare1 for token1
 *
 * User receives both tokens when claiming.
 *
 * PROTOCOL FEES:
 * --------------
 * A percentage of harvested yield goes to protocol:
 * - Yield Fee: 5%
 * - Defined in ProtocolFees.sol as immutable constant
 * - Stored separately, withdrawable by fee recipient
 *
 * ANYONE CAN HARVEST:
 * -------------------
 * harvestYield() is permissionless - anyone can trigger yield collection.
 * This allows keepers/bots to ensure regular harvesting.
 */
contract YieldAccumulatorFacet {
    using SafeERC20 for IERC20;

    // ============================================================
    //                        CONSTANTS
    // ============================================================

    /// @notice Precision for yield per share calculations
    /// @dev Using 1e30 to handle small yields with large token supplies
    uint256 private constant PRECISION = 1e30;

    // ============================================================
    //                          EVENTS
    // ============================================================

    /**
     * @notice Emitted when yield is harvested from underlying protocol
     * @param poolId Pool identifier
     * @param cycleId Current cycle
     * @param harvester Address that triggered harvest
     * @param yield0 Token0 yield collected
     * @param yield1 Token1 yield collected
     * @param protocolFee0 Protocol fee from token0
     * @param protocolFee1 Protocol fee from token1
     */
    event YieldHarvested(
        bytes32 indexed poolId,
        uint256 indexed cycleId,
        address indexed harvester,
        uint256 yield0,
        uint256 yield1,
        uint256 protocolFee0,
        uint256 protocolFee1
    );

    /**
     * @notice Emitted when user claims their yield
     * @param poolId Pool identifier
     * @param cycleId Cycle claimed from
     * @param claimer Address that claimed
     * @param amount0 Token0 claimed
     * @param amount1 Token1 claimed
     */
    event YieldClaimed(
        bytes32 indexed poolId, uint256 indexed cycleId, address indexed claimer, uint256 amount0, uint256 amount1
    );

    /**
     * @notice Emitted when user's checkpoint is synced
     * @param poolId Pool identifier
     * @param cycleId Cycle
     * @param user User whose checkpoint was synced
     */
    event CheckpointSynced(bytes32 indexed poolId, uint256 indexed cycleId, address indexed user);

    /**
     * @notice Emitted when protocol fees are withdrawn
     * @param poolId Pool identifier
     * @param cycleId Cycle
     * @param recipient Fee recipient
     * @param amount0 Token0 withdrawn
     * @param amount1 Token1 withdrawn
     */
    event ProtocolFeesWithdrawn(
        bytes32 indexed poolId, uint256 indexed cycleId, address indexed recipient, uint256 amount0, uint256 amount1
    );

    // ============================================================
    //                          ERRORS
    // ============================================================

    /// @notice Pool does not exist
    error PoolDoesNotExist(bytes32 poolId);

    /// @notice Cycle does not exist
    error CycleDoesNotExist(bytes32 poolId, uint256 cycleId);

    /// @notice No yield to claim
    error NoYieldToClaim();

    /// @notice Not authorized (for fee withdrawal)
    error NotAuthorized();

    /// @notice No fees to withdraw
    error NoFeesToWithdraw();

    /// @notice Caller is not the YT token for this cycle
    error OnlyYTToken();

    // ============================================================
    //                     HARVEST FUNCTIONS
    // ============================================================

    /**
     * @notice Harvest yield from underlying protocol
     * @dev Anyone can call this - permissionless
     *
     * FLOW:
     * 1. Call adapter.collectYield() to get fees from underlying
     * 2. Calculate protocol fee portion
     * 3. Update yieldPerShare for remaining yield
     * 4. Store protocol fees for later withdrawal
     *
     * @param poolId Pool identifier
     * @return yield0 Total token0 yield collected
     * @return yield1 Total token1 yield collected
     *
     * Example:
     *   // Anyone can harvest
     *   (uint256 y0, uint256 y1) = yieldAccumulator.harvestYield(poolId);
     */
    function harvestYield(bytes32 poolId) external returns (uint256 yield0, uint256 yield1) {
        // ===== SECURITY CHECKS =====
        LibPause.requireNotPaused();
        LibReentrancyGuard._nonReentrantBefore();

        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        LibAppStorage.PoolInfo storage pool = s.pools[poolId];

        if (!pool.exists) {
            revert PoolDoesNotExist(poolId);
        }

        uint256 cycleId = s.currentCycleId[poolId];
        if (cycleId == 0) {
            revert CycleDoesNotExist(poolId, 0);
        }

        LibAppStorage.CycleInfo storage cycle = s.cycles[poolId][cycleId];
        LibAppStorage.CycleYieldState storage yieldState = s.cycleYieldStates[poolId][cycleId];

        // ===== COLLECT YIELD FROM ADAPTER =====

        ILiquidityAdapter adapter = ILiquidityAdapter(pool.adapter);
        (yield0, yield1) = adapter.collectYield(pool.poolParams);

        // If no yield, return early
        if (yield0 == 0 && yield1 == 0) {
            // FIX: Must reset reentrancy guard before returning!
            LibReentrancyGuard._nonReentrantAfter();
            return (0, 0);
        }

        // ===== CALCULATE PROTOCOL FEE =====

        uint256 protocolFee0 = ProtocolFees.calculateYieldFee(yield0);
        uint256 protocolFee1 = ProtocolFees.calculateYieldFee(yield1);

        uint256 userYield0 = yield0 - protocolFee0;
        uint256 userYield1 = yield1 - protocolFee1;

        // ===== UPDATE YIELD PER SHARE =====

        // Get current YT supply for distribution
        YieldToken yt = YieldToken(cycle.ytToken);
        uint256 totalYTSupply = yt.totalSupply();

        if (totalYTSupply > 0) {
            // Distribute to YT holders proportionally
            yieldState.yieldPerShare0 += (userYield0 * PRECISION) / totalYTSupply;
            yieldState.yieldPerShare1 += (userYield1 * PRECISION) / totalYTSupply;
        }

        // ===== UPDATE STATE =====

        yieldState.totalYieldAccumulated0 += yield0;
        yieldState.totalYieldAccumulated1 += yield1;
        yieldState.totalYTSupply = totalYTSupply;
        yieldState.protocolFee0 += protocolFee0;
        yieldState.protocolFee1 += protocolFee1;
        yieldState.lastHarvestTime = block.timestamp;

        emit YieldHarvested(poolId, cycleId, msg.sender, yield0, yield1, protocolFee0, protocolFee1);

        // ===== REENTRANCY GUARD EXIT =====
        LibReentrancyGuard._nonReentrantAfter();
    }

    // ============================================================
    //                      CLAIM FUNCTIONS
    // ============================================================

    /**
     * @notice Claim accumulated yield for a specific cycle
     * @dev User must hold YT tokens to have claimable yield
     *
     * FLOW:
     * 1. Calculate pending yield based on checkpoint difference
     * 2. Update user checkpoint to current yieldPerShare
     * 3. Transfer tokens to user
     *
     * @param poolId Pool identifier
     * @param cycleId Cycle to claim from
     * @return amount0 Token0 claimed
     * @return amount1 Token1 claimed
     *
     * Example:
     *   // Claim yield from cycle 1
     *   (uint256 token0, uint256 token1) = yieldAccumulator.claimYield(
     *       poolId,
     *       1
     *   );
     */
    function claimYield(bytes32 poolId, uint256 cycleId) external returns (uint256 amount0, uint256 amount1) {
        // ===== SECURITY CHECKS =====
        LibReentrancyGuard._nonReentrantBefore();

        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        LibAppStorage.PoolInfo storage pool = s.pools[poolId];

        if (!pool.exists) {
            revert PoolDoesNotExist(poolId);
        }

        LibAppStorage.CycleInfo storage cycle = s.cycles[poolId][cycleId];
        if (cycle.cycleId == 0) {
            revert CycleDoesNotExist(poolId, cycleId);
        }

        // ===== CALCULATE PENDING YIELD =====

        (amount0, amount1) = _calculatePendingYield(poolId, cycleId, msg.sender);

        if (amount0 == 0 && amount1 == 0) {
            revert NoYieldToClaim();
        }

        // ===== UPDATE CHECKPOINT =====

        LibAppStorage.CycleYieldState storage yieldState = s.cycleYieldStates[poolId][cycleId];
        LibAppStorage.UserYieldCheckpoint storage checkpoint = s.userYieldCheckpoints[poolId][cycleId][msg.sender];

        checkpoint.lastClaimedPerShare0 = yieldState.yieldPerShare0;
        checkpoint.lastClaimedPerShare1 = yieldState.yieldPerShare1;

        // ===== TRANSFER TOKENS =====

        if (amount0 > 0) {
            IERC20(pool.token0).safeTransfer(msg.sender, amount0);
        }
        if (amount1 > 0) {
            IERC20(pool.token1).safeTransfer(msg.sender, amount1);
        }

        emit YieldClaimed(poolId, cycleId, msg.sender, amount0, amount1);

        // ===== REENTRANCY GUARD EXIT =====
        LibReentrancyGuard._nonReentrantAfter();
    }

    /**
     * @notice Sync user's checkpoint to current yieldPerShare
     * @dev Called by YieldToken on transfer/mint to prevent claiming old yield
     *
     * IMPORTANT: This function should only be called by YT token contracts!
     * It's used to set the checkpoint when a user receives YT tokens,
     * ensuring they can't claim yield from before they held the tokens.
     *
     * @param poolId Pool identifier
     * @param cycleId Cycle
     * @param user User address to sync
     */
    function syncCheckpoint(bytes32 poolId, uint256 cycleId, address user) external {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();

        // Verify cycle exists first (H-02 fix)
        LibAppStorage.CycleInfo storage cycle = s.cycles[poolId][cycleId];
        if (cycle.cycleId == 0) {
            revert CycleDoesNotExist(poolId, cycleId);
        }

        // Verify caller is the YT token for this cycle
        // This prevents arbitrary checkpoint manipulation
        if (msg.sender != cycle.ytToken) {
            revert OnlyYTToken();
        }

        LibAppStorage.CycleYieldState storage yieldState = s.cycleYieldStates[poolId][cycleId];
        LibAppStorage.UserYieldCheckpoint storage checkpoint = s.userYieldCheckpoints[poolId][cycleId][user];

        // Set checkpoint to current yieldPerShare
        checkpoint.lastClaimedPerShare0 = yieldState.yieldPerShare0;
        checkpoint.lastClaimedPerShare1 = yieldState.yieldPerShare1;

        emit CheckpointSynced(poolId, cycleId, user);
    }

    // ============================================================
    //                    PROTOCOL FEE FUNCTIONS
    // ============================================================

    /**
     * @notice Withdraw accumulated protocol fees
     * @dev Only callable by protocol fee recipient
     *
     * @param poolId Pool identifier
     * @param cycleId Cycle to withdraw from
     * @return amount0 Token0 fees withdrawn
     * @return amount1 Token1 fees withdrawn
     */
    function withdrawProtocolFees(bytes32 poolId, uint256 cycleId) external returns (uint256 amount0, uint256 amount1) {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();

        // Only fee recipient can withdraw
        if (msg.sender != s.protocolFeeRecipient) {
            revert NotAuthorized();
        }

        LibAppStorage.PoolInfo storage pool = s.pools[poolId];
        if (!pool.exists) {
            revert PoolDoesNotExist(poolId);
        }

        LibAppStorage.CycleYieldState storage yieldState = s.cycleYieldStates[poolId][cycleId];

        amount0 = yieldState.protocolFee0;
        amount1 = yieldState.protocolFee1;

        if (amount0 == 0 && amount1 == 0) {
            revert NoFeesToWithdraw();
        }

        // Reset fees
        yieldState.protocolFee0 = 0;
        yieldState.protocolFee1 = 0;

        // Transfer fees
        if (amount0 > 0) {
            IERC20(pool.token0).safeTransfer(msg.sender, amount0);
        }
        if (amount1 > 0) {
            IERC20(pool.token1).safeTransfer(msg.sender, amount1);
        }

        emit ProtocolFeesWithdrawn(poolId, cycleId, msg.sender, amount0, amount1);
    }

    // ============================================================
    //                   INTERNAL FUNCTIONS
    // ============================================================

    /**
     * @notice Calculate pending yield for a user
     * @dev Internal helper used by claimYield and view functions
     *
     * Formula:
     *   pending = (yieldPerShare - userCheckpoint) * ytBalance / PRECISION
     *
     * @param poolId Pool identifier
     * @param cycleId Cycle
     * @param user User address
     * @return pending0 Pending token0 yield
     * @return pending1 Pending token1 yield
     */
    function _calculatePendingYield(bytes32 poolId, uint256 cycleId, address user)
        internal
        view
        returns (uint256 pending0, uint256 pending1)
    {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();

        LibAppStorage.CycleInfo storage cycle = s.cycles[poolId][cycleId];
        LibAppStorage.CycleYieldState storage yieldState = s.cycleYieldStates[poolId][cycleId];
        LibAppStorage.UserYieldCheckpoint storage checkpoint = s.userYieldCheckpoints[poolId][cycleId][user];

        // Get user's YT balance
        YieldToken yt = YieldToken(cycle.ytToken);
        uint256 ytBalance = yt.balanceOf(user);

        if (ytBalance == 0) {
            return (0, 0);
        }

        // Calculate pending for each token
        uint256 perShareDelta0 = yieldState.yieldPerShare0 - checkpoint.lastClaimedPerShare0;
        uint256 perShareDelta1 = yieldState.yieldPerShare1 - checkpoint.lastClaimedPerShare1;

        pending0 = (perShareDelta0 * ytBalance) / PRECISION;
        pending1 = (perShareDelta1 * ytBalance) / PRECISION;
    }

    // ============================================================
    //                      VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Get pending yield for a user (preview)
     * @param poolId Pool identifier
     * @param cycleId Cycle
     * @param user User address
     * @return pending0 Pending token0 yield
     * @return pending1 Pending token1 yield
     */
    function getPendingYield(bytes32 poolId, uint256 cycleId, address user)
        external
        view
        returns (uint256 pending0, uint256 pending1)
    {
        return _calculatePendingYield(poolId, cycleId, user);
    }

    /**
     * @notice Get yield state for a cycle
     * @param poolId Pool identifier
     * @param cycleId Cycle
     * @return state Yield state struct
     */
    function getYieldState(bytes32 poolId, uint256 cycleId)
        external
        view
        returns (LibAppStorage.CycleYieldState memory state)
    {
        return LibAppStorage.diamondStorage().cycleYieldStates[poolId][cycleId];
    }

    /**
     * @notice Get user's checkpoint for a cycle
     * @param poolId Pool identifier
     * @param cycleId Cycle
     * @param user User address
     * @return checkpoint User's yield checkpoint
     */
    function getUserCheckpoint(bytes32 poolId, uint256 cycleId, address user)
        external
        view
        returns (LibAppStorage.UserYieldCheckpoint memory checkpoint)
    {
        return LibAppStorage.diamondStorage().userYieldCheckpoints[poolId][cycleId][user];
    }

    /**
     * @notice Get total yield accumulated for a cycle
     * @param poolId Pool identifier
     * @param cycleId Cycle
     * @return total0 Total token0 yield
     * @return total1 Total token1 yield
     */
    function getTotalYieldAccumulated(bytes32 poolId, uint256 cycleId)
        external
        view
        returns (uint256 total0, uint256 total1)
    {
        LibAppStorage.CycleYieldState storage state = LibAppStorage.diamondStorage().cycleYieldStates[poolId][cycleId];
        return (state.totalYieldAccumulated0, state.totalYieldAccumulated1);
    }

    /**
     * @notice Get pending protocol fees for a cycle
     * @param poolId Pool identifier
     * @param cycleId Cycle
     * @return fee0 Pending token0 fees
     * @return fee1 Pending token1 fees
     */
    function getPendingProtocolFees(bytes32 poolId, uint256 cycleId)
        external
        view
        returns (uint256 fee0, uint256 fee1)
    {
        LibAppStorage.CycleYieldState storage state = LibAppStorage.diamondStorage().cycleYieldStates[poolId][cycleId];
        return (state.protocolFee0, state.protocolFee1);
    }

    /**
     * @notice Get last harvest timestamp for a cycle
     * @param poolId Pool identifier
     * @param cycleId Cycle
     * @return Timestamp of last harvest (0 if never harvested)
     */
    function getLastHarvestTime(bytes32 poolId, uint256 cycleId) external view returns (uint256) {
        return LibAppStorage.diamondStorage().cycleYieldStates[poolId][cycleId].lastHarvestTime;
    }

    /**
     * @notice Get precision constant used for yield calculations
     * @return PRECISION value (1e30)
     */
    function getYieldPrecision() external pure returns (uint256) {
        return PRECISION;
    }
}
