// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IDiamondCut} from "./interfaces/IDiamondCut.sol";

/**
 * @title DiamondTimelock
 * @notice Timelock contract for Diamond upgrades
 * @dev Adds 48-hour delay between proposing and executing diamond cuts.
 *      This gives users time to review proposed changes and exit if needed.
 *
 * Usage pattern:
 * 1. Deploy DiamondTimelock with Diamond address
 * 2. Transfer Diamond ownership to DiamondTimelock
 * 3. Admin proposes changes via proposeDiamondCut()
 * 4. Wait 48 hours
 * 5. Admin executes via executeDiamondCut()
 */
contract DiamondTimelock is Ownable {
    // ============ Constants ============

    /// @notice Minimum delay before a proposal can be executed
    uint256 public constant DELAY = 48 hours;

    /// @notice Time window after delay during which execution is allowed
    uint256 public constant GRACE_PERIOD = 7 days;

    // ============ Structs ============

    /// @notice Structure for storing diamond cut proposals
    struct DiamondCutProposal {
        IDiamondCut.FacetCut[] facetCuts;
        address init;
        bytes initCalldata;
        uint256 proposedAt;
        uint256 executeAfter;
        bool executed;
        bool cancelled;
        address proposer;
    }

    /// @notice Structure for storing generic transaction proposals
    struct TransactionProposal {
        address target;
        bytes data;
        uint256 proposedAt;
        uint256 executeAfter;
        bool executed;
        bool cancelled;
        address proposer;
    }

    // ============ State ============

    /// @notice The Diamond contract this timelock controls
    address public immutable diamond;

    /// @notice Mapping of proposal ID to DiamondCut proposal
    mapping(bytes32 => DiamondCutProposal) public proposals;

    /// @notice Mapping of proposal ID to transaction proposal
    mapping(bytes32 => TransactionProposal) public txProposals;

    // ============ Events ============

    event DiamondCutProposed(
        bytes32 indexed proposalId,
        uint256 executeAfter,
        address proposer
    );

    event DiamondCutExecuted(bytes32 indexed proposalId);

    event DiamondCutCancelled(bytes32 indexed proposalId);

    event TransactionProposed(
        bytes32 indexed proposalId,
        address indexed target,
        uint256 executeAfter,
        address proposer
    );

    event TransactionExecuted(bytes32 indexed proposalId);

    event TransactionCancelled(bytes32 indexed proposalId);

    // ============ Errors ============

    error ZeroAddress();
    error ProposalNotFound();
    error ProposalAlreadyExecuted();
    error ProposalCancelled();
    error TooEarly();
    error ProposalExpired();
    error EmptyFacetCuts();
    error TransactionFailed();

    // ============ Constructor ============

    /**
     * @notice Initialize the timelock
     * @param _diamond Address of the Diamond contract to control
     * @param _owner Address of the timelock owner (admin)
     */
    constructor(address _diamond, address _owner) Ownable(_owner) {
        if (_diamond == address(0)) revert ZeroAddress();
        diamond = _diamond;
    }

    // ============ Diamond Cut Functions ============

    /**
     * @notice Propose a diamond cut
     * @param _facetCuts Array of facet cuts (add/replace/remove)
     * @param _init Address of initialization contract
     * @param _calldata Initialization calldata
     * @return proposalId Unique identifier for this proposal
     */
    function proposeDiamondCut(
        IDiamondCut.FacetCut[] calldata _facetCuts,
        address _init,
        bytes calldata _calldata
    ) external onlyOwner returns (bytes32 proposalId) {
        if (_facetCuts.length == 0) revert EmptyFacetCuts();

        proposalId = keccak256(
            abi.encode(
                _facetCuts,
                _init,
                _calldata,
                block.timestamp,
                msg.sender
            )
        );

        uint256 executeAfter = block.timestamp + DELAY;

        // Store proposal
        DiamondCutProposal storage proposal = proposals[proposalId];
        proposal.proposedAt = block.timestamp;
        proposal.executeAfter = executeAfter;
        proposal.executed = false;
        proposal.cancelled = false;
        proposal.proposer = msg.sender;
        proposal.init = _init;
        proposal.initCalldata = _calldata;

        // Copy facet cuts
        for (uint256 i = 0; i < _facetCuts.length; i++) {
            proposal.facetCuts.push(_facetCuts[i]);
        }

        emit DiamondCutProposed(proposalId, executeAfter, msg.sender);
    }

    /**
     * @notice Execute a proposed diamond cut after delay
     * @param proposalId ID of the proposal to execute
     */
    function executeDiamondCut(bytes32 proposalId) external onlyOwner {
        DiamondCutProposal storage proposal = proposals[proposalId];

        if (proposal.proposedAt == 0) revert ProposalNotFound();
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (proposal.cancelled) revert ProposalCancelled();
        if (block.timestamp < proposal.executeAfter) revert TooEarly();
        if (block.timestamp > proposal.executeAfter + GRACE_PERIOD) {
            revert ProposalExpired();
        }

        proposal.executed = true;

        // Execute diamond cut
        IDiamondCut(diamond).diamondCut(
            proposal.facetCuts,
            proposal.init,
            proposal.initCalldata
        );

        emit DiamondCutExecuted(proposalId);
    }

    /**
     * @notice Cancel a pending diamond cut proposal
     * @param proposalId ID of the proposal to cancel
     */
    function cancelDiamondCut(bytes32 proposalId) external onlyOwner {
        DiamondCutProposal storage proposal = proposals[proposalId];

        if (proposal.proposedAt == 0) revert ProposalNotFound();
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (proposal.cancelled) revert ProposalCancelled();

        proposal.cancelled = true;

        emit DiamondCutCancelled(proposalId);
    }

    // ============ Transaction Functions ============

    /**
     * @notice Propose a generic transaction
     * @param _target Target address
     * @param _data Transaction data
     * @return proposalId Unique identifier for this proposal
     */
    function proposeTransaction(
        address _target,
        bytes calldata _data
    ) external onlyOwner returns (bytes32 proposalId) {
        if (_target == address(0)) revert ZeroAddress();

        proposalId = keccak256(
            abi.encode(_target, _data, block.timestamp, msg.sender)
        );

        uint256 executeAfter = block.timestamp + DELAY;

        // Store proposal
        TransactionProposal storage proposal = txProposals[proposalId];
        proposal.target = _target;
        proposal.data = _data;
        proposal.proposedAt = block.timestamp;
        proposal.executeAfter = executeAfter;
        proposal.executed = false;
        proposal.cancelled = false;
        proposal.proposer = msg.sender;

        emit TransactionProposed(proposalId, _target, executeAfter, msg.sender);
    }

    /**
     * @notice Execute a proposed transaction after delay
     * @param proposalId ID of the proposal to execute
     */
    function executeTransaction(bytes32 proposalId) external onlyOwner {
        TransactionProposal storage proposal = txProposals[proposalId];

        if (proposal.proposedAt == 0) revert ProposalNotFound();
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (proposal.cancelled) revert ProposalCancelled();
        if (block.timestamp < proposal.executeAfter) revert TooEarly();
        if (block.timestamp > proposal.executeAfter + GRACE_PERIOD) {
            revert ProposalExpired();
        }

        proposal.executed = true;

        // Execute transaction
        (bool success, ) = proposal.target.call(proposal.data);
        if (!success) revert TransactionFailed();

        emit TransactionExecuted(proposalId);
    }

    /**
     * @notice Cancel a pending transaction proposal
     * @param proposalId ID of the proposal to cancel
     */
    function cancelTransaction(bytes32 proposalId) external onlyOwner {
        TransactionProposal storage proposal = txProposals[proposalId];

        if (proposal.proposedAt == 0) revert ProposalNotFound();
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (proposal.cancelled) revert ProposalCancelled();

        proposal.cancelled = true;

        emit TransactionCancelled(proposalId);
    }

    // ============ View Functions ============

    /**
     * @notice Get proposal details
     * @param proposalId ID of the proposal
     */
    function getProposal(
        bytes32 proposalId
    )
        external
        view
        returns (
            address init,
            bytes memory initCalldata,
            uint256 proposedAt,
            uint256 executeAfter,
            bool executed,
            bool cancelled,
            address proposer
        )
    {
        DiamondCutProposal storage proposal = proposals[proposalId];
        return (
            proposal.init,
            proposal.initCalldata,
            proposal.proposedAt,
            proposal.executeAfter,
            proposal.executed,
            proposal.cancelled,
            proposal.proposer
        );
    }

    /**
     * @notice Get transaction proposal details
     * @param proposalId ID of the proposal
     */
    function getTransactionProposal(
        bytes32 proposalId
    )
        external
        view
        returns (
            address target,
            bytes memory data,
            uint256 proposedAt,
            uint256 executeAfter,
            bool executed,
            bool cancelled,
            address proposer
        )
    {
        TransactionProposal storage proposal = txProposals[proposalId];
        return (
            proposal.target,
            proposal.data,
            proposal.proposedAt,
            proposal.executeAfter,
            proposal.executed,
            proposal.cancelled,
            proposal.proposer
        );
    }

    /**
     * @notice Get facet cuts for a proposal
     * @param proposalId ID of the proposal
     * @return Array of facet cuts
     */
    function getProposalFacetCuts(
        bytes32 proposalId
    ) external view returns (IDiamondCut.FacetCut[] memory) {
        return proposals[proposalId].facetCuts;
    }

    /**
     * @notice Check if proposal can be executed
     * @param proposalId ID of the proposal
     * @return True if proposal is ready to execute
     */
    function canExecute(bytes32 proposalId) external view returns (bool) {
        DiamondCutProposal storage proposal = proposals[proposalId];

        return
            proposal.proposedAt != 0 &&
            !proposal.executed &&
            !proposal.cancelled &&
            block.timestamp >= proposal.executeAfter &&
            block.timestamp <= proposal.executeAfter + GRACE_PERIOD;
    }

    /**
     * @notice Check if transaction proposal can be executed
     * @param proposalId ID of the proposal
     * @return True if proposal is ready to execute
     */
    function canExecuteTransaction(
        bytes32 proposalId
    ) external view returns (bool) {
        TransactionProposal storage proposal = txProposals[proposalId];

        return
            proposal.proposedAt != 0 &&
            !proposal.executed &&
            !proposal.cancelled &&
            block.timestamp >= proposal.executeAfter &&
            block.timestamp <= proposal.executeAfter + GRACE_PERIOD;
    }

    /**
     * @notice Get time until proposal can be executed
     * @param proposalId ID of the proposal
     * @return Seconds until execution (0 if ready)
     */
    function timeUntilExecution(
        bytes32 proposalId
    ) external view returns (uint256) {
        DiamondCutProposal storage proposal = proposals[proposalId];

        if (proposal.proposedAt == 0) revert ProposalNotFound();
        if (block.timestamp >= proposal.executeAfter) return 0;

        return proposal.executeAfter - block.timestamp;
    }

    /**
     * @notice Get time until transaction proposal can be executed
     * @param proposalId ID of the proposal
     * @return Seconds until execution (0 if ready)
     */
    function timeUntilTransactionExecution(
        bytes32 proposalId
    ) external view returns (uint256) {
        TransactionProposal storage proposal = txProposals[proposalId];

        if (proposal.proposedAt == 0) revert ProposalNotFound();
        if (block.timestamp >= proposal.executeAfter) return 0;

        return proposal.executeAfter - block.timestamp;
    }
}
