// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {IERC173} from "../interfaces/IERC173.sol";

/**
 * @title OwnershipFacet
 * @notice Provides ownership management functions (ERC-173)
 * @dev Allows reading and transferring contract ownership
 */
contract OwnershipFacet is IERC173 {
    /**
     * @notice Transfer ownership to a new address
     * @param _newOwner Address of new owner (address(0) to renounce)
     */
    function transferOwnership(address _newOwner) external override {
        LibDiamond.enforceIsContractOwner();
        LibDiamond.setContractOwner(_newOwner);
    }

    /**
     * @notice Get the current owner address
     * @return owner_ Current owner
     */
    function owner() external view override returns (address owner_) {
        owner_ = LibDiamond.contractOwner();
    }
}
