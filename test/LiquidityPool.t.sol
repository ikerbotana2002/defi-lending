// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../src/MockUSDC.sol";
import {LiquidityPool} from "../src/LiquidityPool.sol";

contract LiquidityPoolTest is Test {
    MockUSDC usdc;
    LiquidityPool pool;

    address bob = address(0xB0B);
    address carmen = address(0xCA11);

    uint256 constant USDC = 1e6;

    function setUp() public {
        usdc = new MockUSDC();
        pool = new LiquidityPool(address(usdc));

        usdc.transfer(bob, 10_000 * USDC);
        usdc.transfer(carmen, 10_000 * USDC);

        vm.prank(bob);
        usdc.approve(address(pool), type(uint256).max);

        vm.prank(carmen);
        usdc.approve(address(pool), type(uint256).max);
    }

    function testDeposit() public {
        vm.prank(bob);
        pool.deposit(5_000 * USDC);

        assertEq(pool.deposits(bob), 5_000 * USDC);
        assertEq(pool.totalDeposits(), 5_000 * USDC);
        assertEq(pool.availableLiquidity(), 5_000 * USDC);
    }

    function testTwoDepositors() public {
        vm.prank(bob);
        pool.deposit(5_000 * USDC);

        vm.prank(carmen);
        pool.deposit(3_000 * USDC);

        assertEq(pool.deposits(bob), 5_000 * USDC);
        assertEq(pool.deposits(carmen), 3_000 * USDC);
        assertEq(pool.totalDeposits(), 8_000 * USDC);
        assertEq(pool.availableLiquidity(), 8_000 * USDC);
    }

    function testPartialWithdrawal() public {
        vm.prank(bob);
        pool.deposit(5_000 * USDC);

        vm.prank(bob);
        pool.withdraw(2_000 * USDC);

        assertEq(pool.deposits(bob), 3_000 * USDC);
        assertEq(pool.totalDeposits(), 3_000 * USDC);
        assertEq(usdc.balanceOf(bob), 7_000 * USDC);
    }

    function testFullWithdrawal() public {
        vm.prank(bob);
        pool.deposit(5_000 * USDC);

        vm.prank(bob);
        pool.withdraw(5_000 * USDC);

        assertEq(pool.deposits(bob), 0);
        assertEq(pool.totalDeposits(), 0);
        assertEq(pool.availableLiquidity(), 0);
        assertEq(usdc.balanceOf(bob), 10_000 * USDC);
    }

    function testRevertZeroDeposit() public {
        vm.prank(bob);
        vm.expectRevert(LiquidityPool.ZeroAmount.selector);

        pool.deposit(0);
    }

    function testRevertZeroWithdrawal() public {
        vm.prank(bob);
        vm.expectRevert(LiquidityPool.ZeroAmount.selector);

        pool.withdraw(0);
    }

    function testRevertInsufficientDeposit() public {
        vm.prank(bob);
        pool.deposit(1_000 * USDC);

        vm.prank(bob);
        vm.expectRevert(LiquidityPool.InsufficientDeposit.selector);

        pool.withdraw(2_000 * USDC);
    }

    function testCannotWithdrawOtherUsersFunds() public {
        vm.prank(bob);
        pool.deposit(5_000 * USDC);

        vm.prank(carmen);
        vm.expectRevert(LiquidityPool.InsufficientDeposit.selector);

        pool.withdraw(1_000 * USDC);

        assertEq(pool.deposits(bob), 5_000 * USDC);
    }

    function testRevertInvalidAsset() public {
        vm.expectRevert(LiquidityPool.InvalidAsset.selector);

        new LiquidityPool(address(0));
    }

    function testDepositsRequireApproval() public {
        address alice = address(0xA11CE);

        usdc.transfer(alice, 100 * USDC);

        // Alice no ha aprobado al pool.
        vm.prank(alice);
        vm.expectRevert();

        pool.deposit(100 * USDC);

        assertEq(pool.deposits(alice), 0);
    }

    function testFuzzDepositAndWithdraw(uint256 amount, uint256 withdrawal) public {
        amount = bound(amount, 1, 10_000 * USDC);

        withdrawal = bound(withdrawal, 1, amount);

        vm.prank(bob);
        pool.deposit(amount);

        vm.prank(bob);
        pool.withdraw(withdrawal);

        uint256 remaining = amount - withdrawal;

        assertEq(pool.deposits(bob), remaining);
        assertEq(pool.totalDeposits(), remaining);
        assertEq(pool.availableLiquidity(), remaining);
        assertEq(usdc.balanceOf(bob), 10_000 * USDC - remaining);
    }
}
