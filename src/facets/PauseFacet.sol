// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibPause} from "../libraries/LibPause.sol";

/**
 * @title PauseFacet
 * @notice Emergency pause functionality for the Diamond
 * @dev Allows owner to pause/unpause all protected operations.
 *      Optionally, a pause guardian can be set who can only pause (not unpause).
 *
 * Usage in other facets:
 *   function sensitiveOperation() external {
 *       LibPause.requireNotPaused();
 *       // ... operation logic
 *   }
 */
contract PauseFacet {
    // ============ Events ============

    event Paused(address account);
    event Unpaused(address account);
    event PauseGuardianSet(address indexed previousGuardian, address indexed newGuardian);

    // ============ Modifiers ============

    modifier onlyOwner() {
        LibDiamond.enforceIsContractOwner();
        _;
    }

    // ============ External Functions ============

    /**
     * @notice Pause the contract (emergency stop)
     * @dev Can be called by owner OR pause guardian
     */
    function pause() external {
        LibPause.requirePauseAuthority();
        LibPause.requireNotPaused();

        LibPause.PauseStorage storage ps = LibPause.pauseStorage();
        ps.paused = true;

        emit Paused(msg.sender);
    }

    /**
     * @notice Unpause the contract (resume operations)
     * @dev Can ONLY be called by owner (not guardian)
     */
    function unpause() external onlyOwner {
        LibPause.requirePaused();

        LibPause.PauseStorage storage ps = LibPause.pauseStorage();
        ps.paused = false;

        emit Unpaused(msg.sender);
    }

    /**
     * @notice Set the pause guardian address
     * @dev Guardian can pause but not unpause - good for multisig scenarios
     * @param _guardian New guardian address (address(0) to remove)
     */
    function setPauseGuardian(address _guardian) external onlyOwner {
        LibPause.PauseStorage storage ps = LibPause.pauseStorage();

        address previousGuardian = ps.pauseGuardian;
        ps.pauseGuardian = _guardian;

        emit PauseGuardianSet(previousGuardian, _guardian);
    }

    // ============ View Functions ============

    /**
     * @notice Check if contract is paused
     * @return True if paused
     */
    function paused() external view returns (bool) {
        return LibPause.pauseStorage().paused;
    }

    /**
     * @notice Get the pause guardian address
     * @return Guardian address
     */
    function pauseGuardian() external view returns (address) {
        return LibPause.pauseStorage().pauseGuardian;
    }
}
