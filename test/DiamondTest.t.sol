// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Diamond} from "../src/Diamond.sol";
import {DiamondCutFacet} from "../src/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../src/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {IERC173} from "../src/interfaces/IERC173.sol";
import {IERC165} from "../src/interfaces/IERC165.sol";
import {LibDiamond} from "../src/libraries/LibDiamond.sol";

/**
 * @title DiamondTest
 * @notice Comprehensive tests for Diamond proxy infrastructure
 * @dev Tests deployment, facet management, and ownership
 */
contract DiamondTest is Test {
    Diamond diamond;
    DiamondCutFacet diamondCutFacet;
    DiamondLoupeFacet diamondLoupeFacet;
    OwnershipFacet ownershipFacet;

    address owner = address(this);
    address user1 = address(0x1);
    address user2 = address(0x2);

    // Events
    event DiamondCut(IDiamondCut.FacetCut[] _diamondCut, address _init, bytes _calldata);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        // 1. Deploy DiamondCutFacet
        diamondCutFacet = new DiamondCutFacet();

        // 2. Deploy Diamond with owner and DiamondCutFacet
        diamond = new Diamond(owner, address(diamondCutFacet));

        // 3. Deploy other facets
        diamondLoupeFacet = new DiamondLoupeFacet();
        ownershipFacet = new OwnershipFacet();

        // 4. Add DiamondLoupeFacet
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](2);

        // DiamondLoupeFacet selectors
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

        // OwnershipFacet selectors
        bytes4[] memory ownershipSelectors = new bytes4[](2);
        ownershipSelectors[0] = IERC173.owner.selector;
        ownershipSelectors[1] = IERC173.transferOwnership.selector;

        cut[1] = IDiamondCut.FacetCut({
            facetAddress: address(ownershipFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: ownershipSelectors
        });

        // Execute diamond cut
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
    }

    // ============ Deployment Tests ============

    function test_DeploymentSetsOwner() public view {
        address diamondOwner = OwnershipFacet(address(diamond)).owner();
        assertEq(diamondOwner, owner, "Owner should be set correctly");
    }

    function test_DiamondCutFacetIsAdded() public view {
        address facet = IDiamondLoupe(address(diamond)).facetAddress(IDiamondCut.diamondCut.selector);
        assertEq(facet, address(diamondCutFacet), "DiamondCutFacet should be at correct address");
    }

    function test_AllFacetsAreRegistered() public view {
        address[] memory facetAddresses = IDiamondLoupe(address(diamond)).facetAddresses();
        assertEq(facetAddresses.length, 3, "Should have 3 facets");
    }

    // ============ Loupe Tests ============

    function test_FacetsReturnsAllFacets() public view {
        IDiamondLoupe.Facet[] memory facets = IDiamondLoupe(address(diamond)).facets();
        assertEq(facets.length, 3, "Should return 3 facets");

        // Verify each facet has selectors
        for (uint256 i = 0; i < facets.length; i++) {
            assertTrue(facets[i].functionSelectors.length > 0, "Each facet should have selectors");
        }
    }

    function test_FacetFunctionSelectorsReturnsCorrectSelectors() public view {
        bytes4[] memory selectors = IDiamondLoupe(address(diamond)).facetFunctionSelectors(address(ownershipFacet));
        assertEq(selectors.length, 2, "OwnershipFacet should have 2 selectors");
    }

    function test_FacetAddressReturnsZeroForUnknownSelector() public view {
        bytes4 unknownSelector = bytes4(keccak256("unknownFunction()"));
        address facet = IDiamondLoupe(address(diamond)).facetAddress(unknownSelector);
        assertEq(facet, address(0), "Unknown selector should return address(0)");
    }

    // ============ Ownership Tests ============

    function test_TransferOwnership() public {
        OwnershipFacet(address(diamond)).transferOwnership(user1);

        address newOwner = OwnershipFacet(address(diamond)).owner();
        assertEq(newOwner, user1, "Ownership should be transferred");
    }

    function test_TransferOwnershipEmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferred(owner, user1);

        OwnershipFacet(address(diamond)).transferOwnership(user1);
    }

    function test_RevertWhenNonOwnerTransfersOwnership() public {
        vm.prank(user1);
        vm.expectRevert("LibDiamond: Must be contract owner");
        OwnershipFacet(address(diamond)).transferOwnership(user2);
    }

    // ============ DiamondCut Tests ============

    function test_AddNewFacet() public {
        // Deploy a mock facet
        MockFacet mockFacet = new MockFacet();

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = MockFacet.getValue.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(mockFacet), action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });

        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");

        // Verify facet was added
        address facetAddress = IDiamondLoupe(address(diamond)).facetAddress(MockFacet.getValue.selector);
        assertEq(facetAddress, address(mockFacet), "MockFacet should be added");

        // Call function through diamond
        uint256 value = MockFacet(address(diamond)).getValue();
        assertEq(value, 42, "MockFacet function should work through diamond");
    }

    function test_ReplaceFacetFunction() public {
        // First add MockFacet
        MockFacet mockFacet = new MockFacet();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = MockFacet.getValue.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(mockFacet), action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");

        // Now replace with MockFacetV2
        MockFacetV2 mockFacetV2 = new MockFacetV2();

        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(mockFacetV2), action: IDiamondCut.FacetCutAction.Replace, functionSelectors: selectors
        });
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");

        // Verify the function now returns V2 value
        uint256 value = MockFacet(address(diamond)).getValue();
        assertEq(value, 100, "Should return V2 value after replacement");
    }

    function test_RemoveFacetFunction() public {
        // First add MockFacet
        MockFacet mockFacet = new MockFacet();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = MockFacet.getValue.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(mockFacet), action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");

        // Now remove the function
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(0), // Must be address(0) for Remove
            action: IDiamondCut.FacetCutAction.Remove,
            functionSelectors: selectors
        });
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");

        // Verify function no longer exists
        address facetAddress = IDiamondLoupe(address(diamond)).facetAddress(MockFacet.getValue.selector);
        assertEq(facetAddress, address(0), "Function should be removed");

        // Calling should revert
        vm.expectRevert("Diamond: Function does not exist");
        MockFacet(address(diamond)).getValue();
    }

    function test_RevertWhenNonOwnerCallsDiamondCut() public {
        MockFacet mockFacet = new MockFacet();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = MockFacet.getValue.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(mockFacet), action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });

        vm.prank(user1);
        vm.expectRevert("LibDiamond: Must be contract owner");
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
    }

    function test_RevertWhenAddingExistingSelector() public {
        // Try to add owner() selector which already exists
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IERC173.owner.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(ownershipFacet), action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });

        vm.expectRevert("LibDiamondCut: Can't add function that already exists");
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
    }

    // ============ Initialization Test ============

    function test_DiamondCutWithInitialization() public {
        // Deploy init contract
        DiamondInit diamondInit = new DiamondInit();

        // Add MockFacet with setValue selector
        MockFacetWithState mockFacet = new MockFacetWithState();
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = MockFacetWithState.getValue.selector;
        selectors[1] = MockFacetWithState.setValue.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(mockFacet), action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });

        // Call diamondCut with initialization that sets a value
        bytes memory initCalldata = abi.encodeWithSelector(DiamondInit.init.selector, 999);
        IDiamondCut(address(diamond)).diamondCut(cut, address(diamondInit), initCalldata);

        // Verify initialization set the value in Diamond's storage context
        uint256 value = MockFacetWithState(address(diamond)).getValue();
        assertEq(value, 999, "Init should have set value to 999");
    }

    // ============ ETH Receive Test ============

    function test_DiamondCanReceiveETH() public {
        uint256 amount = 1 ether;
        vm.deal(address(this), amount);

        (bool success,) = address(diamond).call{value: amount}("");
        assertTrue(success, "Diamond should accept ETH");
        assertEq(address(diamond).balance, amount, "Diamond balance should be 1 ether");
    }
}

