// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {LiquidityPool} from "./LiquidityPool.sol";
import {CollateralVault} from "./CollateralVault.sol";
import {ICollateralController} from "./interfaces/ICollateralController.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract LendingProtocol is ICollateralController, ReentrancyGuard {
    uint256 public constant WAD = 1e18;
    uint256 public constant USDC_SCALE = 1e12;
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_LTV_BPS = 5_000;

    LiquidityPool public immutable pool;
    CollateralVault public immutable vault;
    IPriceOracle public immutable oracle;

    // Deuda expresada en unidades minimas de USDC.
    mapping(address => uint256) public debt;

    error InvalidDependency();
    error UnsupportedDecimals();
    error ControllersNotConfigured();
    error ZeroAmount();
    error InsufficientCollateral();

    error NoDebt();
    error RepaymentExceedsDebt();

    event Repaid(address indexed borrower, uint256 amount, uint256 remainingDebt);

    event Borrowed(address indexed borrower, uint256 amount);

    constructor(address pool_, address vault_, address oracle_) {
        if (
            pool_ == address(0) || vault_ == address(0) || oracle_ == address(0) || pool_.code.length == 0
                || vault_.code.length == 0 || oracle_.code.length == 0
        ) {
            revert InvalidDependency();
        }

        pool = LiquidityPool(pool_);
        vault = CollateralVault(vault_);
        oracle = IPriceOracle(oracle_);

        // Este ejercicio admite USDC de 6 decimales
        // y WETH de 18 decimales.
        if (
            IERC20Metadata(address(pool.asset())).decimals() != 6
                || IERC20Metadata(address(vault.collateralToken())).decimals() != 18
        ) {
            revert UnsupportedDecimals();
        }
    }

    // USD normalizados a 18 decimales.
    function getCollateralValueUsd18(address user) public view returns (uint256) {
        uint256 collateral = vault.collateralBalances(user);

        uint256 price18 = oracle.getPrice18();

        return Math.mulDiv(collateral, price18, WAD);
    }

    // Prestamo maximo en unidades de USDC (6 decimales).
    function getMaxDebt(address user) public view returns (uint256) {
        uint256 valueUsd18 = getCollateralValueUsd18(user);

        return Math.mulDiv(valueUsd18, MAX_LTV_BPS, BPS * USDC_SCALE);
    }

    function borrow(uint256 amount) external nonReentrant {
        if (amount == 0) {
            revert ZeroAmount();
        }

        // No se pueden prestar fondos hasta que
        // los dos controladores esten configurados.
        if (pool.lendingController() != address(this) || address(vault.riskController()) != address(this)) {
            revert ControllersNotConfigured();
        }

        uint256 newDebt = debt[msg.sender] + amount;

        if (newDebt > getMaxDebt(msg.sender)) {
            revert InsufficientCollateral();
        }

        // Registrar antes de transferir los USDC.
        debt[msg.sender] = newDebt;

        // Solo este contrato esta autorizado
        // para ordenar la transferencia.
        pool.lendTo(msg.sender, amount);

        emit Borrowed(msg.sender, amount);
    }

    // Devolver parte o la totalidad de un prestamo.
    function repay(uint256 amount) external nonReentrant {
        if (amount == 0) {
            revert ZeroAmount();
        }

        uint256 currentDebt = debt[msg.sender];

        if (currentDebt == 0) {
            revert NoDebt();
        }

        if (amount > currentDebt) {
            revert RepaymentExceedsDebt();
        }

        uint256 remainingDebt = currentDebt - amount;

        // Actualizamos la deuda individual.
        debt[msg.sender] = remainingDebt;

        // El pool recibe los USDC y reduce
        // su contabilidad global de prestamos.
        pool.repayFrom(msg.sender, amount);

        emit Repaid(msg.sender, amount, remainingDebt);
    }

    // El CollateralVault consulta esta funcion
    // antes de permitir una retirada.
    function canWithdraw(address user, uint256 amount) external view returns (bool) {
        uint256 collateral = vault.collateralBalances(user);

        if (amount > collateral) {
            return false;
        }

        // Sin deuda puede retirar su garantia.
        if (debt[user] == 0) {
            return true;
        }

        uint256 remaining = collateral - amount;

        uint256 price18 = oracle.getPrice18();

        uint256 remainingValueUsd18 = Math.mulDiv(remaining, price18, WAD);

        uint256 maxDebtAfterWithdrawal = Math.mulDiv(remainingValueUsd18, MAX_LTV_BPS, BPS * USDC_SCALE);

        return debt[user] <= maxDebtAfterWithdrawal;
    }
}
