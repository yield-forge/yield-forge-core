// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Diamond} from "../src/Diamond.sol";
import {DiamondCutFacet} from "../src/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../src/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {PauseFacet} from "../src/facets/PauseFacet.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {IERC173} from "../src/interfaces/IERC173.sol";
import {IERC165} from "../src/interfaces/IERC165.sol";
import {LibPause} from "../src/libraries/LibPause.sol";

/**
 * @title PauseFacetTest
 * @notice Tests for emergency pause functionality
 */
contract PauseFacetTest is Test {
    Diamond diamond;
    DiamondCutFacet diamondCutFacet;
    DiamondLoupeFacet diamondLoupeFacet;
    OwnershipFacet ownershipFacet;
    PauseFacet pauseFacet;

    address owner = address(this);
    address guardian = address(0x6ABE);
    address attacker = address(0xBAD);

    event Paused(address account);
    event Unpaused(address account);
    event PauseGuardianSet(address indexed previousGuardian, address indexed newGuardian);

    function setUp() public {
        // Deploy facets
        diamondCutFacet = new DiamondCutFacet();
        diamond = new Diamond(owner, address(diamondCutFacet));

        diamondLoupeFacet = new DiamondLoupeFacet();
        ownershipFacet = new OwnershipFacet();
        pauseFacet = new PauseFacet();

        // Add all facets
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](3);

        // Loupe
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

        // Ownership
        bytes4[] memory ownershipSelectors = new bytes4[](2);
        ownershipSelectors[0] = IERC173.owner.selector;
        ownershipSelectors[1] = IERC173.transferOwnership.selector;

        cut[1] = IDiamondCut.FacetCut({
            facetAddress: address(ownershipFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: ownershipSelectors
        });

        // Pause
        bytes4[] memory pauseSelectors = new bytes4[](5);
        pauseSelectors[0] = PauseFacet.pause.selector;
        pauseSelectors[1] = PauseFacet.unpause.selector;
        pauseSelectors[2] = PauseFacet.setPauseGuardian.selector;
        pauseSelectors[3] = PauseFacet.paused.selector;
        pauseSelectors[4] = PauseFacet.pauseGuardian.selector;

        cut[2] = IDiamondCut.FacetCut({
            facetAddress: address(pauseFacet), action: IDiamondCut.FacetCutAction.Add, functionSelectors: pauseSelectors
        });

        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
    }

    // ============ Pause Tests ============

    function test_InitiallyNotPaused() public view {
        assertFalse(PauseFacet(address(diamond)).paused(), "Should start unpaused");
    }

    function test_OwnerCanPause() public {
        PauseFacet(address(diamond)).pause();
        assertTrue(PauseFacet(address(diamond)).paused(), "Should be paused");
    }

    function test_PauseEmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit Paused(owner);

        PauseFacet(address(diamond)).pause();
    }

    function test_OwnerCanUnpause() public {
        PauseFacet(address(diamond)).pause();
        PauseFacet(address(diamond)).unpause();

        assertFalse(PauseFacet(address(diamond)).paused(), "Should be unpaused");
    }

    function test_UnpauseEmitsEvent() public {
        PauseFacet(address(diamond)).pause();

        vm.expectEmit(true, false, false, false);
        emit Unpaused(owner);

        PauseFacet(address(diamond)).unpause();
    }

    function test_RevertPauseWhenAlreadyPaused() public {
        PauseFacet(address(diamond)).pause();

        vm.expectRevert(LibPause.EnforcedPause.selector);
        PauseFacet(address(diamond)).pause();
    }

    function test_RevertUnpauseWhenNotPaused() public {
        vm.expectRevert(LibPause.ExpectedPause.selector);
        PauseFacet(address(diamond)).unpause();
    }

    function test_RevertPauseNonOwner() public {
        vm.prank(attacker);
        vm.expectRevert(LibPause.NotAuthorized.selector);
        PauseFacet(address(diamond)).pause();
    }

    function test_RevertUnpauseNonOwner() public {
        PauseFacet(address(diamond)).pause();

        vm.prank(attacker);
        vm.expectRevert("LibDiamond: Must be contract owner");
        PauseFacet(address(diamond)).unpause();
    }

    // ============ Guardian Tests ============

    function test_SetPauseGuardian() public {
        PauseFacet(address(diamond)).setPauseGuardian(guardian);

        assertEq(PauseFacet(address(diamond)).pauseGuardian(), guardian, "Guardian should be set");
    }

    function test_SetGuardianEmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit PauseGuardianSet(address(0), guardian);

        PauseFacet(address(diamond)).setPauseGuardian(guardian);
    }

    function test_GuardianCanPause() public {
        PauseFacet(address(diamond)).setPauseGuardian(guardian);

        vm.prank(guardian);
        PauseFacet(address(diamond)).pause();

        assertTrue(PauseFacet(address(diamond)).paused(), "Guardian should be able to pause");
    }

    function test_GuardianCannotUnpause() public {
        PauseFacet(address(diamond)).setPauseGuardian(guardian);

        vm.prank(guardian);
        PauseFacet(address(diamond)).pause();

        vm.prank(guardian);
        vm.expectRevert("LibDiamond: Must be contract owner");
        PauseFacet(address(diamond)).unpause();
    }

    function test_RevertGuardianSetByNonOwner() public {
        vm.prank(attacker);
        vm.expectRevert("LibDiamond: Must be contract owner");
        PauseFacet(address(diamond)).setPauseGuardian(guardian);
    }

    // ============ Integration Test with Mock Facet ============

    function test_LibPauseRequireNotPausedIntegration() public {
        // Deploy mock facet that uses LibPause
        MockPausableFacet mockFacet = new MockPausableFacet();

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = MockPausableFacet.protectedAction.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(mockFacet), action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });

        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");

        // Works when not paused
        MockPausableFacet(address(diamond)).protectedAction();

        // Pause
        PauseFacet(address(diamond)).pause();

        // Reverts when paused
        vm.expectRevert(LibPause.EnforcedPause.selector);
        MockPausableFacet(address(diamond)).protectedAction();

        // Works again after unpause
        PauseFacet(address(diamond)).unpause();
        MockPausableFacet(address(diamond)).protectedAction();
    }
}

// ============ Mock Contracts ============

contract MockPausableFacet {
    event ActionPerformed();

    function protectedAction() external {
        LibPause.requireNotPaused();
        emit ActionPerformed();
    }
}
