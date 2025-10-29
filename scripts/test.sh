#!/bin/bash

set -o allexport
source .env
set +o allexport

# run tests at block 2386336
sed -e "s~MAINNET_RPC_URL~$MAINNET_RPC_URL~g" \
    -e "s~BLOCK_NUMBER~2386336~g" \
    Scarb.toml.template > Scarb.toml

snforge test "Test_2386336"

# run tests at block 3251219
sed -e "s~MAINNET_RPC_URL~$MAINNET_RPC_URL~g" \
    -e "s~BLOCK_NUMBER~3251219~g" \
    Scarb.toml.template > Scarb.toml

snforge test "Test_3251219"
