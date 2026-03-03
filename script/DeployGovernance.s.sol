// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {YieldForgeToken} from "../src/governance/YieldForgeToken.sol";
import {MerkleClaim} from "../src/governance/MerkleClaim.sol";

contract DeployGovernance is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Configuration with sensible defaults
        uint256 totalSupply = vm.envOr("TOKEN_TOTAL_SUPPLY", uint256(100_000_000e18));
        address tokenRecipient = vm.envOr("TOKEN_RECIPIENT", deployer);
        address merkleClaimOwner = vm.envOr("MERKLE_CLAIM_OWNER", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy governance token
        YieldForgeToken token = new YieldForgeToken(totalSupply, tokenRecipient);
        console.log("YieldForgeToken deployed at:", address(token));
        console.log("  Total supply:", totalSupply);
        console.log("  Recipient:", tokenRecipient);

        // 2. Deploy MerkleClaim
        MerkleClaim merkleClaim = new MerkleClaim(address(token), merkleClaimOwner);
        console.log("MerkleClaim deployed at:", address(merkleClaim));
        console.log("  Owner:", merkleClaimOwner);

        vm.stopBroadcast();

        // 3. Save deployment artifacts
        string memory chainId = vm.toString(block.chainid);
        string memory json = "governance_data";

        vm.serializeAddress(json, "YieldForgeToken", address(token));
        string memory finalJson = vm.serializeAddress(json, "MerkleClaim", address(merkleClaim));

        string memory path = string.concat(vm.projectRoot(), "/deployments/governance-", chainId, ".json");
        vm.writeJson(finalJson, path);
        console.log("Deployment artifacts saved to:", path);
    }
}
