// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../src/MockUSDC.sol";
import {MockWETH} from "../src/MockWETH.sol";
import {LiquidityPool} from "../src/LiquidityPool.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {LendingProtocol} from "../src/LendingProtocol.sol";

import {SecurePriceOracle} from "../lib/oracle-integration/src/SecurePriceOracle.sol";

import {AdversarialPriceFeed} from "../lib/oracle-integration/test/mocks/AdversarialPriceFeed.sol";

contract LendingRepaymentTest is Test {
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

    function setUp() public {
        vm.warp(1_000_000);

        usdc = new MockUSDC();
        weth = new MockWETH();

        pool = new LiquidityPool(address(usdc));
        vault = new CollateralVault(address(weth));

        feed = new AdversarialPriceFeed(8);
        feed.setData(3000e8, block.timestamp);

        oracle = new SecurePriceOracle(address(feed), 1 hours);

        lending = new LendingProtocol(address(pool), address(vault), address(oracle));

        pool.setLendingController(address(lending));
        vault.setRiskController(address(lending));

        usdc.transfer(bob, 10_000 * USDC);
        weth.transfer(alice, 10 ether);

        vm.prank(bob);
        usdc.approve(address(pool), type(uint256).max);

        vm.prank(alice);
        weth.approve(address(vault), type(uint256).max);

        // Aprobar USDC para futuras devoluciones.
        vm.prank(alice);
        usdc.approve(address(pool), type(uint256).max);

        vm.prank(bob);
        pool.deposit(5_000 * USDC);

        vm.prank(alice);
        vault.depositCollateral(2 ether);

        vm.prank(alice);
        lending.borrow(3_000 * USDC);
    }

    // 1. Devolucion parcial.
    function testPartialRepayment() public {
        vm.prank(alice);
        lending.repay(1_000 * USDC);

        assertEq(lending.debt(alice), 2_000 * USDC);

        assertEq(pool.totalBorrowed(), 2_000 * USDC);

        assertEq(pool.availableLiquidity(), 3_000 * USDC);

        assertEq(usdc.balanceOf(alice), 2_000 * USDC);
    }

    // 2. Devolucion completa.
    function testFullRepayment() public {
        vm.prank(alice);
        lending.repay(3_000 * USDC);

        assertEq(lending.debt(alice), 0);
        assertEq(pool.totalBorrowed(), 0);

        assertEq(pool.availableLiquidity(), 5_000 * USDC);

        assertEq(usdc.balanceOf(alice), 0);
    }

    // 3. Devolver en varios pagos.
    function testMultipleRepayments() public {
        vm.startPrank(alice);

        lending.repay(1_000 * USDC);
        lending.repay(500 * USDC);
        lending.repay(1_500 * USDC);

        vm.stopPrank();

        assertEq(lending.debt(alice), 0);
        assertEq(pool.totalBorrowed(), 0);
    }

    // 4. No permite devolver cero.
    function testRevertZeroRepayment() public {
        vm.prank(alice);
        vm.expectRevert(LendingProtocol.ZeroAmount.selector);
        lending.repay(0);
    }

    // 5. No permite devolver mas de lo debido.
    function testRevertExcessRepayment() public {
        vm.prank(alice);
        vm.expectRevert(LendingProtocol.RepaymentExceedsDebt.selector);

        lending.repay(3_001 * USDC);

        assertEq(lending.debt(alice), 3_000 * USDC);
    }

    // 6. Un usuario sin deuda no puede devolver.
    function testRevertWhenNoDebt() public {
        vm.prank(bob);
        vm.expectRevert(LendingProtocol.NoDebt.selector);

        lending.repay(100 * USDC);
    }

    // 7. Retirada de garantia antes de devolver.
    function testWithdrawalBlockedBeforeRepayment() public {
        vm.prank(alice);
        vm.expectRevert(CollateralVault.UnsafeWithdrawal.selector);
        vault.withdrawCollateral(0.5 ether);
    }

    // 8. Tras devolver, puede retirar mas garantia.
    function testRepaymentUnlocksCollateral() public {
        vm.prank(alice);
        lending.repay(1_000 * USDC);

        vm.prank(alice);
        vault.withdrawCollateral(0.5 ether);

        assertEq(vault.collateralBalances(alice), 1.5 ether);

        assertEq(lending.debt(alice), 2_000 * USDC);

        assertEq(weth.balanceOf(alice), 8.5 ether);
    }

    // 9. Al devolver todo, recupera todo el WETH.
    function testFullRepaymentUnlocksAllCollateral() public {
        vm.prank(alice);
        lending.repay(3_000 * USDC);

        vm.prank(alice);
        vault.withdrawCollateral(2 ether);

        assertEq(vault.collateralBalances(alice), 0);
        assertEq(vault.totalCollateral(), 0);
        assertEq(weth.balanceOf(alice), 10 ether);
    }

    // 10. El pool no acepta devoluciones
    // solicitadas por direcciones no autorizadas.
    function testUnauthorizedRepaymentReverts() public {
        vm.prank(alice);
        vm.expectRevert(LiquidityPool.Unauthorized.selector);

        pool.repayFrom(alice, 100 * USDC);
    }

    // 11. Una transferencia fallida no cancela deuda.
    function testRepaymentRevertsWithoutAllowance() public {
        vm.prank(alice);
        usdc.approve(address(pool), 0);

        vm.prank(alice);
        vm.expectRevert();
        lending.repay(1_000 * USDC);

        assertEq(lending.debt(alice), 3_000 * USDC);

        assertEq(pool.totalBorrowed(), 3_000 * USDC);
    }

    // 12. Fuzz de devoluciones parciales.
    function testFuzzRepayment(uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 1, 3_000 * USDC);

        vm.prank(alice);
        lending.repay(amount);

        uint256 remaining = 3_000 * USDC - amount;

        assertEq(lending.debt(alice), remaining);
        assertEq(pool.totalBorrowed(), remaining);

        assertEq(pool.availableLiquidity(), 5_000 * USDC - remaining);

        assertEq(usdc.balanceOf(alice), remaining);
    }
}
