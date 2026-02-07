// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * @title LibReentrancyGuard
 * @notice Diamond-compatible reentrancy guard using storage pattern
 * @dev Uses a unique storage slot to prevent reentrancy across all facets
 */
library LibReentrancyGuard {
    /// @notice Storage position for reentrancy guard
    bytes32 constant REENTRANCY_GUARD_STORAGE_POSITION = keccak256("yieldforge.reentrancy.guard.storage");

    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    struct ReentrancyStorage {
        uint256 status;
    }

    error ReentrancyGuardReentrantCall();

    function reentrancyStorage() internal pure returns (ReentrancyStorage storage rs) {
        bytes32 position = REENTRANCY_GUARD_STORAGE_POSITION;
        assembly {
            rs.slot := position
        }
    }

    function _initializeReentrancyGuard() internal {
        ReentrancyStorage storage rs = reentrancyStorage();
        if (rs.status == 0) {
            rs.status = NOT_ENTERED;
        }
    }

    function _nonReentrantBefore() internal {
        ReentrancyStorage storage rs = reentrancyStorage();
        // Initialize if not set (for upgrades)
        if (rs.status == 0) {
            rs.status = NOT_ENTERED;
        }
        if (rs.status == ENTERED) {
            revert ReentrancyGuardReentrantCall();
        }
        rs.status = ENTERED;
    }

    function _nonReentrantAfter() internal {
        reentrancyStorage().status = NOT_ENTERED;
    }
}
