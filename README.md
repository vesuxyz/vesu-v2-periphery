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