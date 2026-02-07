// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * @title ProtocolFees
 * @author Yield Forge Team
 * @notice Library containing all protocol fee constants
 * @dev Fees are immutable constants to ensure transparency.
 *      Any fee change requires contract redeploy, giving users
 *      time to review and exit if needed.
 *
 * FEE STRUCTURE:
 * ----------------------------------
 * 1. Mint Fee: NONE (users receive 100% of PT/YT)
 * 2. Yield Fee: 5% of harvested yield goes to protocol
 *
 * WHY CONSTANTS?
 * --------------
 * Unlike storage variables, constants cannot be changed without
 * a contract upgrade. This provides:
 * - Predictability for users
 * - Transparency (changes visible in new code)
 * - Time for users to react before changes take effect
 */
library ProtocolFees {
    // ============================================================
    //                        CONSTANTS
    // ============================================================

    /// @notice Fee on harvested yield (5% = 500 bps)
    /// @dev Applied when yield is collected via harvestYield()
    /// Protocol receives this % of all yield before distribution to YT holders
    uint256 public constant YIELD_FEE_BPS = 500;

    /// @notice Basis points denominator (100% = 10000)
    /// @dev 1 basis point = 0.01%
    /// 100 bps = 1%, 500 bps = 5%, 10000 bps = 100%
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // ============================================================
    //                        FUNCTIONS
    // ============================================================

    /**
     * @notice Calculate fee amount from a given value
     * @dev Uses basis points for precision
     *
     * Example:
     *   calculateFee(1000, 500) = 50 (5% of 1000)
     *   calculateFee(1000, 100) = 10 (1% of 1000)
     *
     * @param amount The base amount to calculate fee from
     * @param feeBps Fee in basis points
     * @return Fee amount
     */
    function calculateFee(uint256 amount, uint256 feeBps) internal pure returns (uint256) {
        return (amount * feeBps) / BPS_DENOMINATOR;
    }

    /**
     * @notice Calculate yield fee for a given amount
     * @dev Convenience function using YIELD_FEE_BPS
     *
     * @param amount The yield amount
     * @return Protocol fee portion (5% of amount)
     */
    function calculateYieldFee(uint256 amount) internal pure returns (uint256) {
        return calculateFee(amount, YIELD_FEE_BPS);
    }
}
