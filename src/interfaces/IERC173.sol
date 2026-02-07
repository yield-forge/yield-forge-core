// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * @title IERC173
 * @notice Standard interface for contract ownership management
 * @dev ERC-173: https://eips.ethereum.org/EIPS/eip-173
 *      Interface ID: 0x7f5828d0
 *
 * Why a standard is needed:
 * - Unified way to determine owner of any contract
 * - Tools can automatically determine access rights
 * - Diamond uses this to protect diamondCut()
 *
 * Security:
 * - Only owner can call diamondCut() to add/remove facets
 * - transferOwnership(address(0)) = renounce ownership (irreversible!)
 */
interface IERC173 {
    /// @notice Emitted when ownership changes
    /// @param previousOwner Previous owner
    /// @param newOwner New owner
    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    /// @notice Get the contract owner address
    /// @return owner_ Owner address
    function owner() external view returns (address owner_);

    /// @notice Transfer ownership to a new address
    /// @param _newOwner New owner (address(0) to renounce ownership)
    /// @dev Only current owner can call
    function transferOwnership(address _newOwner) external;
}
