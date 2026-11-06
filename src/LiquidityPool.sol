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

    address public immutable owner;
    address public lendingController;

    uint256 public totalBorrowed;

    error Unauthorized();
    error InvalidController();
    error ControllerAlreadySet();
    error InsufficientLiquidity();

    event LendingControllerSet(address indexed controller);

    event LoanDisbursed(address indexed borrower, uint256 amount);

    event LoanRepaid(address indexed payer, uint256 amount);

    constructor(address asset_) {
        if (asset_ == address(0) || asset_.code.length == 0) {
            revert InvalidAsset();
        }

        asset = IERC20(asset_);

        owner = msg.sender; // Añade esta línea si falta
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

    // El deployer autoriza un unico contrato de Lending.
    function setLendingController(address controller_) external {
        if (msg.sender != owner) {
            revert Unauthorized();
        }

        if (lendingController != address(0)) {
            revert ControllerAlreadySet();
        }

        if (controller_ == address(0) || controller_.code.length == 0) {
            revert InvalidController();
        }

        lendingController = controller_;

        emit LendingControllerSet(controller_);
    }

    // Solo LendingProtocol puede ordenar prestamos.
    function lendTo(address borrower, uint256 amount) external nonReentrant {
        if (msg.sender != lendingController) {
            revert Unauthorized();
        }

        if (amount == 0) {
            revert ZeroAmount();
        }

        if (borrower == address(0)) {
            revert InvalidController();
        }

        uint256 beforeBalance = asset.balanceOf(address(this));

        if (beforeBalance < amount) {
            revert InsufficientLiquidity();
        }

        totalBorrowed += amount;

        asset.safeTransfer(borrower, amount);

        uint256 afterBalance = asset.balanceOf(address(this));

        if (afterBalance > beforeBalance || beforeBalance - afterBalance != amount) {
            revert UnsupportedToken();
        }

        emit LoanDisbursed(borrower, amount);
    }

    // Recibir USDC para devolver un prestamo.
    // Solo LendingProtocol puede solicitar la operacion.
    function repayFrom(address payer, uint256 amount) external nonReentrant {
        if (msg.sender != lendingController) {
            revert Unauthorized();
        }

        if (amount == 0) {
            revert ZeroAmount();
        }

        if (amount > totalBorrowed) {
            revert InsufficientDeposit();
        }

        // Reducimos el principal pendiente.
        totalBorrowed -= amount;

        uint256 balanceBefore = asset.balanceOf(address(this));

        // El pool recoge los USDC del prestatario.
        asset.safeTransferFrom(payer, address(this), amount);

        uint256 balanceAfter = asset.balanceOf(address(this));

        // Deben haberse recibido exactamente los USDC.
        if (balanceAfter < balanceBefore || balanceAfter - balanceBefore != amount) {
            revert UnsupportedToken();
        }

        emit LoanRepaid(payer, amount);
    }
}
