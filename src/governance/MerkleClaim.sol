// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title MerkleClaim
 * @notice Monthly Merkle-drop distribution for YieldForge governance tokens
 * @dev Each epoch (month) has an immutable Merkle root. Users claim by providing a proof.
 *      Leaf encoding: keccak256(bytes.concat(keccak256(abi.encode(account, amount))))
 *      (double-hash prevents second preimage attacks per OZ recommendation)
 */
contract MerkleClaim is Ownable2Step {
    using SafeERC20 for IERC20;

    // ===== STATE =====

    IERC20 public immutable token;

    /// @notice Merkle root per epoch (immutable once set)
    mapping(uint256 epoch => bytes32 root) public merkleRoots;

    /// @notice Whether an account has claimed for a given epoch
    mapping(uint256 epoch => mapping(address account => bool)) public claimed;

    // ===== EVENTS =====

    event MerkleRootSet(uint256 indexed epoch, bytes32 root);
    event Claimed(uint256 indexed epoch, address indexed account, uint256 amount);

    // ===== ERRORS =====

    error ZeroAddress();
    error RootAlreadySet();
    error RootNotSet();
    error AlreadyClaimed();
    error InvalidProof();
    error ZeroRoot();

    // ===== CONSTRUCTOR =====

    /**
     * @param _token        Address of the YieldForgeToken
     * @param _initialOwner Admin address (multisig or timelock)
     */
    constructor(address _token, address _initialOwner) Ownable(_initialOwner) {
        if (_token == address(0)) revert ZeroAddress();
        token = IERC20(_token);
    }

    // ===== ADMIN =====

    /**
     * @notice Set the Merkle root for an epoch
     * @dev Root is immutable once set — cannot be overwritten
     * @param epoch Epoch number (e.g. month index)
     * @param root  Merkle root of the reward tree
     */
    function setMerkleRoot(uint256 epoch, bytes32 root) external onlyOwner {
        if (root == bytes32(0)) revert ZeroRoot();
        if (merkleRoots[epoch] != bytes32(0)) revert RootAlreadySet();

        merkleRoots[epoch] = root;
        emit MerkleRootSet(epoch, root);
    }

    // ===== USER =====

    /**
     * @notice Claim tokens for a given epoch
     * @param epoch  Epoch to claim from
     * @param amount Amount allocated to caller
     * @param proof  Merkle proof for the caller's leaf
     */
    function claim(uint256 epoch, uint256 amount, bytes32[] calldata proof) external {
        if (merkleRoots[epoch] == bytes32(0)) revert RootNotSet();
        if (claimed[epoch][msg.sender]) revert AlreadyClaimed();

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, amount))));
        if (!MerkleProof.verifyCalldata(proof, merkleRoots[epoch], leaf)) revert InvalidProof();

        claimed[epoch][msg.sender] = true;
        token.safeTransfer(msg.sender, amount);

        emit Claimed(epoch, msg.sender, amount);
    }
}
