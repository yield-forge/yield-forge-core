// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/******************************************************************************\
* Author: Nick Mudge <nick@perfectabstractions.com> (https://twitter.com/mudgen)
* EIP-2535 Diamonds: https://eips.ethereum.org/EIPS/eip-2535
/******************************************************************************/

/**
 * @title IDiamondCut
 * @notice Interface for adding, replacing, and removing facets in a Diamond
 * @dev Official reference implementation from EIP-2535 author
 *
 * Key concepts:
 * - FacetCut defines which functions (selectors) to add/replace/remove
 * - _init allows executing initialization code after changes
 * - All changes are atomic - either all apply or none
 */
interface IDiamondCut {
    /// @notice Action to perform on facet functions
    /// @dev Add=0: add new functions (selector must not exist)
    ///      Replace=1: replace existing functions (selector must exist)
    ///      Remove=2: remove functions (facetAddress must be address(0))
    enum FacetCutAction {
        Add,
        Replace,
        Remove
    }

    /// @notice Structure describing changes for one facet
    /// @param facetAddress Contract address with logic (address(0) for Remove)
    /// @param action Action: Add, Replace, or Remove
    /// @param functionSelectors Array of function selectors (first 4 bytes of keccak256 signature)
    struct FacetCut {
        address facetAddress;
        FacetCutAction action;
        bytes4[] functionSelectors;
    }

    /// @notice Add/replace/remove functions and optionally execute initialization
    /// @param _diamondCut Array of FacetCut describing changes
    /// @param _init Address of contract for initialization (address(0) if not needed)
    /// @param _calldata Data for calling _init via delegatecall
    function diamondCut(
        FacetCut[] calldata _diamondCut,
        address _init,
        bytes calldata _calldata
    ) external;

    /// @notice Emitted on any facet changes
    event DiamondCut(FacetCut[] _diamondCut, address _init, bytes _calldata);
}
