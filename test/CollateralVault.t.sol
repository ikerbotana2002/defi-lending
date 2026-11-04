// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockWETH} from "../src/MockWETH.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {ICollateralController} from "../src/interfaces/ICollateralController.sol";

// Simula la futura decision del Lending Protocol.
contract MockCollateralController is ICollateralController {
    bool public allowed = true;

    function setAllowed(bool value) external {
        allowed = value;
    }

    function canWithdraw(address, uint256) external view returns (bool) {
        return allowed;
    }
}

contract CollateralVaultTest is Test {
    MockWETH weth;
    CollateralVault vault;
    MockCollateralController controller;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        weth = new MockWETH();
        vault = new CollateralVault(address(weth));
        controller = new MockCollateralController();

        weth.transfer(alice, 10 ether);
        weth.transfer(bob, 10 ether);

        vm.prank(alice);
        weth.approve(address(vault), type(uint256).max);

        vm.prank(bob);
        weth.approve(address(vault), type(uint256).max);
    }

    // 1. Alicia deposita 2 WETH.
    function testDepositCollateral() public {
        vm.prank(alice);
        vault.depositCollateral(2 ether);

        assertEq(vault.collateralBalances(alice), 2 ether);

        assertEq(vault.totalCollateral(), 2 ether);

        assertEq(weth.balanceOf(address(vault)), 2 ether);

        assertEq(weth.balanceOf(alice), 8 ether);
    }

    // 2. Dos usuarios depositan.
    function testMultipleDepositors() public {
        vm.prank(alice);
        vault.depositCollateral(2 ether);

        vm.prank(bob);
        vault.depositCollateral(3 ether);

        assertEq(vault.getCollateralBalance(alice), 2 ether);

        assertEq(vault.getCollateralBalance(bob), 3 ether);

        assertEq(vault.totalCollateral(), 5 ether);
    }

    // 3. Retirada parcial.
    function testPartialWithdrawal() public {
        vm.prank(alice);
        vault.depositCollateral(2 ether);

        vm.prank(alice);
        vault.withdrawCollateral(0.5 ether);

        assertEq(vault.collateralBalances(alice), 1.5 ether);

        assertEq(vault.totalCollateral(), 1.5 ether);
        assertEq(weth.balanceOf(alice), 8.5 ether);
    }

    // 4. Retirada completa sin prestamos.
    function testFullWithdrawal() public {
        vm.prank(alice);
        vault.depositCollateral(2 ether);

        vm.prank(alice);
        vault.withdrawCollateral(2 ether);

        assertEq(vault.collateralBalances(alice), 0);
        assertEq(vault.totalCollateral(), 0);
        assertEq(weth.balanceOf(alice), 10 ether);
    }

    // 5. No permite depositar cero.
    function testRevertZeroDeposit() public {
        vm.prank(alice);
        vm.expectRevert(CollateralVault.ZeroAmount.selector);

        vault.depositCollateral(0);
    }

    // 6. No permite retirar cero.
    function testRevertZeroWithdrawal() public {
        vm.prank(alice);
        vm.expectRevert(CollateralVault.ZeroAmount.selector);

        vault.withdrawCollateral(0);
    }

    // 7. No permite retirar mas de lo depositado.
    function testRevertInsufficientCollateral() public {
        vm.prank(alice);
        vault.depositCollateral(2 ether);

        vm.prank(alice);
        vm.expectRevert(CollateralVault.InsufficientCollateral.selector);

        vault.withdrawCollateral(3 ether);
    }

    // 8. Bob no puede retirar lo de Alicia.
    function testCannotWithdrawAnotherUsersCollateral() public {
        vm.prank(alice);
        vault.depositCollateral(2 ether);

        vm.prank(bob);
        vm.expectRevert(CollateralVault.InsufficientCollateral.selector);

        vault.withdrawCollateral(1 ether);
    }

    // 9. Configuracion del controlador.
    function testOwnerSetsRiskController() public {
        vault.setRiskController(address(controller));

        assertEq(address(vault.riskController()), address(controller));
    }

    // 10. Solo el owner configura el controlador.
    function testNonOwnerCannotSetController() public {
        vm.prank(alice);
        vm.expectRevert(CollateralVault.Unauthorized.selector);

        vault.setRiskController(address(controller));
    }

    // 11. No puede reemplazarse el controlador.
    function testCannotReplaceController() public {
        vault.setRiskController(address(controller));

        vm.expectRevert(CollateralVault.ControllerAlreadySet.selector);

        vault.setRiskController(address(controller));
    }

    // 12. El controlador bloquea una retirada insegura.
    function testControllerBlocksUnsafeWithdrawal() public {
        vm.prank(alice);
        vault.depositCollateral(2 ether);

        vault.setRiskController(address(controller));
        controller.setAllowed(false);

        vm.prank(alice);
        vm.expectRevert(CollateralVault.UnsafeWithdrawal.selector);

        vault.withdrawCollateral(1 ether);

        assertEq(vault.collateralBalances(alice), 2 ether);
    }

    // 13. El controlador permite una retirada segura.
    function testControllerAllowsSafeWithdrawal() public {
        vm.prank(alice);
        vault.depositCollateral(2 ether);

        vault.setRiskController(address(controller));
        controller.setAllowed(true);

        vm.prank(alice);
        vault.withdrawCollateral(1 ether);

        assertEq(vault.collateralBalances(alice), 1 ether);
    }
}
