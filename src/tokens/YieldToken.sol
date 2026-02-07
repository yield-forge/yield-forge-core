// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {TokenBase} from "./TokenBase.sol";

/**
 * @title Yield Token (YT)
 * @notice Represents the yield component of a tokenized yield position
 * @dev Minimal implementation - extended functionality added as needed
 *
 * TOKEN NAMING: YF-YT-[HASH]-[MATURITY]
 * Example: "YF-YT-A3F2E9-JAN2025"
 * - YF = Yield Forge (brand)
 * - YT = Yield Token
 * - A3F2E9 = Pool hash (first 6 chars of poolId)
 * - JAN2025 = Maturity date
 *
 * WHAT IS YT:
 * - Represents rights to yield (swap fees) until maturity
 * - Holders accumulate yield continuously in BOTH pool tokens
 * - After maturity: no new yield, but can claim accumulated
 *
 * LIFECYCLE:
 * 1. User deposits tokens → receives equal amounts of PT + YT
 * 2. YT accumulates yield from swaps (stored in YieldAccumulator)
 * 3. User can claim yield at any time via YieldAccumulatorFacet
 * 4. After maturity: can still claim accumulated yield
 *
 * NOTE: Yield claiming logic is in YieldAccumulatorFacet, not here
 */
contract YieldToken is TokenBase {
    /// @notice Error when trying to burn YT with unclaimed yield
    error UnclaimedYieldExists(uint256 pending0, uint256 pending1);

    /**
     * @notice Create a new Yield Token
     * @param name Token name (e.g., "YF-YT-A3F2E9-JAN2025")
     * @param symbol Token symbol (same as name)
     * @param _diamond Address of YieldForge Diamond contract
     * @param _poolId Unique pool identifier
     * @param _cycleId Cycle ID this token belongs to
     * @param _maturityDate When yield accumulation stops (Unix timestamp)
     */
    constructor(
        string memory name,
        string memory symbol,
        address _diamond,
        bytes32 _poolId,
        uint256 _cycleId,
        uint256 _maturityDate
    ) TokenBase(name, symbol, _diamond, _poolId, _cycleId, _maturityDate) {}

    /**
     * @notice Override _update to handle yield on transfers and burns
     * @dev
     * - On transfer: sync checkpoint for recipient (prevents claiming old yield)
     * - On burn (to == address(0)): REVERT if user has unclaimed yield
     */
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override {
        // Block burn if user has unclaimed yield
        if (to == address(0) && from != address(0)) {
            // Check if there's pending yield for this user
            (uint256 pending0, uint256 pending1) = IYieldAccumulator(diamond)
                .getPendingYield(poolId, cycleId, from);

            if (pending0 > 0 || pending1 > 0) {
                revert UnclaimedYieldExists(pending0, pending1);
            }
        }

        super._update(from, to, amount);

        // Sync checkpoint for recipient (not for burns)
        if (to != address(0)) {
            // Call Diamond to sync checkpoint
            IYieldAccumulator(diamond).syncCheckpoint(poolId, cycleId, to);
        }
    }
}

/**
 * @notice Interface for YieldAccumulatorFacet
 */
interface IYieldAccumulator {
    function syncCheckpoint(
        bytes32 poolId,
        uint256 cycleId,
        address user
    ) external;

    function claimYield(
        bytes32 poolId,
        uint256 cycleId
    ) external returns (uint256 amount0, uint256 amount1);

    function getPendingYield(
        bytes32 poolId,
        uint256 cycleId,
        address user
    ) external view returns (uint256 pending0, uint256 pending1);
}
