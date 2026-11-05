// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPriceOracle {
    function getPrice18() external view returns (uint256);
}
