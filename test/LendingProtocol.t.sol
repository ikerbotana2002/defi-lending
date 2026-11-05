// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../src/MockUSDC.sol";
import {MockWETH} from "../src/MockWETH.sol";
import {LiquidityPool} from "../src/LiquidityPool.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {LendingProtocol} from "../src/LendingProtocol.sol";

// Reutilizamos los contratos del Proyecto 9.
import {SecurePriceOracle} from "../lib/oracle-integration/src/SecurePriceOracle.sol";

import {AdversarialPriceFeed} from "../lib/oracle-integration/test/mocks/AdversarialPriceFeed.sol";

contract LendingProtocolTest is Test {
    MockUSDC usdc;
    MockWETH weth;
    LiquidityPool pool;
    CollateralVault vault;
    SecurePriceOracle oracle;
    AdversarialPriceFeed feed;
    LendingProtocol lending;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 constant USDC = 1e6;
    uint256 constant MAX_AGE = 1 hours;

    function setUp() public {
        vm.warp(1_000_000);

        usdc = new MockUSDC();
        weth = new MockWETH();

        pool = new LiquidityPool(address(usdc));
        vault = new CollateralVault(address(weth));

        feed = new AdversarialPriceFeed(8);
        feed.setData(3000e8, block.timestamp);

        oracle = new SecurePriceOracle(address(feed), MAX_AGE);

        lending = new LendingProtocol(address(pool), address(vault), address(oracle));

        // Solo LendingProtocol puede ordenar prestamos.
        pool.setLendingController(address(lending));

        // LendingProtocol decide si puede retirarse WETH.
        vault.setRiskController(address(lending));

        usdc.transfer(bob, 30_000 * USDC);
        weth.transfer(alice, 10 ether);

        vm.prank(bob);
        usdc.approve(address(pool), type(uint256).max);

        vm.prank(alice);
        weth.approve(address(vault), type(uint256).max);
    }

    function _provideLiquidity(uint256 amount) internal {
        vm.prank(bob);
        pool.deposit(amount);
    }

    function _depositCollateral(uint256 amount) internal {
        vm.prank(alice);
        vault.depositCollateral(amount);
    }

    // 1. Prestamo real de USDC al prestatario.
    function testBorrowTransfersUSDC() public {
        _provideLiquidity(5000 * USDC);
        _depositCollateral(2 ether);

        vm.prank(alice);
        lending.borrow(3000 * USDC);

        assertEq(lending.debt(alice), 3000 * USDC);
        assertEq(usdc.balanceOf(alice), 3000 * USDC);
        assertEq(pool.totalBorrowed(), 3000 * USDC);
        assertEq(pool.totalDeposits(), 5000 * USDC);
        assertEq(pool.availableLiquidity(), 2000 * USDC);
    }

    // 2. Valor de garantia y limite correctos.
    function testCalculatesBorrowLimit() public {
        _depositCollateral(2 ether);

        assertEq(lending.getCollateralValueUsd18(alice), 6000 ether);

        assertEq(lending.getMaxDebt(alice), 3000 * USDC);
    }

    // 3. No permite pedir prestado sin garantia.
    function testRejectsBorrowWithoutCollateral() public {
        _provideLiquidity(5000 * USDC);

        vm.prank(alice);
        vm.expectRevert(LendingProtocol.InsufficientCollateral.selector);
        lending.borrow(1 * USDC);
    }

    // 4. No permite superar el 50% LTV.
    function testRejectsBorrowAboveLTV() public {
        _provideLiquidity(5000 * USDC);
        _depositCollateral(2 ether);

        vm.prank(alice);
        vm.expectRevert(LendingProtocol.InsufficientCollateral.selector);
        lending.borrow(3001 * USDC);
    }

    // 5. No permite prestar mas liquidez de la disponible.
    function testRejectsInsufficientLiquidity() public {
        _provideLiquidity(1000 * USDC);
        _depositCollateral(2 ether);

        vm.prank(alice);
        vm.expectRevert(LiquidityPool.InsufficientLiquidity.selector);
        lending.borrow(2000 * USDC);

        // El revert conserva la deuda anterior.
        assertEq(lending.debt(alice), 0);
    }

    // 6. El usuario no puede retirar garantia insegura.
    function testBorrowBlocksUnsafeWithdrawal() public {
        _provideLiquidity(5000 * USDC);
        _depositCollateral(2 ether);

        vm.prank(alice);
        lending.borrow(3000 * USDC);

        vm.prank(alice);
        vm.expectRevert(CollateralVault.UnsafeWithdrawal.selector);
        vault.withdrawCollateral(1 ether);

        assertEq(vault.collateralBalances(alice), 2 ether);
    }

    // 7. Una retirada que respeta el LTV si funciona.
    function testAllowsSafeCollateralWithdrawal() public {
        _provideLiquidity(5000 * USDC);
        _depositCollateral(2 ether);

        vm.prank(alice);
        lending.borrow(1500 * USDC);

        vm.prank(alice);
        vault.withdrawCollateral(1 ether);

        assertEq(vault.collateralBalances(alice), 1 ether);
        assertEq(lending.debt(alice), 1500 * USDC);
    }

    // 8. No se pueden ordenar prestamos sin autorizacion.
    function testUnauthorizedPoolLoanReverts() public {
        _provideLiquidity(5000 * USDC);

        vm.prank(alice);
        vm.expectRevert(LiquidityPool.Unauthorized.selector);

        pool.lendTo(alice, 1000 * USDC);
    }

    // 9. Cuando ETH cae, se reduce la capacidad.
    function testPriceDropReducesBorrowLimit() public {
        _depositCollateral(2 ether);

        assertEq(lending.getMaxDebt(alice), 3000 * USDC);

        feed.setData(1500e8, block.timestamp);

        assertEq(lending.getMaxDebt(alice), 1500 * USDC);
    }

    // 10. No se acepta un precio obsoleto.
    function testBorrowRejectsStalePrice() public {
        _provideLiquidity(5000 * USDC);
        _depositCollateral(2 ether);

        vm.warp(block.timestamp + MAX_AGE + 1);

        vm.prank(alice);
        vm.expectRevert(SecurePriceOracle.StalePrice.selector);

        lending.borrow(100 * USDC);
    }

    // 11. No se puede pedir cero.
    function testRejectsZeroBorrow() public {
        vm.prank(alice);
        vm.expectRevert(LendingProtocol.ZeroAmount.selector);

        lending.borrow(0);
    }

    // 12. Se pueden solicitar varios prestamos.
    function testMultipleBorrowsTrackDebt() public {
        _provideLiquidity(5000 * USDC);
        _depositCollateral(2 ether);

        vm.startPrank(alice);
        lending.borrow(1000 * USDC);
        lending.borrow(500 * USDC);
        vm.stopPrank();

        assertEq(lending.debt(alice), 1500 * USDC);
        assertEq(usdc.balanceOf(alice), 1500 * USDC);
        assertEq(pool.totalBorrowed(), 1500 * USDC);
    }

    // 13. Fuzz: cantidades validas dentro del LTV.
    function testFuzzBorrowWithinLimit(uint256 rawAmount) public {
        _provideLiquidity(10_000 * USDC);
        _depositCollateral(2 ether);

        uint256 amount = bound(rawAmount, 1, 3000 * USDC);

        vm.prank(alice);
        lending.borrow(amount);

        assertEq(lending.debt(alice), amount);
        assertEq(usdc.balanceOf(alice), amount);
        assertEq(pool.availableLiquidity(), 10_000 * USDC - amount);
    }
}
