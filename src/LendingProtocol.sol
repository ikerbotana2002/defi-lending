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
}
