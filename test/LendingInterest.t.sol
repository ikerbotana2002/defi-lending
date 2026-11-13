// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {MockUSDC} from "../src/MockUSDC.sol";
import {MockWETH} from "../src/MockWETH.sol";
import {LiquidityPool} from "../src/LiquidityPool.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {LendingProtocol} from "../src/LendingProtocol.sol";

import {SecurePriceOracle} from "../lib/oracle-integration/src/SecurePriceOracle.sol";
import {AdversarialPriceFeed} from "../lib/oracle-integration/test/mocks/AdversarialPriceFeed.sol";

contract LendingInterestTest is Test {
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
    uint256 constant APR_BPS = 1_000;
    uint256 constant BPS = 10_000;
    uint256 constant YEAR = 365 days;

    uint256 start;

    function setUp() public {
        vm.warp(1_000_000);
        start = block.timestamp;

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

        vm.prank(alice);
        usdc.approve(address(pool), type(uint256).max);

        vm.prank(bob);
        pool.deposit(5_000 * USDC);

        vm.prank(alice);
        vault.depositCollateral(2 ether);

        vm.prank(alice);
        lending.borrow(3_000 * USDC);
    }

    function _expectedInterest(uint256 principal, uint256 elapsed) internal pure returns (uint256) {
        return Math.mulDiv(principal, APR_BPS * elapsed, BPS * YEAR);
    }

    // 1. En el momento del prestamo no hay intereses.
    function testNoInterestImmediatelyAfterBorrow() public view {
        assertEq(lending.debt(alice), 3_000 * USDC);
        assertEq(lending.getAccruedInterest(alice), 0);
        assertEq(lending.getTotalDebt(alice), 3_000 * USDC);
    }

    // 2. El interes de treinta dias es correcto.
    function testInterestAfterThirtyDays() public {
        vm.warp(start + 30 days);

        assertEq(lending.getAccruedInterest(alice), 24_657_534);

        assertEq(lending.getTotalDebt(alice), 3_024_657_534);

        assertEq(lending.storedInterest(alice), 0);
    }

    // 3. Despues de un anio el interes es del 10%.
    function testInterestAfterOneYear() public {
        vm.warp(start + YEAR);

        assertEq(lending.getAccruedInterest(alice), 300 * USDC);

        assertEq(lending.getTotalDebt(alice), 3_300 * USDC);
    }

    // 4. Si paga menos que los intereses, no reduce capital.
    function testRepaymentPaysInterestFirst() public {
        vm.warp(start + 30 days);

        vm.prank(alice);
        lending.repay(10 * USDC);

        assertEq(lending.debt(alice), 3_000 * USDC);
        assertEq(lending.storedInterest(alice), 14_657_534);

        assertEq(pool.totalBorrowed(), 3_000 * USDC);

        assertEq(pool.totalInterestCollected(), 10 * USDC);

        assertEq(pool.availableLiquidity(), 2_010 * USDC);
    }

    // 5. Una devolucion mayor paga intereses y capital.
    function testRepaymentSplitsInterestAndPrincipal() public {
        vm.warp(start + 30 days);

        uint256 interest = lending.getAccruedInterest(alice);

        // Paga todos los intereses y 500 USDC de capital.
        vm.prank(alice);
        lending.repay(interest + 500 * USDC);

        assertEq(lending.debt(alice), 2_500 * USDC);
        assertEq(lending.storedInterest(alice), 0);

        assertEq(pool.totalBorrowed(), 2_500 * USDC);

        assertEq(pool.totalInterestCollected(), interest);
    }

    // 6. Devolucion total con intereses.
    function testFullRepaymentWithInterest() public {
        vm.warp(start + 30 days);

        uint256 interest = lending.getAccruedInterest(alice);

        // Alicia necesita USDC adicionales para pagar
        // los intereses del prestamo.
        usdc.transfer(alice, 100 * USDC);

        vm.prank(alice);
        lending.repay(3_000 * USDC + interest);

        assertEq(lending.debt(alice), 0);
        assertEq(lending.getAccruedInterest(alice), 0);
        assertEq(lending.getTotalDebt(alice), 0);

        assertEq(pool.totalBorrowed(), 0);

        assertEq(pool.availableLiquidity(), 5_000 * USDC + interest);

        assertEq(pool.totalInterestCollected(), interest);
    }

    // 7. Los intereses no se generan sobre capital devuelto.
    function testInterestAfterPartialPrincipalRepayment() public {
        vm.warp(start + 30 days);

        uint256 firstInterest = lending.getAccruedInterest(alice);

        vm.prank(alice);
        lending.repay(firstInterest + 1_000 * USDC);

        assertEq(lending.debt(alice), 2_000 * USDC);

        vm.warp(start + 60 days);

        uint256 secondInterest = _expectedInterest(2_000 * USDC, 30 days);

        assertEq(lending.getAccruedInterest(alice), secondInterest);
    }

    // 8. Un nuevo prestamo conserva los intereses anteriores.
    function testAdditionalBorrowAccruesPreviousInterest() public {
        vm.warp(start + 30 days);

        uint256 previousInterest = lending.getAccruedInterest(alice);

        // Aumenta la garantia para permitir otro prestamo.
        vm.prank(alice);
        vault.depositCollateral(1 ether);

        // Refrescar el feed simulado para que no este obsoleto.
        feed.setData(3000e8, block.timestamp);

        vm.prank(alice);
        lending.borrow(500 * USDC);

        assertEq(lending.debt(alice), 3_500 * USDC);

        assertEq(lending.storedInterest(alice), previousInterest);

        assertEq(lending.getTotalDebt(alice), 3_500 * USDC + previousInterest);
    }

    // 9. Los intereses tambien cuentan para el riesgo.
    function testInterestReducesCollateralWithdrawalCapacity() public {
        assertTrue(lending.canWithdraw(alice, 0));

        vm.warp(start + 30 days);
        feed.setData(3000e8, block.timestamp);

        // Ya supera el LTV del 50% por los intereses.
        assertFalse(lending.canWithdraw(alice, 0));

        vm.prank(alice);
        vm.expectRevert(CollateralVault.UnsafeWithdrawal.selector);
        vault.withdrawCollateral(1);
    }

    // 10. Una transferencia fallida conserva toda la deuda.
    function testRepaymentWithoutAllowancePreservesDebt() public {
        vm.warp(start + 30 days);

        uint256 totalBefore = lending.getTotalDebt(alice);

        vm.prank(alice);
        usdc.approve(address(pool), 0);

        vm.prank(alice);
        vm.expectRevert();
        lending.repay(10 * USDC);

        assertEq(lending.getTotalDebt(alice), totalBefore);
        assertEq(lending.debt(alice), 3_000 * USDC);
        assertEq(pool.totalInterestCollected(), 0);
    }

    // 11. Fuzz: el interes aumenta con el tiempo.
    function testFuzzInterestIncreasesWithTime(uint256 rawDays) public {
        uint256 elapsedDays = bound(rawDays, 1, 365);

        vm.warp(start + elapsedDays * 1 days);

        uint256 actual = lending.getAccruedInterest(alice);

        assertEq(actual, _expectedInterest(3_000 * USDC, elapsedDays * 1 days));

        assertLe(actual, 300 * USDC);
    }
}
