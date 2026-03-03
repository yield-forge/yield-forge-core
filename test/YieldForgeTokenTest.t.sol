// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {YieldForgeToken} from "../src/governance/YieldForgeToken.sol";

contract YieldForgeTokenTest is Test {
    YieldForgeToken token;

    address recipient = address(0x1);
    address alice = address(0x2);
    address bob = address(0x3);

    uint256 constant TOTAL_SUPPLY = 100_000_000e18;

    function setUp() public {
        token = new YieldForgeToken(TOTAL_SUPPLY, recipient);
    }

    // ================================================================
    //                        BASIC ERC-20
    // ================================================================

    function test_Name() public view {
        assertEq(token.name(), "Yield Forge");
    }

    function test_Symbol() public view {
        assertEq(token.symbol(), "YFORGE");
    }

    function test_Decimals() public view {
        assertEq(token.decimals(), 18);
    }

    function test_TotalSupply() public view {
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
    }

    function test_RecipientBalance() public view {
        assertEq(token.balanceOf(recipient), TOTAL_SUPPLY);
    }

    function test_Transfer() public {
        vm.prank(recipient);
        token.transfer(alice, 1000e18);

        assertEq(token.balanceOf(alice), 1000e18);
        assertEq(token.balanceOf(recipient), TOTAL_SUPPLY - 1000e18);
    }

    // ================================================================
    //                        ERC20Votes
    // ================================================================

    function test_DelegateToSelf() public {
        vm.prank(recipient);
        token.delegate(recipient);

        assertEq(token.getVotes(recipient), TOTAL_SUPPLY);
    }

    function test_DelegateToOther() public {
        vm.prank(recipient);
        token.delegate(alice);

        assertEq(token.getVotes(alice), TOTAL_SUPPLY);
        assertEq(token.getVotes(recipient), 0);
    }

    function test_VotesUpdateOnTransfer() public {
        // Recipient delegates to self
        vm.prank(recipient);
        token.delegate(recipient);

        // Transfer to alice (who delegates to self)
        vm.prank(alice);
        token.delegate(alice);

        vm.prank(recipient);
        token.transfer(alice, 1000e18);

        assertEq(token.getVotes(recipient), TOTAL_SUPPLY - 1000e18);
        assertEq(token.getVotes(alice), 1000e18);
    }

    function test_GetPastVotes() public {
        // Start at a known block
        vm.roll(100);

        vm.prank(recipient);
        token.delegate(recipient);

        // Advance and transfer
        vm.roll(101);
        vm.prank(recipient);
        token.transfer(alice, 500e18);

        // Advance again so we can query past blocks
        vm.roll(102);

        // Block 100: delegation happened, full supply
        assertEq(token.getPastVotes(recipient, 100), TOTAL_SUPPLY);
        // Block 101: post-transfer
        assertEq(token.getPastVotes(recipient, 101), TOTAL_SUPPLY - 500e18);
    }

    function test_NumCheckpoints() public {
        vm.prank(recipient);
        token.delegate(recipient);

        assertEq(token.numCheckpoints(recipient), 1);

        // Another action in a new block creates another checkpoint
        vm.roll(block.number + 1);
        vm.prank(recipient);
        token.transfer(alice, 100e18);

        assertEq(token.numCheckpoints(recipient), 2);
    }

    function test_ZeroVotesWithoutDelegation() public view {
        // No delegation → zero voting power
        assertEq(token.getVotes(recipient), 0);
    }

    // ================================================================
    //                        ERC20Permit
    // ================================================================

    function test_Permit() public {
        uint256 ownerPrivateKey = 0xA11CE;
        address owner = vm.addr(ownerPrivateKey);

        // Give tokens to owner
        vm.prank(recipient);
        token.transfer(owner, 1000e18);

        uint256 nonce = token.nonces(owner);
        uint256 deadline = block.timestamp + 1 hours;
        uint256 value = 500e18;

        bytes32 domainSeparator = token.DOMAIN_SEPARATOR();
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                bob,
                value,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        token.permit(owner, bob, value, deadline, v, r, s);

        assertEq(token.allowance(owner, bob), value);
        assertEq(token.nonces(owner), nonce + 1);
    }

    function test_PermitRevertsAfterDeadline() public {
        uint256 ownerPrivateKey = 0xA11CE;
        address owner = vm.addr(ownerPrivateKey);

        uint256 deadline = block.timestamp - 1; // expired

        bytes32 domainSeparator = token.DOMAIN_SEPARATOR();
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                bob,
                100e18,
                0,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        vm.expectRevert();
        token.permit(owner, bob, 100e18, deadline, v, r, s);
    }
}
