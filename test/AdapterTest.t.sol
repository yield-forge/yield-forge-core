// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {CurveAdapter} from "../src/adapters/CurveAdapter.sol";
import {UniswapV3Adapter} from "../src/adapters/UniswapV3Adapter.sol";
import {UniswapV4Adapter} from "../src/adapters/UniswapV4Adapter.sol";

/**
 * @title AdapterTest
 * @notice Tests for adapter access control and basic functionality
 * @dev Uses mock contracts to test adapter behavior in isolation
 */
contract AdapterTest is Test {
    address diamond = address(0xD1A);
    address attacker = address(0xBAD);
    address crvToken = address(0xCCC);

    CurveAdapter curveAdapter;

    function setUp() public {
        curveAdapter = new CurveAdapter(diamond, crvToken);
    }

    // ================================================================
    //                    CURVE ADAPTER TESTS
    // ================================================================

    function test_CurveAdapter_OnlyDiamondCanAddLiquidity() public {
        bytes memory params = abi.encode(address(0), address(0), 0, 0);

        vm.prank(attacker);
        vm.expectRevert();
        curveAdapter.addLiquidity(params);
    }

    function test_CurveAdapter_OnlyDiamondCanRemoveLiquidity() public {
        bytes memory params = abi.encode(address(0), address(0));

        vm.prank(attacker);
        vm.expectRevert();
        curveAdapter.removeLiquidity(0, params);
    }

    function test_CurveAdapter_OnlyDiamondCanCollectYield() public {
        bytes memory params = abi.encode(address(0), address(0));

        vm.prank(attacker);
        vm.expectRevert();
        curveAdapter.collectYield(params);
    }

    function test_CurveAdapter_ProtocolId() public view {
        assertEq(curveAdapter.protocolId(), "CRV");
    }

    function test_CurveAdapter_DiamondAddress() public view {
        assertEq(curveAdapter.diamond(), diamond);
    }

    function test_CurveAdapter_CrvToken() public view {
        assertEq(curveAdapter.crvToken(), crvToken);
    }

    function test_CurveAdapter_ConstructorRevertsOnZeroDiamond() public {
        vm.expectRevert("Zero diamond");
        new CurveAdapter(address(0), crvToken);
    }

    function test_CurveAdapter_ConstructorRevertsOnZeroCrv() public {
        vm.expectRevert("Zero CRV token");
        new CurveAdapter(diamond, address(0));
    }
}

/**
 * @title UniswapV3AdapterTest
 * @notice Tests for UniswapV3Adapter access control
 */
contract UniswapV3AdapterTest is Test {
    address diamond = address(0xD1A);
    address attacker = address(0xBAD);
    address positionManager = address(0x555);
    address factory = address(0x666);

    UniswapV3Adapter v3Adapter;

    function setUp() public {
        v3Adapter = new UniswapV3Adapter(positionManager, factory, diamond);
    }

    function test_V3Adapter_OnlyDiamondCanAddLiquidity() public {
        bytes memory params = abi.encode(
            address(0xABC),
            uint256(100e18),
            uint256(100e18)
        );

        vm.prank(attacker);
        vm.expectRevert();
        v3Adapter.addLiquidity(params);
    }

    function test_V3Adapter_OnlyDiamondCanRemoveLiquidity() public {
        bytes memory params = abi.encode(address(0xABC));

        vm.prank(attacker);
        vm.expectRevert();
        v3Adapter.removeLiquidity(0, params);
    }

    function test_V3Adapter_ProtocolId() public view {
        assertEq(v3Adapter.protocolId(), "V3");
    }

    function test_V3Adapter_DiamondAddress() public view {
        assertEq(v3Adapter.diamond(), diamond);
    }

    function test_V3Adapter_ConstructorRevertsOnZeroPositionManager() public {
        vm.expectRevert("Zero position manager");
        new UniswapV3Adapter(address(0), factory, diamond);
    }

    function test_V3Adapter_ConstructorRevertsOnZeroFactory() public {
        vm.expectRevert("Zero factory");
        new UniswapV3Adapter(positionManager, address(0), diamond);
    }

    function test_V3Adapter_ConstructorRevertsOnZeroDiamond() public {
        vm.expectRevert("Zero diamond");
        new UniswapV3Adapter(positionManager, factory, address(0));
    }
}

/**
 * @title UniswapV4AdapterTest
 * @notice Tests for UniswapV4Adapter access control
 */
contract UniswapV4AdapterTest is Test {
    address diamond = address(0xD1A);
    address attacker = address(0xBAD);
    address poolManager = address(0x444);

    UniswapV4Adapter v4Adapter;

    function setUp() public {
        v4Adapter = new UniswapV4Adapter(poolManager, diamond);
    }

    function test_V4Adapter_OnlyDiamondCanAddLiquidity() public {
        bytes memory params = abi.encode(new bytes(0), uint256(0), uint256(0));

        vm.prank(attacker);
        vm.expectRevert();
        v4Adapter.addLiquidity(params);
    }

    function test_V4Adapter_OnlyDiamondCanRemoveLiquidity() public {
        bytes memory params = abi.encode(new bytes(0));

        vm.prank(attacker);
        vm.expectRevert();
        v4Adapter.removeLiquidity(0, params);
    }

    function test_V4Adapter_ProtocolId() public view {
        assertEq(v4Adapter.protocolId(), "V4");
    }

    function test_V4Adapter_DiamondAddress() public view {
        assertEq(v4Adapter.diamond(), diamond);
    }

    function test_V4Adapter_ConstructorRevertsOnZeroPoolManager() public {
        vm.expectRevert("Zero pool manager");
        new UniswapV4Adapter(address(0), diamond);
    }

    function test_V4Adapter_ConstructorRevertsOnZeroDiamond() public {
        vm.expectRevert("Zero diamond");
        new UniswapV4Adapter(poolManager, address(0));
    }
}
