// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract LiquidityPool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset;

    mapping(address => uint256) public deposits;
    uint256 public totalDeposits;

    error InvalidAsset();
    error ZeroAmount();
    error InsufficientDeposit();
    error UnsupportedToken();

    event LiquidityDeposited(address indexed user, uint256 amount);

    event LiquidityWithdrawn(address indexed user, uint256 amount);

    constructor(address asset_) {
        if (asset_ == address(0) || asset_.code.length == 0) {
            revert InvalidAsset();
        }

        asset = IERC20(asset_);
    }

    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) {
            revert ZeroAmount();
        }

        uint256 beforeBalance = asset.balanceOf(address(this));

        asset.safeTransferFrom(msg.sender, address(this), amount);

        uint256 afterBalance = asset.balanceOf(address(this));

        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) {
            revert UnsupportedToken();
        }

        deposits[msg.sender] += amount;
        totalDeposits += amount;

        emit LiquidityDeposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) {
            revert ZeroAmount();
        }

        if (deposits[msg.sender] < amount) {
            revert InsufficientDeposit();
        }

        deposits[msg.sender] -= amount;
        totalDeposits -= amount;

        uint256 beforeBalance = asset.balanceOf(address(this));

        asset.safeTransfer(msg.sender, amount);

        uint256 afterBalance = asset.balanceOf(address(this));

        if (afterBalance > beforeBalance || beforeBalance - afterBalance != amount) {
            revert UnsupportedToken();
        }

        emit LiquidityWithdrawn(msg.sender, amount);
    }

    function availableLiquidity() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }
}
