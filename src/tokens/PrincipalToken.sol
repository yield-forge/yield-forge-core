// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {TokenBase} from "./TokenBase.sol";

/**
 * @title Principal Token (PT)
 * @notice Represents the principal component of a tokenized yield position
 * @dev Minimal implementation - extended functionality added as needed
 *
 * TOKEN NAMING: YF-PT-[HASH]-[MATURITY]
 * Example: "YF-PT-A3F2E9-JAN2025"
 * - YF = Yield Forge (brand)
 * - PT = Principal Token
 * - A3F2E9 = Pool hash (first 6 chars of poolId)
 * - JAN2025 = Maturity date
 *
 * WHAT IS PT:
 * - Represents the principal (original deposit amount)
 * - After maturity: redeemable for proportional share of pool (both tokens)
 * - Before maturity: can be traded on secondary market
 *
 * LIFECYCLE:
 * 1. User deposits tokens → receives equal amounts of PT + YT
 * 2. PT can be traded or held until maturity
 * 3. After maturity: redeem PT for underlying token pair
 */
contract PrincipalToken is TokenBase {
    /**
     * @notice Create a new Principal Token
     * @param name Token name (e.g., "YF-PT-A3F2E9-JAN2025")
     * @param symbol Token symbol (same as name)
     * @param _diamond Address of YieldForge Diamond contract
     * @param _poolId Unique pool identifier
     * @param _cycleId Cycle ID this token belongs to
     * @param _maturityDate When the token matures (Unix timestamp)
     */
    constructor(
        string memory name,
        string memory symbol,
        address _diamond,
        bytes32 _poolId,
        uint256 _cycleId,
        uint256 _maturityDate
    ) TokenBase(name, symbol, _diamond, _poolId, _cycleId, _maturityDate) {}

    // All core functionality inherited from TokenBase
    // Additional PT-specific functions will be added as needed
}
