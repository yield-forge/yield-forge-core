// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {YieldForgeToken} from "../src/governance/YieldForgeToken.sol";
import {MerkleClaim} from "../src/governance/MerkleClaim.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MerkleClaimTest
 * @notice Tests for the Merkle-based reward distribution contract
 * @dev Builds a 4-leaf Merkle tree in setUp for use across all tests
 */
contract MerkleClaimTest is Test {
    YieldForgeToken token;
    MerkleClaim merkleClaim;

    address owner = address(this);
    address alice = address(0x1);
    address bob = address(0x2);
    address carol = address(0x3);
    address dave = address(0x4);
    address attacker = address(0xBAD);

    uint256 constant TOTAL_SUPPLY = 100_000_000e18;
    uint256 constant EPOCH = 1;

    // Amounts for each participant
    uint256 aliceAmount = 1000e18;
    uint256 bobAmount = 2000e18;
    uint256 carolAmount = 500e18;
    uint256 daveAmount = 1500e18;

    // Merkle tree components (computed in setUp)
    bytes32 leafAlice;
    bytes32 leafBob;
    bytes32 leafCarol;
    bytes32 leafDave;
    bytes32 nodeAB; // hash(leafAlice, leafBob)
    bytes32 nodeCD; // hash(leafCarol, leafDave)
    bytes32 merkleRoot;

    function setUp() public {
        // Deploy token and claim contract
        token = new YieldForgeToken(TOTAL_SUPPLY, owner);
        merkleClaim = new MerkleClaim(address(token), owner);

        // Fund the claim contract
        token.transfer(address(merkleClaim), 10_000e18);

        // Build Merkle tree (4 leaves, depth 2)
        // Leaf encoding: keccak256(bytes.concat(keccak256(abi.encode(account, amount))))
        leafAlice = keccak256(bytes.concat(keccak256(abi.encode(alice, aliceAmount))));
        leafBob = keccak256(bytes.concat(keccak256(abi.encode(bob, bobAmount))));
        leafCarol = keccak256(bytes.concat(keccak256(abi.encode(carol, carolAmount))));
        leafDave = keccak256(bytes.concat(keccak256(abi.encode(dave, daveAmount))));

        // Internal nodes (sorted pair hashing — OZ MerkleProof convention)
        nodeAB = _hashPair(leafAlice, leafBob);
        nodeCD = _hashPair(leafCarol, leafDave);
        merkleRoot = _hashPair(nodeAB, nodeCD);

        // Set Merkle root for epoch 1
        merkleClaim.setMerkleRoot(EPOCH, merkleRoot);
    }

    /// @dev Sorted pair hashing matching OZ MerkleProof.commutativeKeccak256
    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    // ================================================================
    //                     SUCCESSFUL CLAIMS
    // ================================================================

    function test_ClaimAlice() public {
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = leafBob; // sibling
        proof[1] = nodeCD; // uncle

        vm.prank(alice);
        merkleClaim.claim(EPOCH, aliceAmount, proof);

        assertEq(token.balanceOf(alice), aliceAmount);
        assertTrue(merkleClaim.claimed(EPOCH, alice));
    }

    function test_ClaimBob() public {
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = leafAlice;
        proof[1] = nodeCD;

        vm.prank(bob);
        merkleClaim.claim(EPOCH, bobAmount, proof);

        assertEq(token.balanceOf(bob), bobAmount);
        assertTrue(merkleClaim.claimed(EPOCH, bob));
    }

    function test_ClaimCarol() public {
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = leafDave;
        proof[1] = nodeAB;

        vm.prank(carol);
        merkleClaim.claim(EPOCH, carolAmount, proof);

        assertEq(token.balanceOf(carol), carolAmount);
    }

    function test_ClaimDave() public {
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = leafCarol;
        proof[1] = nodeAB;

        vm.prank(dave);
        merkleClaim.claim(EPOCH, daveAmount, proof);

        assertEq(token.balanceOf(dave), daveAmount);
    }

    function test_ClaimEmitsEvent() public {
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = leafBob;
        proof[1] = nodeCD;

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit MerkleClaim.Claimed(EPOCH, alice, aliceAmount);
        merkleClaim.claim(EPOCH, aliceAmount, proof);
    }

    // ================================================================
    //                     CLAIM REJECTIONS
    // ================================================================

    function test_RevertDoubleClaim() public {
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = leafBob;
        proof[1] = nodeCD;

        vm.prank(alice);
        merkleClaim.claim(EPOCH, aliceAmount, proof);

        vm.prank(alice);
        vm.expectRevert(MerkleClaim.AlreadyClaimed.selector);
        merkleClaim.claim(EPOCH, aliceAmount, proof);
    }

    function test_RevertInvalidProof() public {
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = bytes32(uint256(0xDEAD)); // wrong sibling
        proof[1] = nodeCD;

        vm.prank(alice);
        vm.expectRevert(MerkleClaim.InvalidProof.selector);
        merkleClaim.claim(EPOCH, aliceAmount, proof);
    }

    function test_RevertWrongAmount() public {
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = leafBob;
        proof[1] = nodeCD;

        vm.prank(alice);
        vm.expectRevert(MerkleClaim.InvalidProof.selector);
        merkleClaim.claim(EPOCH, 9999e18, proof); // wrong amount
    }

    function test_RevertWrongClaimer() public {
        // Attacker tries to claim alice's allocation
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = leafBob;
        proof[1] = nodeCD;

        vm.prank(attacker);
        vm.expectRevert(MerkleClaim.InvalidProof.selector);
        merkleClaim.claim(EPOCH, aliceAmount, proof);
    }

    function test_RevertRootNotSet() public {
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = leafBob;
        proof[1] = nodeCD;

        vm.prank(alice);
        vm.expectRevert(MerkleClaim.RootNotSet.selector);
        merkleClaim.claim(999, aliceAmount, proof); // non-existent epoch
    }

    // ================================================================
    //                     ADMIN: setMerkleRoot
    // ================================================================

    function test_SetMerkleRootEmitsEvent() public {
        bytes32 newRoot = keccak256("epoch2");

        vm.expectEmit(true, false, false, true);
        emit MerkleClaim.MerkleRootSet(2, newRoot);
        merkleClaim.setMerkleRoot(2, newRoot);
    }

    function test_RevertSetRootAlreadySet() public {
        vm.expectRevert(MerkleClaim.RootAlreadySet.selector);
        merkleClaim.setMerkleRoot(EPOCH, keccak256("different"));
    }

    function test_RevertSetZeroRoot() public {
        vm.expectRevert(MerkleClaim.ZeroRoot.selector);
        merkleClaim.setMerkleRoot(2, bytes32(0));
    }

    function test_RevertSetRootNotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        merkleClaim.setMerkleRoot(2, keccak256("evil"));
    }

    // ================================================================
    //                     MULTI-EPOCH
    // ================================================================

    function test_MultipleEpochsIndependent() public {
        // Set epoch 2 with same tree
        merkleClaim.setMerkleRoot(2, merkleRoot);

        bytes32[] memory proof = new bytes32[](2);
        proof[0] = leafBob;
        proof[1] = nodeCD;

        // Claim epoch 1
        vm.prank(alice);
        merkleClaim.claim(EPOCH, aliceAmount, proof);

        // Claim epoch 2 (same proof, same amount — independent)
        vm.prank(alice);
        merkleClaim.claim(2, aliceAmount, proof);

        assertEq(token.balanceOf(alice), aliceAmount * 2);
    }

    // ================================================================
    //                     CONSTRUCTOR VALIDATION
    // ================================================================

    function test_RevertZeroTokenAddress() public {
        vm.expectRevert(MerkleClaim.ZeroAddress.selector);
        new MerkleClaim(address(0), owner);
    }

    function test_OwnerSetCorrectly() public view {
        assertEq(merkleClaim.owner(), owner);
    }

    function test_TokenSetCorrectly() public view {
        assertEq(address(merkleClaim.token()), address(token));
    }
}
