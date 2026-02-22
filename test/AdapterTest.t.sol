// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {UniswapV3Adapter} from "../src/adapters/UniswapV3Adapter.sol";
import {UniswapV4Adapter} from "../src/adapters/UniswapV4Adapter.sol";

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
        bytes memory poolParams = abi.encode(address(0xABC));

        vm.prank(attacker);
        vm.expectRevert();
        v3Adapter.addLiquidity(poolParams, 100e18, 100e18);
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
        bytes memory poolParams = abi.encode(new bytes(0));

        vm.prank(attacker);
        vm.expectRevert();
        v4Adapter.addLiquidity(poolParams, 0, 0);
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
