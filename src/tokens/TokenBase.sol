// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @notice Interface for querying pool information from Diamond
 */
interface IPoolFactory {
    struct PoolInfo {
        address token0;
        address token1;
        uint24 fee;
        int24 tickSpacing;
        bool exists;
    }

    function getPoolInfo(bytes32 poolId) external view returns (PoolInfo memory);
}

/**
 * @title TokenBase
 * @notice Base contract for Principal and Yield tokens
 * @dev Contains only essential functionality needed by the protocol
 *
 * PHILOSOPHY:
 * - Minimal implementation - only what's actually used
 * - No speculative features for future use
 * - Common logic shared between PT and YT
 */
abstract contract TokenBase is ERC20 {
    // ===== IMMUTABLE STATE =====

    /// @notice Address of the YieldForge Diamond contract
    /// @dev Only Diamond can mint/burn tokens
    address public immutable diamond;

    /// @notice Unique identifier for the pool this token belongs to
    bytes32 public immutable poolId;

    /// @notice Cycle ID this token belongs to
    uint256 public immutable cycleId;

    /// @notice Unix timestamp when this cycle matures
    uint256 public immutable maturityDate;

    // ===== ERRORS =====

    error NotAuthorized();
    error ZeroAmount();
    error InvalidMaturityDate();
    error InvalidDiamond();

    // ===== CONSTRUCTOR =====

    /**
     * @param name Token name (e.g., "YF-PT-A3F2E9-JAN2025")
     * @param symbol Token symbol (same as name)
     * @param _diamond Address of YieldForge Diamond contract
     * @param _poolId Unique pool identifier
     * @param _cycleId Cycle ID this token belongs to
     * @param _maturityDate When this cycle matures (Unix timestamp)
     */
    constructor(
        string memory name,
        string memory symbol,
        address _diamond,
        bytes32 _poolId,
        uint256 _cycleId,
        uint256 _maturityDate
    ) ERC20(name, symbol) {
        if (_maturityDate <= block.timestamp) {
            revert InvalidMaturityDate();
        }
        if (_diamond == address(0)) {
            revert InvalidDiamond();
        }

        diamond = _diamond;
        poolId = _poolId;
        cycleId = _cycleId;
        maturityDate = _maturityDate;
    }

    // ===== CORE FUNCTIONS =====

    /**
     * @notice Mint tokens
     * @dev Only callable by Diamond
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external {
        if (msg.sender != diamond) {
            revert NotAuthorized();
        }
        if (amount == 0) {
            revert ZeroAmount();
        }

        _mint(to, amount);
    }

    /**
     * @notice Burn tokens
     * @dev Only callable by Diamond
     * @param from Address to burn from
     * @param amount Amount to burn
     */
    function burn(address from, uint256 amount) external {
        if (msg.sender != diamond) {
            revert NotAuthorized();
        }
        if (amount == 0) {
            revert ZeroAmount();
        }

        _burn(from, amount);
    }

    // ===== VIEW FUNCTIONS =====

    /**
     * @notice Get pool information from Diamond
     * @return Pool details (token0, token1, fee, tickSpacing, exists)
     */
    function getPoolInfo() external view returns (IPoolFactory.PoolInfo memory) {
        return IPoolFactory(diamond).getPoolInfo(poolId);
    }

    /**
     * @notice Get underlying token pair of the pool
     * @return token0 First token address
     * @return token1 Second token address
     */
    function getUnderlyingTokens() external view returns (address token0, address token1) {
        IPoolFactory.PoolInfo memory info = IPoolFactory(diamond).getPoolInfo(poolId);
        return (info.token0, info.token1);
    }

    /**
     * @notice Check if this cycle has matured
     * @return true if current time >= maturity date
     */
    function isMature() external view returns (bool) {
        return block.timestamp >= maturityDate;
    }

    /**
     * @notice Get time remaining until maturity
     * @return Seconds until maturity (0 if already mature)
     */
    function timeUntilMaturity() external view returns (uint256) {
        if (block.timestamp >= maturityDate) {
            return 0;
        }
        return maturityDate - block.timestamp;
    }
}
