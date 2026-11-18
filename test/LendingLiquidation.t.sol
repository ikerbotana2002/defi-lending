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

contract LendingLiquidationTest is Test {
    MockUSDC usdc;
    MockWETH weth;
    LiquidityPool pool;
    CollateralVault vault;
    SecurePriceOracle oracle;
    AdversarialPriceFeed feed;
    LendingProtocol lending;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carlos = address(0xCA7105);

    uint256 constant USDC = 1e6;
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
        usdc.transfer(carlos, 5_000 * USDC);
        weth.transfer(alice, 10 ether);

        vm.prank(bob);
        usdc.approve(address(pool), type(uint256).max);

        vm.prank(carlos);
        usdc.approve(address(pool), type(uint256).max);

        vm.prank(alice);
        weth.approve(address(vault), type(uint256).max);

        vm.prank(bob);
        pool.deposit(5_000 * USDC);

        vm.prank(alice);
        vault.depositCollateral(2 ether);

        vm.prank(alice);
        lending.borrow(3_000 * USDC);
    }

    function _setEthPrice(uint256 priceUsd) internal {
        feed.setData(int256(priceUsd * 1e8), block.timestamp);
    }

    // 1. Una posicion sana tiene HF superior a 1.
    function testHealthyPosition() public view {
        assertEq(lending.getHealthFactor(alice), 1.2 ether);
        assertFalse(lending.isLiquidatable(alice));
    }

    // 2. La caida de ETH vuelve liquidable la posicion.
    function testPriceDropMakesPositionLiquidatable() public {
        _setEthPrice(2000);

        assertEq(lending.getHealthFactor(alice), 0.8 ether);
        assertTrue(lending.isLiquidatable(alice));
    }

    // 3. El limite exacto HF = 1 no permite liquidar.
    function testPositionAtThresholdIsNotLiquidatable() public {
        _setEthPrice(2500);

        assertEq(lending.getHealthFactor(alice), 1 ether);
        assertFalse(lending.isLiquidatable(alice));
    }

    // 4. No se puede liquidar una posicion sana.
    function testRejectsHealthyLiquidation() public {
        vm.prank(carlos);
        vm.expectRevert(LendingProtocol.PositionHealthy.selector);

        lending.liquidate(alice, 1_000 * USDC);
    }

    // 5. Liquidacion real: USDC por WETH.
    function testSuccessfulLiquidation() public {
        _setEthPrice(2000);

        vm.prank(carlos);
        lending.liquidate(alice, 1_000 * USDC);

        assertEq(lending.debt(alice), 2_000 * USDC);
        assertEq(pool.totalBorrowed(), 2_000 * USDC);
        assertEq(pool.availableLiquidity(), 3_000 * USDC);

        assertEq(vault.collateralBalances(alice), 1.475 ether);

        assertEq(weth.balanceOf(carlos), 0.525 ether);
        assertEq(usdc.balanceOf(carlos), 4_000 * USDC);
    }

    // 6. El liquidador recibe el bonus del 5%.
    function testLiquidationBonus() public {
        _setEthPrice(2000);

        assertEq(lending.getCollateralToSeize(1_000 * USDC), 0.525 ether);
    }

    // 7. No se puede superar el close factor.
    function testRejectsLiquidationAboveCloseFactor() public {
        _setEthPrice(2000);

        vm.prank(carlos);
        vm.expectRevert(LendingProtocol.InvalidLiquidationAmount.selector);

        lending.liquidate(alice, 1_501 * USDC);
    }

    // 8. Una posicion puede liquidarse al 50% exacto.
    function testLiquidationAtCloseFactor() public {
        _setEthPrice(2000);

        vm.prank(carlos);
        lending.liquidate(alice, 1_500 * USDC);

        assertEq(lending.debt(alice), 1_500 * USDC);
        assertEq(vault.collateralBalances(alice), 1.2125 ether);
    }

    // 9. Sin autorizacion de USDC no hay liquidacion.
    function testLiquidationRevertsWithoutApproval() public {
        _setEthPrice(2000);

        vm.prank(carlos);
        usdc.approve(address(pool), 0);

        vm.prank(carlos);
        vm.expectRevert();
        lending.liquidate(alice, 1_000 * USDC);

        assertEq(lending.debt(alice), 3_000 * USDC);
        assertEq(vault.collateralBalances(alice), 2 ether);
        assertEq(pool.totalBorrowed(), 3_000 * USDC);
    }

    // 10. Nadie puede llamar directamente al Vault
    // para quedarse con los WETH de otro usuario.
    function testCannotSeizeCollateralDirectly() public {
        vm.prank(carlos);
        vm.expectRevert(CollateralVault.Unauthorized.selector);

        vault.seizeCollateral(alice, carlos, 1 ether);
    }

    // 11. Los intereses se pagan primero.
    function testLiquidationPaysInterestFirst() public {
        vm.warp(start + 30 days);
        _setEthPrice(2000);

        uint256 interest = lending.getAccruedInterest(alice);

        vm.prank(carlos);
        lending.liquidate(alice, 1_000 * USDC);

        assertEq(lending.storedInterest(alice), 0);

        assertEq(pool.totalInterestCollected(), interest);

        assertEq(lending.debt(alice), 2_000 * USDC + interest);

        assertEq(pool.totalBorrowed(), 2_000 * USDC + interest);

        assertEq(weth.balanceOf(carlos), 0.525 ether);
    }

    // 12. Rechaza liquidaciones sin garantia suficiente.
    function testRejectsInsufficientSeizableCollateral() public {
        _setEthPrice(200);

        vm.prank(carlos);
        vm.expectRevert(LendingProtocol.InsufficientSeizableCollateral.selector);

        lending.liquidate(alice, 500 * USDC);
    }

    // 13. Fuzz de liquidaciones validas.
    function testFuzzValidLiquidation(uint256 rawAmount) public {
        _setEthPrice(2000);

        uint256 amount = bound(rawAmount, 1 * USDC, 1_500 * USDC);

        uint256 expectedSeizure = lending.getCollateralToSeize(amount);

        vm.prank(carlos);
        lending.liquidate(alice, amount);

        assertEq(lending.debt(alice), 3_000 * USDC - amount);

        assertEq(pool.totalBorrowed(), 3_000 * USDC - amount);

        assertEq(weth.balanceOf(carlos), expectedSeizure);

        assertEq(vault.collateralBalances(alice), 2 ether - expectedSeizure);
    }
}
