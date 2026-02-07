// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {LibDiamond} from "../libraries/LibDiamond.sol";

/**
 * @title LibPause
 * @notice Shared storage and utilities for emergency pause functionality
 * @dev Uses Diamond storage pattern for cross-facet pause state
 */
library LibPause {
    // Unique storage slot for pause state
    bytes32 constant PAUSE_STORAGE_POSITION =
        keccak256("yieldforge.pause.storage");

    struct PauseStorage {
        bool paused;
        address pauseGuardian; // Can pause but not unpause (for emergencies)
    }

    function pauseStorage() internal pure returns (PauseStorage storage ps) {
        bytes32 position = PAUSE_STORAGE_POSITION;
        assembly {
            ps.slot := position
        }
    }

    // ============ Errors ============

    error EnforcedPause();
    error ExpectedPause();
    error NotAuthorized();

    // ============ Modifiers as Functions ============

    /**
     * @notice Reverts if contract is paused
     * @dev Use this in facets: LibPause.requireNotPaused();
     */
    function requireNotPaused() internal view {
        if (pauseStorage().paused) {
            revert EnforcedPause();
        }
    }

    /**
     * @notice Reverts if contract is not paused
     */
    function requirePaused() internal view {
        if (!pauseStorage().paused) {
            revert ExpectedPause();
        }
    }

    /**
     * @notice Check if caller is owner or pause guardian
     */
    function requirePauseAuthority() internal view {
        PauseStorage storage ps = pauseStorage();
        if (
            msg.sender != LibDiamond.contractOwner() &&
            msg.sender != ps.pauseGuardian
        ) {
            revert NotAuthorized();
        }
    }
}
