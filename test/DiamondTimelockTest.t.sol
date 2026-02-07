// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Diamond} from "../src/Diamond.sol";
import {DiamondTimelock} from "../src/DiamondTimelock.sol";
import {DiamondCutFacet} from "../src/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../src/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {IERC173} from "../src/interfaces/IERC173.sol";
import {IERC165} from "../src/interfaces/IERC165.sol";

/**
 * @title DiamondTimelockTest
 * @notice Tests for DiamondTimelock security contract
 */
contract DiamondTimelockTest is Test {
    Diamond diamond;
    DiamondTimelock timelock;
    DiamondCutFacet diamondCutFacet;
    DiamondLoupeFacet diamondLoupeFacet;
    OwnershipFacet ownershipFacet;

    address admin = address(this);
    address attacker = address(0xBAD);

    uint256 constant DELAY = 48 hours;
    uint256 constant GRACE_PERIOD = 7 days;

    // Events
    event DiamondCutProposed(bytes32 indexed proposalId, uint256 executeAfter, address proposer);
    event DiamondCutExecuted(bytes32 indexed proposalId);
    event DiamondCutCancelled(bytes32 indexed proposalId);

    function setUp() public {
        // 1. Deploy DiamondCutFacet
        diamondCutFacet = new DiamondCutFacet();

        // 2. Deploy Diamond with admin as owner (temporary)
        diamond = new Diamond(admin, address(diamondCutFacet));

        // 3. Deploy other facets and add them
        diamondLoupeFacet = new DiamondLoupeFacet();
        ownershipFacet = new OwnershipFacet();

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](2);

        bytes4[] memory loupeSelectors = new bytes4[](5);
        loupeSelectors[0] = IDiamondLoupe.facets.selector;
        loupeSelectors[1] = IDiamondLoupe.facetFunctionSelectors.selector;
        loupeSelectors[2] = IDiamondLoupe.facetAddresses.selector;
        loupeSelectors[3] = IDiamondLoupe.facetAddress.selector;
        loupeSelectors[4] = IERC165.supportsInterface.selector;

        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(diamondLoupeFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: loupeSelectors
        });

        bytes4[] memory ownershipSelectors = new bytes4[](2);
        ownershipSelectors[0] = IERC173.owner.selector;
        ownershipSelectors[1] = IERC173.transferOwnership.selector;

        cut[1] = IDiamondCut.FacetCut({
            facetAddress: address(ownershipFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: ownershipSelectors
        });

        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");

        // 4. Deploy Timelock with Diamond address
        timelock = new DiamondTimelock(address(diamond), admin);

        // 5. Transfer Diamond ownership to Timelock
        OwnershipFacet(address(diamond)).transferOwnership(address(timelock));
    }

    // ============ Setup Verification ============

    function test_SetupDiamondOwnedByTimelock() public view {
        address diamondOwner = OwnershipFacet(address(diamond)).owner();
        assertEq(diamondOwner, address(timelock), "Diamond should be owned by timelock");
    }

    function test_SetupTimelockOwnedByAdmin() public view {
        address timelockOwner = timelock.owner();
        assertEq(timelockOwner, admin, "Timelock should be owned by admin");
    }

    // ============ Propose Tests ============

    function test_ProposeCreatesProposal() public {
        MockFacet mockFacet = new MockFacet();

        IDiamondCut.FacetCut[] memory cuts = _createMockCut(address(mockFacet));

        bytes32 proposalId = timelock.proposeDiamondCut(cuts, address(0), "");

        (,, uint256 proposedAt, uint256 executeAfter, bool executed, bool cancelled, address proposer) =
            timelock.getProposal(proposalId);

        assertEq(proposedAt, block.timestamp, "Proposed at should be now");
        assertEq(executeAfter, block.timestamp + DELAY, "Execute after should be now + DELAY");
        assertFalse(executed, "Should not be executed");
        assertFalse(cancelled, "Should not be cancelled");
        assertEq(proposer, admin, "Proposer should be admin");
    }

    function test_ProposeEmitsEvent() public {
        MockFacet mockFacet = new MockFacet();
        IDiamondCut.FacetCut[] memory cuts = _createMockCut(address(mockFacet));

        vm.expectEmit(false, false, false, true);
        emit DiamondCutProposed(bytes32(0), block.timestamp + DELAY, admin);

        timelock.proposeDiamondCut(cuts, address(0), "");
    }

    function test_RevertProposeEmptyCuts() public {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](0);

        vm.expectRevert(DiamondTimelock.EmptyFacetCuts.selector);
        timelock.proposeDiamondCut(cuts, address(0), "");
    }

    function test_RevertProposeNonOwner() public {
        MockFacet mockFacet = new MockFacet();
        IDiamondCut.FacetCut[] memory cuts = _createMockCut(address(mockFacet));

        vm.prank(attacker);
        vm.expectRevert();
        timelock.proposeDiamondCut(cuts, address(0), "");
    }

    // ============ Execute Tests ============

    function test_ExecuteAfterDelay() public {
        MockFacet mockFacet = new MockFacet();
        IDiamondCut.FacetCut[] memory cuts = _createMockCut(address(mockFacet));

        bytes32 proposalId = timelock.proposeDiamondCut(cuts, address(0), "");

        // Warp past delay
        vm.warp(block.timestamp + DELAY + 1);

        // Execute
        timelock.executeDiamondCut(proposalId);

        // Verify facet was added to Diamond
        address facetAddr = IDiamondLoupe(address(diamond)).facetAddress(MockFacet.getValue.selector);
        assertEq(facetAddr, address(mockFacet), "MockFacet should be added to Diamond");

        // Verify proposal marked as executed
        (,,,, bool executed,,) = timelock.getProposal(proposalId);
        assertTrue(executed, "Proposal should be marked executed");
    }

    function test_ExecuteEmitsEvent() public {
        MockFacet mockFacet = new MockFacet();
        IDiamondCut.FacetCut[] memory cuts = _createMockCut(address(mockFacet));

        bytes32 proposalId = timelock.proposeDiamondCut(cuts, address(0), "");

        vm.warp(block.timestamp + DELAY + 1);

        vm.expectEmit(true, false, false, false);
        emit DiamondCutExecuted(proposalId);

        timelock.executeDiamondCut(proposalId);
    }

    function test_RevertExecuteBeforeDelay() public {
        MockFacet mockFacet = new MockFacet();
        IDiamondCut.FacetCut[] memory cuts = _createMockCut(address(mockFacet));

        bytes32 proposalId = timelock.proposeDiamondCut(cuts, address(0), "");

        // Try to execute immediately (should fail)
        vm.expectRevert(DiamondTimelock.TooEarly.selector);
        timelock.executeDiamondCut(proposalId);

        // Try at delay - 1 second
        vm.warp(block.timestamp + DELAY - 1);
        vm.expectRevert(DiamondTimelock.TooEarly.selector);
        timelock.executeDiamondCut(proposalId);
    }

    function test_RevertExecuteAfterGracePeriod() public {
        MockFacet mockFacet = new MockFacet();
        IDiamondCut.FacetCut[] memory cuts = _createMockCut(address(mockFacet));

        bytes32 proposalId = timelock.proposeDiamondCut(cuts, address(0), "");

        // Warp past delay + grace period
        vm.warp(block.timestamp + DELAY + GRACE_PERIOD + 1);

        vm.expectRevert(DiamondTimelock.ProposalExpired.selector);
        timelock.executeDiamondCut(proposalId);
    }

    function test_RevertExecuteNonExistent() public {
        bytes32 fakeId = keccak256("fake");

        vm.expectRevert(DiamondTimelock.ProposalNotFound.selector);
        timelock.executeDiamondCut(fakeId);
    }

    function test_RevertExecuteTwice() public {
        MockFacet mockFacet = new MockFacet();
        IDiamondCut.FacetCut[] memory cuts = _createMockCut(address(mockFacet));

        bytes32 proposalId = timelock.proposeDiamondCut(cuts, address(0), "");

        vm.warp(block.timestamp + DELAY + 1);
        timelock.executeDiamondCut(proposalId);

        // Try to execute again
        vm.expectRevert(DiamondTimelock.ProposalAlreadyExecuted.selector);
        timelock.executeDiamondCut(proposalId);
    }

    function test_RevertExecuteNonOwner() public {
        MockFacet mockFacet = new MockFacet();
        IDiamondCut.FacetCut[] memory cuts = _createMockCut(address(mockFacet));

        bytes32 proposalId = timelock.proposeDiamondCut(cuts, address(0), "");

        vm.warp(block.timestamp + DELAY + 1);

        vm.prank(attacker);
        vm.expectRevert();
        timelock.executeDiamondCut(proposalId);
    }

    // ============ Cancel Tests ============

    function test_CancelProposal() public {
        MockFacet mockFacet = new MockFacet();
        IDiamondCut.FacetCut[] memory cuts = _createMockCut(address(mockFacet));

        bytes32 proposalId = timelock.proposeDiamondCut(cuts, address(0), "");

        timelock.cancelDiamondCut(proposalId);

        (,,,,, bool cancelled,) = timelock.getProposal(proposalId);
        assertTrue(cancelled, "Proposal should be cancelled");
    }

    function test_CancelEmitsEvent() public {
        MockFacet mockFacet = new MockFacet();
        IDiamondCut.FacetCut[] memory cuts = _createMockCut(address(mockFacet));

        bytes32 proposalId = timelock.proposeDiamondCut(cuts, address(0), "");

        vm.expectEmit(true, false, false, false);
        emit DiamondCutCancelled(proposalId);

        timelock.cancelDiamondCut(proposalId);
    }

    function test_RevertExecuteCancelled() public {
        MockFacet mockFacet = new MockFacet();
        IDiamondCut.FacetCut[] memory cuts = _createMockCut(address(mockFacet));

        bytes32 proposalId = timelock.proposeDiamondCut(cuts, address(0), "");

        timelock.cancelDiamondCut(proposalId);

        vm.warp(block.timestamp + DELAY + 1);

        vm.expectRevert(DiamondTimelock.ProposalCancelled.selector);
        timelock.executeDiamondCut(proposalId);
    }

    // ============ View Function Tests ============

    function test_CanExecuteReturnsFalseBeforeDelay() public {
        MockFacet mockFacet = new MockFacet();
        IDiamondCut.FacetCut[] memory cuts = _createMockCut(address(mockFacet));

        bytes32 proposalId = timelock.proposeDiamondCut(cuts, address(0), "");

        assertFalse(timelock.canExecute(proposalId), "Should not be executable before delay");
    }

    function test_CanExecuteReturnsTrueAfterDelay() public {
        MockFacet mockFacet = new MockFacet();
        IDiamondCut.FacetCut[] memory cuts = _createMockCut(address(mockFacet));

        bytes32 proposalId = timelock.proposeDiamondCut(cuts, address(0), "");

        vm.warp(block.timestamp + DELAY);

        assertTrue(timelock.canExecute(proposalId), "Should be executable after delay");
    }

    function test_TimeUntilExecution() public {
        MockFacet mockFacet = new MockFacet();
        IDiamondCut.FacetCut[] memory cuts = _createMockCut(address(mockFacet));

        bytes32 proposalId = timelock.proposeDiamondCut(cuts, address(0), "");

        uint256 timeLeft = timelock.timeUntilExecution(proposalId);
        assertEq(timeLeft, DELAY, "Should return full DELAY");

        // After half the delay
        vm.warp(block.timestamp + DELAY / 2);
        timeLeft = timelock.timeUntilExecution(proposalId);
        assertEq(timeLeft, DELAY / 2, "Should return half DELAY");

        // After full delay
        vm.warp(block.timestamp + DELAY / 2 + 1);
        timeLeft = timelock.timeUntilExecution(proposalId);
        assertEq(timeLeft, 0, "Should return 0 when ready");
    }

    // ============ Transaction Proposal Tests ============

    function test_TransactionProposalFlow() public {
        // Deploy a simple contract to call
        Counter counter = new Counter();

        bytes memory data = abi.encodeWithSelector(Counter.increment.selector);

        bytes32 proposalId = timelock.proposeTransaction(address(counter), data);

        vm.warp(block.timestamp + DELAY + 1);

        timelock.executeTransaction(proposalId);

        assertEq(counter.count(), 1, "Counter should be incremented");
    }

    // ============ Helpers ============

    function _createMockCut(address facetAddress) internal pure returns (IDiamondCut.FacetCut[] memory) {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = MockFacet.getValue.selector;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: facetAddress, action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });

        return cuts;
    }
}

// ============ Mock Contracts ============

contract MockFacet {
    function getValue() external pure returns (uint256) {
        return 42;
    }
}

contract Counter {
    uint256 public count;

    function increment() external {
        count++;
    }
}
