// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {LiquidityPool} from "./LiquidityPool.sol";
import {CollateralVault} from "./CollateralVault.sol";
import {ICollateralController} from "./interfaces/ICollateralController.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

contract LendingProtocol is ICollateralController, ReentrancyGuard {
    uint256 public constant WAD = 1e18;
    uint256 public constant USDC_SCALE = 1e12;
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_LTV_BPS = 5_000;

    // Interes simple anual del 10%.
    uint256 public constant BORROW_APR_BPS = 1_000;
    uint256 public constant YEAR = 365 days;

    // Umbral de liquidacion: 60%.
    uint256 public constant LIQUIDATION_THRESHOLD_BPS = 6_000;

    // Bonificacion del liquidador: 5%.
    uint256 public constant LIQUIDATION_BONUS_BPS = 500;

    // Maximo de deuda liquidable por operacion: 50%.
    uint256 public constant CLOSE_FACTOR_BPS = 5_000;

    LiquidityPool public immutable pool;
    CollateralVault public immutable vault;
    IPriceOracle public immutable oracle;

    // Principal pendiente, en unidades de USDC.
    mapping(address => uint256) public debt;

    // Interes contabilizado pero aun no pagado.
    mapping(address => uint256) public storedInterest;

    // Ultima actualizacion de intereses por usuario.
    mapping(address => uint256) public lastAccrualTimestamp;

    error InvalidDependency();
    error UnsupportedDecimals();
    error ControllersNotConfigured();
    error ZeroAmount();
    error InsufficientCollateral();
    error NoDebt();
    error RepaymentExceedsDebt();

    error PositionHealthy();
    error InvalidLiquidationAmount();
    error InsufficientSeizableCollateral();
    error InvalidBorrower();

    event Liquidated(
        address indexed borrower, address indexed liquidator, uint256 debtRepaid, uint256 collateralSeized
    );

    event Borrowed(address indexed borrower, uint256 amount);

    event InterestAccrued(address indexed borrower, uint256 amount);

    event Repaid(address indexed borrower, uint256 amount, uint256 remainingDebt);

    event RepaymentAllocated(address indexed borrower, uint256 principalPaid, uint256 interestPaid);

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

        if (
            IERC20Metadata(address(pool.asset())).decimals() != 6
                || IERC20Metadata(address(vault.collateralToken())).decimals() != 18
        ) {
            revert UnsupportedDecimals();
        }
    }

    // --------------------------------------------------
    // 1. CALCULAR INTERESES NUEVOS
    // --------------------------------------------------

    function getNewInterest(address user) public view returns (uint256) {
        uint256 principal = debt[user];
        uint256 lastUpdate = lastAccrualTimestamp[user];

        if (principal == 0 || lastUpdate == 0) {
            return 0;
        }

        uint256 elapsed = block.timestamp - lastUpdate;

        return Math.mulDiv(principal, BORROW_APR_BPS * elapsed, BPS * YEAR);
    }

    // Intereses pendientes, incluidos los generados
    // desde la ultima actualizacion.
    function getAccruedInterest(address user) public view returns (uint256) {
        return storedInterest[user] + getNewInterest(user);
    }

    // Principal + intereses acumulados.
    function getTotalDebt(address user) public view returns (uint256) {
        return debt[user] + getAccruedInterest(user);
    }

    // Guardar los intereses que se han generado.
    function _accrue(address user) internal {
        uint256 newInterest = getNewInterest(user);

        if (newInterest > 0) {
            storedInterest[user] += newInterest;
            emit InterestAccrued(user, newInterest);
        }

        lastAccrualTimestamp[user] = block.timestamp;
    }

    // --------------------------------------------------
    // 2. VALORAR GARANTIAS
    // --------------------------------------------------

    function getCollateralValueUsd18(address user) public view returns (uint256) {
        uint256 collateral = vault.collateralBalances(user);

        uint256 price18 = oracle.getPrice18();

        return Math.mulDiv(collateral, price18, WAD);
    }

    function getMaxDebt(address user) public view returns (uint256) {
        uint256 valueUsd18 = getCollateralValueUsd18(user);

        return Math.mulDiv(valueUsd18, MAX_LTV_BPS, BPS * USDC_SCALE);
    }

    // --------------------------------------------------
    // 3. SOLICITAR UN PRESTAMO
    // --------------------------------------------------

    function borrow(uint256 amount) external nonReentrant {
        if (amount == 0) {
            revert ZeroAmount();
        }

        if (pool.lendingController() != address(this) || address(vault.riskController()) != address(this)) {
            revert ControllersNotConfigured();
        }

        // Contabilizar los intereses anteriores
        // antes de incorporar nuevo principal.
        _accrue(msg.sender);

        uint256 newPrincipal = debt[msg.sender] + amount;

        uint256 newTotalDebt = newPrincipal + storedInterest[msg.sender];

        if (newTotalDebt > getMaxDebt(msg.sender)) {
            revert InsufficientCollateral();
        }

        debt[msg.sender] = newPrincipal;

        pool.lendTo(msg.sender, amount);

        emit Borrowed(msg.sender, amount);
    }

    // --------------------------------------------------
    // 4. DEVOLVER CAPITAL E INTERESES
    // --------------------------------------------------

    function repay(uint256 amount) external nonReentrant {
        if (amount == 0) {
            revert ZeroAmount();
        }

        _accrue(msg.sender);

        uint256 principal = debt[msg.sender];
        uint256 interest = storedInterest[msg.sender];
        uint256 totalOwed = principal + interest;

        if (totalOwed == 0) {
            revert NoDebt();
        }

        if (amount > totalOwed) {
            revert RepaymentExceedsDebt();
        }

        // Primero se pagan los intereses.
        uint256 interestPaid = Math.min(amount, interest);

        // Lo restante reduce el principal.
        uint256 principalPaid = amount - interestPaid;

        storedInterest[msg.sender] = interest - interestPaid;
        debt[msg.sender] = principal - principalPaid;

        // Ambas operaciones son atomicas.
        if (interestPaid > 0) {
            pool.collectInterestFrom(msg.sender, interestPaid);
        }

        if (principalPaid > 0) {
            pool.repayFrom(msg.sender, principalPaid);
        }

        emit Repaid(msg.sender, amount, debt[msg.sender] + storedInterest[msg.sender]);

        emit RepaymentAllocated(msg.sender, principalPaid, interestPaid);
    }

    // --------------------------------------------------
    // 5. CONTROLAR RETIRADAS DE GARANTIA
    // --------------------------------------------------

    function canWithdraw(address user, uint256 amount) external view returns (bool) {
        uint256 collateral = vault.collateralBalances(user);

        if (amount > collateral) {
            return false;
        }

        if (getTotalDebt(user) == 0) {
            return true;
        }

        uint256 remaining = collateral - amount;

        uint256 price18 = oracle.getPrice18();

        uint256 remainingValueUsd18 = Math.mulDiv(remaining, price18, WAD);

        uint256 maxDebtAfterWithdrawal = Math.mulDiv(remainingValueUsd18, MAX_LTV_BPS, BPS * USDC_SCALE);

        return getTotalDebt(user) <= maxDebtAfterWithdrawal;
    }

    // Cuanta deuda puede soportar la garantia antes
    // de entrar en zona liquidable.
    function getLiquidationThresholdDebt(address user) public view returns (uint256) {
        uint256 valueUsd18 = getCollateralValueUsd18(user);

        return Math.mulDiv(valueUsd18, LIQUIDATION_THRESHOLD_BPS, BPS * USDC_SCALE);
    }

    // Health Factor normalizado a 18 decimales.
    // 1e18 representa HF = 1.
    function getHealthFactor(address user) public view returns (uint256) {
        uint256 totalOwed = getTotalDebt(user);

        // Sin deuda, no existe riesgo de liquidacion.
        if (totalOwed == 0) {
            return type(uint256).max;
        }

        uint256 thresholdDebt = getLiquidationThresholdDebt(user);

        return Math.mulDiv(thresholdDebt, WAD, totalOwed);
    }

    // Una posicion es liquidable cuando HF < 1.
    function isLiquidatable(address user) public view returns (bool) {
        return getHealthFactor(user) < WAD;
    }

    // Convierte los USDC devueltos a WETH,
    // incluyendo la bonificacion del 5%.
    function getCollateralToSeize(uint256 repayAmount) public view returns (uint256) {
        if (repayAmount == 0) {
            revert ZeroAmount();
        }

        // Precio ETH/USD a 18 decimales.
        uint256 price18 = oracle.getPrice18();

        // 1e30 = 1e12 para pasar USDC a USD18,
        // multiplicado por 1e18 para obtener WETH wei.
        uint256 baseCollateralWei = Math.mulDiv(repayAmount, 1e30, price18);

        return Math.mulDiv(baseCollateralWei, BPS + LIQUIDATION_BONUS_BPS, BPS);
    }

    function liquidate(address borrower, uint256 repayAmount) external nonReentrant {
        if (borrower == address(0) || borrower == msg.sender) {
            revert InvalidBorrower();
        }

        if (repayAmount == 0) {
            revert ZeroAmount();
        }

        // 1. Comprobar que la posicion es liquidable.
        if (!isLiquidatable(borrower)) {
            revert PositionHealthy();
        }

        // 2. Actualizar los intereses pendientes.
        _accrue(borrower);

        uint256 principal = debt[borrower];
        uint256 interest = storedInterest[borrower];
        uint256 totalOwed = principal + interest;

        // 3. Maximo 50% de la deuda en esta operacion.
        uint256 maxRepayment = Math.mulDiv(totalOwed, CLOSE_FACTOR_BPS, BPS, Math.Rounding.Ceil);

        if (repayAmount > maxRepayment) {
            revert InvalidLiquidationAmount();
        }

        // 4. Calcular los WETH que recibira el liquidador.
        uint256 collateralAmount = getCollateralToSeize(repayAmount);

        if (collateralAmount == 0 || collateralAmount > vault.collateralBalances(borrower)) {
            revert InsufficientSeizableCollateral();
        }

        // 5. Primero se pagan los intereses.
        uint256 interestPaid = Math.min(repayAmount, interest);

        uint256 principalPaid = repayAmount - interestPaid;

        storedInterest[borrower] = interest - interestPaid;

        debt[borrower] = principal - principalPaid;

        // 6. El pool recibe USDC del LIQUIDADOR,
        // no del prestatario.
        if (interestPaid > 0) {
            pool.collectInterestFrom(msg.sender, interestPaid);
        }

        if (principalPaid > 0) {
            pool.repayFrom(msg.sender, principalPaid);
        }

        // 7. El Vault entrega WETH al liquidador.
        vault.seizeCollateral(borrower, msg.sender, collateralAmount);

        emit Liquidated(borrower, msg.sender, repayAmount, collateralAmount);
    }
}
