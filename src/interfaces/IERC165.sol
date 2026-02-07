// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * @title IERC165
 * @notice Standard interface for detecting support of other interfaces
 * @dev ERC-165: https://eips.ethereum.org/EIPS/eip-165
 *
 * How it works:
 * - Each interface has a unique ID (XOR of all function selectors)
 * - A contract can declare support for an interface
 * - Other contracts can check support before calling
 *
 * Example:
 *   bytes4 constant IERC721_ID = 0x80ac58cd;
 *   if (contract.supportsInterface(IERC721_ID)) {
 *       // Safe to call ERC721 functions
 *   }
 */
interface IERC165 {
    /// @notice Check if contract supports an interface
    /// @param interfaceId Interface identifier (4 bytes)
    /// @return true if interface is supported and interfaceId != 0xffffffff
    /// @dev Must use less than 30,000 gas
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}
