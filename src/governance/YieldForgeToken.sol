// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit, Nonces} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";

/**
 * @title YieldForgeToken
 * @notice Governance token for the Yield Forge protocol
 * @dev Fixed-supply ERC-20 with vote delegation (ERC20Votes) and gasless approvals (ERC20Permit).
 *      Entire supply is minted at deployment — no mint/burn functions exposed.
 */
contract YieldForgeToken is ERC20, ERC20Permit, ERC20Votes {
    /**
     * @param _totalSupply Total token supply (with decimals, e.g. 100_000_000e18)
     * @param _recipient   Address that receives the entire initial supply
     */
    constructor(uint256 _totalSupply, address _recipient)
        ERC20("Yield Forge", "YFORGE")
        ERC20Permit("Yield Forge")
    {
        _mint(_recipient, _totalSupply);
    }

    // ===== REQUIRED OVERRIDES (OZ v5 linearization) =====

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
