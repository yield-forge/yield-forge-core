// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title MintTokens
 * @notice Dev script to mint ERC20 tokens on Anvil fork
 * @dev This script finds the correct storage slot using stdStorage,
 *      then outputs the slot and value for the shell wrapper to apply via anvil_setStorageAt
 *
 * Usage:
 *   pnpm dev:mint-tokens <TOKEN_ADDRESS> <AMOUNT>
 */
contract MintTokens is Script {
    using stdStorage for StdStorage;

    /**
     * @notice Find the storage slot and output it for the shell wrapper
     * @param token ERC20 token address
     * @param amountStr Amount in human-readable format
     */
    function run(address token, string calldata amountStr) external {
        // ============ Load Configuration ============
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address recipient = vm.addr(privateKey);

        // ============ Get Token Info ============
        IERC20Metadata tokenContract = IERC20Metadata(token);

        string memory symbol;
        uint8 decimals;

        try tokenContract.symbol() returns (string memory _symbol) {
            symbol = _symbol;
        } catch {
            symbol = "UNKNOWN";
        }
        try tokenContract.decimals() returns (uint8 _decimals) {
            decimals = _decimals;
        } catch {
            revert("Failed to get token decimals");
        }
        // ============ Parse Amount ============
        uint256 amount = _parseAmount(amountStr, decimals);

        // ============ Get Current Balance ============
        uint256 balanceBefore = IERC20(token).balanceOf(recipient);

        // ============ Find Storage Slot using stdStorage ============
        // This is the magic - stdStorage can find the correct slot even for proxies
        uint256 slot = stdstore
            .target(token)
            .sig(IERC20.balanceOf.selector)
            .with_key(recipient)
            .find();

        uint256 newBalance = balanceBefore + amount;

        // ============ Output for shell wrapper ============
        // Format: SLOT_INFO:<token>:<slot>:<value>
        console.log(
            "SLOT_INFO:%s:%s:%s",
            vm.toString(token),
            vm.toString(bytes32(slot)),
            vm.toString(bytes32(newBalance))
        );

        // Also output human-readable info
        console.log("");
        console.log("=== Mint Tokens (Dev Script) ===");
        console.log("Token:", token);
        console.log("Symbol:", symbol);
        console.log("Decimals:", decimals);
        console.log("Recipient:", recipient);
        console.log("Amount (human):", amountStr);
        console.log("Amount (wei):", amount);
        console.log("Balance Before:", balanceBefore);
        console.log("New Balance:", newBalance);
        console.log("Storage Slot:", slot);
    }

    function _parseAmount(
        string memory amountStr,
        uint8 decimals
    ) internal pure returns (uint256) {
        bytes memory amountBytes = bytes(amountStr);
        uint256 integerPart = 0;
        uint256 fractionalPart = 0;
        uint256 fractionalDigits = 0;
        bool foundDecimal = false;

        for (uint256 i = 0; i < amountBytes.length; i++) {
            bytes1 char = amountBytes[i];

            if (char == ".") {
                require(
                    !foundDecimal,
                    "Invalid amount: multiple decimal points"
                );
                foundDecimal = true;
                continue;
            }

            require(
                char >= "0" && char <= "9",
                "Invalid amount: non-numeric character"
            );

            uint8 digit = uint8(char) - 48;

            if (foundDecimal) {
                fractionalPart = fractionalPart * 10 + digit;
                fractionalDigits++;
                require(
                    fractionalDigits <= decimals,
                    "Amount has too many decimal places"
                );
            } else {
                integerPart = integerPart * 10 + digit;
            }
        }

        uint256 multiplier = 10 ** decimals;
        uint256 fractionalMultiplier = 10 ** (decimals - fractionalDigits);

        return
            (integerPart * multiplier) +
            (fractionalPart * fractionalMultiplier);
    }
}
