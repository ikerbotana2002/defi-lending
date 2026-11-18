// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ICollateralController} from "./interfaces/ICollateralController.sol";

contract CollateralVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable collateralToken;
    address public immutable owner;

    ICollateralController public riskController;

    mapping(address => uint256) public collateralBalances;
    uint256 public totalCollateral;

    error InvalidCollateralToken();
    error ZeroAmount();
    error InsufficientCollateral();
    error UnsupportedToken();
    error Unauthorized();
    error InvalidController();
    error ControllerAlreadySet();
    error UnsafeWithdrawal();
    error InvalidRecipient();
    error ControllerNotConfigured();

    event CollateralDeposited(address indexed user, uint256 amount);

    event CollateralWithdrawn(address indexed user, uint256 amount);

    event RiskControllerSet(address indexed controller);

    event CollateralSeized(address indexed borrower, address indexed liquidator, uint256 amount);

    constructor(address token_) {
        if (token_ == address(0) || token_.code.length == 0) {
            revert InvalidCollateralToken();
        }

        collateralToken = IERC20(token_);
        owner = msg.sender;
    }

    // Solo se puede configurar un controlador,
    // una unica vez, por el deployer.
    function setRiskController(address controller_) external {
        if (msg.sender != owner) {
            revert Unauthorized();
        }

        if (address(riskController) != address(0)) {
            revert ControllerAlreadySet();
        }

        if (controller_ == address(0) || controller_.code.length == 0) {
            revert InvalidController();
        }

        riskController = ICollateralController(controller_);

        emit RiskControllerSet(controller_);
    }

    // Depositar WETH como garantia.
    function depositCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) {
            revert ZeroAmount();
        }

        uint256 beforeBalance = collateralToken.balanceOf(address(this));

        collateralToken.safeTransferFrom(msg.sender, address(this), amount);

        uint256 afterBalance = collateralToken.balanceOf(address(this));

        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) {
            revert UnsupportedToken();
        }

        collateralBalances[msg.sender] += amount;
        totalCollateral += amount;

        emit CollateralDeposited(msg.sender, amount);
    }

    // Retirar WETH, siempre que sea seguro.
    function withdrawCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) {
            revert ZeroAmount();
        }

        if (collateralBalances[msg.sender] < amount) {
            revert InsufficientCollateral();
        }

        // Si existe controlador, debe autorizar
        // la retirada segun la deuda del usuario.
        if (address(riskController) != address(0)) {
            if (!riskController.canWithdraw(msg.sender, amount)) {
                revert UnsafeWithdrawal();
            }
        }

        // Checks-Effects-Interactions.
        collateralBalances[msg.sender] -= amount;
        totalCollateral -= amount;

        uint256 beforeBalance = collateralToken.balanceOf(address(this));

        collateralToken.safeTransfer(msg.sender, amount);

        uint256 afterBalance = collateralToken.balanceOf(address(this));

        if (afterBalance > beforeBalance || beforeBalance - afterBalance != amount) {
            revert UnsupportedToken();
        }

        emit CollateralWithdrawn(msg.sender, amount);
    }

    function getCollateralBalance(address user) external view returns (uint256) {
        return collateralBalances[user];
    }

    function seizeCollateral(address borrower, address liquidator, uint256 amount) external nonReentrant {
        // Solo nuestro LendingProtocol puede liquidar.
        if (address(riskController) == address(0) || msg.sender != address(riskController)) {
            revert Unauthorized();
        }

        if (borrower == address(0) || liquidator == address(0)) {
            revert InvalidRecipient();
        }

        if (amount == 0) {
            revert ZeroAmount();
        }

        if (collateralBalances[borrower] < amount) {
            revert InsufficientCollateral();
        }

        // Actualizar la contabilidad antes de transferir.
        collateralBalances[borrower] -= amount;
        totalCollateral -= amount;

        uint256 balanceBefore = collateralToken.balanceOf(address(this));

        collateralToken.safeTransfer(liquidator, amount);

        uint256 balanceAfter = collateralToken.balanceOf(address(this));

        if (balanceAfter > balanceBefore || balanceBefore - balanceAfter != amount) {
            revert UnsupportedToken();
        }

        emit CollateralSeized(borrower, liquidator, amount);
    }
}
