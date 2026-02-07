// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/******************************************************************************\
* Author: Nick Mudge <nick@perfectabstractions.com> (https://twitter.com/mudgen)
* EIP-2535 Diamonds: https://eips.ethereum.org/EIPS/eip-2535
/******************************************************************************/

/**
 * @title IDiamondLoupe
 * @notice Interface for Diamond introspection (viewing facets and functions)
 * @dev "Loupe" is a jeweler's magnifying glass for examining diamonds.
 *      These functions allow "examining" the Diamond structure.
 *
 * Why this is needed:
 * - Tools (Etherscan, Louper.dev) use these functions for display
 * - Allows programmatically discovering available functions
 * - Required for EIP-2535 compliance
 */
interface IDiamondLoupe {
    /// @notice Structure linking facet address to its functions
    struct Facet {
        address facetAddress;
        bytes4[] functionSelectors;
    }

    /// @notice Get all facets and their functions
    /// @return facets_ Array of Facet structures
    /// @dev Used by tools to display entire Diamond structure
    function facets() external view returns (Facet[] memory facets_);

    /// @notice Get all function selectors for a specific facet
    /// @param _facet Address of the facet contract
    /// @return facetFunctionSelectors_ Array of selectors (bytes4)
    function facetFunctionSelectors(address _facet) external view returns (bytes4[] memory facetFunctionSelectors_);

    /// @notice Get addresses of all facets in the Diamond
    /// @return facetAddresses_ Array of addresses
    function facetAddresses() external view returns (address[] memory facetAddresses_);

    /// @notice Find facet for a specific function selector
    /// @param _functionSelector Function selector (4 bytes)
    /// @return facetAddress_ Facet address or address(0) if not found
    /// @dev Useful for debugging: "which contract handles this function?"
    function facetAddress(bytes4 _functionSelector) external view returns (address facetAddress_);
}
