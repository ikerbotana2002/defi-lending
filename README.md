
# DeFi Lending Protocol

An educational DeFi lending protocol built with
Solidity, Foundry, OpenZeppelin and price oracles.

> Work in progress. Not audited or production-ready.

## Project Goal

Build an overcollateralized lending protocol where:

- Liquidity providers deposit ERC-20 assets
- Borrowers deposit collateral
- Borrowers can take and repay loans
- Debt accumulates interest
- Oracle prices determine collateral valuation
- Unsafe positions can be liquidated

## Day 49 - Liquidity Pool

The first component is a basic ERC-20 liquidity pool.

Implemented:
- Deposits
- Partial and full withdrawals
- Individual deposit accounting
- Total deposit accounting
- Available token balance reporting
- SafeERC20 transfers
- Reentrancy protection
- Unit and fuzz tests

## Contracts

- `src/MockUSDC.sol`: Educational ERC-20 with 6 decimals
- `src/LiquidityPool.sol`: Liquidity deposits and withdrawals

## Tests

```bash
forge build
forge test -vv
forge fmt --check
```

## Development Roadmap

- Day 49: Liquidity pool
- Day 50: Collateral management
- Day 51: Borrowing and oracle integration
- Day 52: Repayments and debt accounting
- Day 53: Interest accrual
- Day 54: Health factor and liquidation
- Day 55: Security, fuzz and invariants
- Day 56: Integration and documentation

## Current Limitations

- No borrowing or interest accrual yet
- No collateral custody yet
- Deposit accounting is currently 1:1
- No liquidity-provider share token
- No handling of rebasing tokens
- Direct token transfers are not credited as deposits
- No independent audit

Do not use with real funds.
