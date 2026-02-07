// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/******************************************************************************\
* Author: Nick Mudge <nick@perfectabstractions.com> (https://twitter.com/mudgen)
* EIP-2535 Diamonds: https://eips.ethereum.org/EIPS/eip-2535
*
* Implementation of a diamond.
/******************************************************************************/

import {LibDiamond} from "./libraries/LibDiamond.sol";
import {IDiamondCut} from "./interfaces/IDiamondCut.sol";

/**
 * @title Diamond
 * @notice Main proxy contract implementing EIP-2535 Diamond pattern
 * @dev All calls are delegated to facets via the fallback function.
 *      The constructor only adds the diamondCut function - all other
 *      functions must be added via diamondCut calls.
 *
 * How it works:
 * 1. User calls a function on Diamond address
 * 2. fallback() looks up which facet handles that function selector
 * 3. delegatecall executes the facet code with Diamond's storage
 * 4. Result is returned to the caller
 */
contract Diamond {
    /**
     * @notice Initialize the Diamond with owner and DiamondCutFacet
     * @param _contractOwner Address of the contract owner
     * @param _diamondCutFacet Address of deployed DiamondCutFacet
     * @dev The diamondCut function is the only function added in constructor.
     *      All other facets must be added via diamondCut calls.
     */
    constructor(address _contractOwner, address _diamondCutFacet) payable {
        LibDiamond.setContractOwner(_contractOwner);

        // Add the diamondCut external function from the diamondCutFacet
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        bytes4[] memory functionSelectors = new bytes4[](1);
        functionSelectors[0] = IDiamondCut.diamondCut.selector;
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: _diamondCutFacet, action: IDiamondCut.FacetCutAction.Add, functionSelectors: functionSelectors
        });
        LibDiamond.diamondCut(cut, address(0), "");
    }

    /**
     * @notice Route all calls to appropriate facets
     * @dev This is the core of the Diamond pattern:
     *      1. Get the facet address for msg.sig (function selector)
     *      2. delegatecall to that facet
     *      3. Return any data or revert with error
     */
    fallback() external payable {
        LibDiamond.DiamondStorage storage ds;
        bytes32 position = LibDiamond.DIAMOND_STORAGE_POSITION;
        // Get diamond storage
        assembly {
            ds.slot := position
        }
        // Get facet from function selector
        address facet = ds.selectorToFacetAndPosition[msg.sig].facetAddress;
        require(facet != address(0), "Diamond: Function does not exist");
        // Execute external function from facet using delegatecall and return any value
        assembly {
            // Copy function selector and any arguments
            calldatacopy(0, 0, calldatasize())
            // Execute function call using the facet
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            // Get any return value
            returndatacopy(0, 0, returndatasize())
            // Return any return value or error back to the caller
            switch result
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return(0, returndatasize())
            }
        }
    }

    /**
     * @notice Accept ETH transfers
     */
    receive() external payable {}
}
