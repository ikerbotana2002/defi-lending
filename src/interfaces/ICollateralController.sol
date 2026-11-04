// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICollateralController {
    function canWithdraw(address user, uint256 amount) external view returns (bool);
}