// ============ Mock Contracts for Testing ============

contract MockFacet {
    function getValue() external pure returns (uint256) {
        return 42;
    }

    function setValue(uint256) external pure {
        // Does nothing, just for testing selector
    }
}

contract MockFacetV2 {
    function getValue() external pure returns (uint256) {
        return 100;
    }
}

// Uses Diamond storage pattern for state
contract MockFacetWithState {
    // Storage position for mock data
    bytes32 constant MOCK_STORAGE_POSITION = keccak256("mock.facet.storage");

    struct MockStorage {
        uint256 value;
    }

    function mockStorage() internal pure returns (MockStorage storage ms) {
        bytes32 position = MOCK_STORAGE_POSITION;
        assembly {
            ms.slot := position
        }
    }

    function getValue() external view returns (uint256) {
        return mockStorage().value;
    }

    function setValue(uint256 _value) external {
        mockStorage().value = _value;
    }
}

contract DiamondInit {
    // Uses same storage position as MockFacetWithState
    bytes32 constant MOCK_STORAGE_POSITION = keccak256("mock.facet.storage");

    struct MockStorage {
        uint256 value;
    }

    function mockStorage() internal pure returns (MockStorage storage ms) {
        bytes32 position = MOCK_STORAGE_POSITION;
        assembly {
            ms.slot := position
        }
    }

    function init(uint256 _value) external {
        mockStorage().value = _value;
    }
}
