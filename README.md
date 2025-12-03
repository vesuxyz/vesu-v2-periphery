# VESU Periphery Contracts

This repository contains the periphery contracts for VESU V1. This includes [Liquidate](./src/liquidate.cairo), [Multiply](./src/multiply.cairo), [Rebalance](./src/rebalance.cairo).

## Setup

### Requirements

This project uses Starknet Foundry for testing. To install Starknet Foundry follow [these instructions](https://foundry-rs.github.io/starknet-foundry/getting-started/installation.html).

### Install

We advise that you use [nvm](https://github.com/nvm-sh/nvm) to manage your Node versions.

```sh
yarn
```

### Test

```sh
scarb run test
```

## Deployment

### Prerequisite

Copy and update the contents of `.env.example` to `.env`.

### Declare and deploy contracts

Declare and deploy all contracts under `src` using the account with `PRIVATE_KEY` and `ADDRESS` specified in `.env`

```sh
scarb run deployLiquidate
scarb run deployMultiply
scarb run deployRebalance
```

## Documentation

### Migrate

Migrate.cairo allows existing users to migrate their positions from Vesu-V1 to Vesu-V2 and between Vesu-V2 pools. It automatically upgrades any legacy tokens (such as USDC.e) to their new contract. Under the hood it makes use of flash loans to facilitate migration of outstanding debt without requiring the user to repay their debt temporarily. In order to facilitate safe migrations, avoiding that the newly created positions become liquidatable right after the migration because of differences in oracle price or interest rates between pools and pairs, the user has to specify an additional ltv tolerance (`max_ltv_delta`) between the old and the new position.

### Multiply

Multiply.cairo enables users to increase or decrease their leverage on existing positions in Vesu-V2. It supports both increasing leverage (by depositing additional margin and borrowing more debt) and decreasing leverage (by repaying debt and withdrawing collateral). The contract uses Ekubo's swap interface to convert between assets and handles all operations atomically through flash loan callbacks. Users can customize swap routes for margin conversion, debt swaps, and residual collateral conversion, with optional position closure that automatically repays all outstanding debt.

### Liquidate

Liquidate.cairo enables liquidators to liquidate undercollateralized positions in Vesu-V2 pools. It uses flash loans to cover the debt repayment, then seizes the position's collateral to repay the borrowed amount. The contract integrates with Ekubo's swap interface to exchange seized collateral for the debt asset or convert residual collateral to alternative assets. Liquidators can customize swap routes for debt repayment and residual collateral conversion, with flexible parameters for controlling the amount of debt to repay and minimum collateral requirements.
