use starknet::ContractAddress;
use vesu_v2_periphery::swap::Swap;

#[derive(Serde, Drop, Clone)]
pub struct LiquidateParams {
    pub pool: ContractAddress,
    pub collateral_asset: ContractAddress,
    pub debt_asset: ContractAddress,
    pub user: ContractAddress,
    pub recipient: ContractAddress,
    pub min_collateral_to_receive: u256,
    pub debt_to_repay: u256,
    pub liquidate_swap: Array<Swap>,
    pub liquidate_swap_limit_amount: u128,
    pub liquidate_swap_weights: Array<u128>,
    pub withdraw_swap: Array<Swap>,
    pub withdraw_swap_limit_amount: u128,
    pub withdraw_swap_weights: Array<u128>,
}

#[derive(Serde, Copy, Drop)]
pub struct LiquidateResponse {
    pub liquidated_collateral: u256,
    pub repaid_debt: u256,
    pub residual_collateral: u256,
    pub residual_token: ContractAddress,
}

#[starknet::interface]
pub trait ILiquidate<TContractState> {
    fn liquidate(ref self: TContractState, params: LiquidateParams) -> LiquidateResponse;
}

#[starknet::contract]
pub mod Liquidate {
    use alexandria_math::i257::I257Trait;
    use ekubo::components::shared_locker::{call_core_with_callback, consume_callback_data, handle_delta};
    use ekubo::interfaces::core::{ICoreDispatcher, ILocker};
    use ekubo::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use ekubo::types::i129::i129;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::{ContractAddress, get_contract_address};
    use vesu::data_model::{LiquidatePositionParams, UpdatePositionResponse};
    use vesu::pool::{IPoolDispatcher, IPoolDispatcherTrait};
    use vesu_v2_periphery::liquidate::{ILiquidate, LiquidateParams, LiquidateResponse};
    use vesu_v2_periphery::swap::{apply_weights, assert_empty_token_amounts, assert_matching_token_amounts, swap};

    #[storage]
    struct Storage {
        core: ICoreDispatcher,
    }

    #[derive(Drop, starknet::Event)]
    struct LiquidatePosition {
        #[key]
        pool: ContractAddress,
        #[key]
        collateral_asset: ContractAddress,
        #[key]
        debt_asset: ContractAddress,
        #[key]
        user: ContractAddress,
        residual: u256,
        collateral_delta: u256,
        debt_delta: u256,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        LiquidatePosition: LiquidatePosition,
    }

    #[constructor]
    fn constructor(ref self: ContractState, core: ICoreDispatcher) {
        self.core.write(core);
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn liquidate_position(ref self: ContractState, liquidate_params: LiquidateParams) -> LiquidateResponse {
            let LiquidateParams {
                pool,
                collateral_asset,
                debt_asset,
                user,
                recipient,
                min_collateral_to_receive,
                mut debt_to_repay,
                mut liquidate_swap,
                liquidate_swap_limit_amount,
                liquidate_swap_weights,
                mut withdraw_swap,
                withdraw_swap_limit_amount,
                withdraw_swap_weights,
            } = liquidate_params;

            let core = self.core.read();
            let pool = IPoolDispatcher { contract_address: pool };
            let (_, _, debt) = pool.position(collateral_asset, debt_asset, user);

            // if debt_to_repay is 0 or greater than the debt, repay the full debt
            if debt_to_repay == 0 || debt_to_repay > debt {
                debt_to_repay = debt;
            }

            // flash loan asset to repay the position's debt
            handle_delta(
                core, debt_asset, i129 { mag: debt_to_repay.try_into().unwrap(), sign: true }, get_contract_address(),
            );

            assert!(
                IERC20Dispatcher { contract_address: debt_asset }.approve(pool.contract_address, debt),
                "approve-failed",
            );

            let UpdatePositionResponse {
                collateral_delta, debt_delta, bad_debt, ..,
            } =
                pool
                    .liquidate_position(
                        LiquidatePositionParams {
                            collateral_asset, debt_asset, user, min_collateral_to_receive, debt_to_repay,
                        },
                    );

            let debt_paid = debt_delta.abs() - bad_debt;

            // - swap collateral asset to debt asset (1.)
            // for repaying an exact amount of debt:
            //   - input token: debt asset and output token: collateral asset, since we specify a negative input amount
            //     of the debt asset (swap direction is reversed)
            assert_matching_token_amounts(liquidate_swap.clone());
            assert_empty_token_amounts(liquidate_swap.clone());
            // apply weights to lever_swap token amounts
            liquidate_swap =
                apply_weights( // debt_paid.try_into().unwrap()
                    liquidate_swap, liquidate_swap_weights, i129 { mag: debt_paid.try_into().unwrap(), sign: true },
                );

            let (collateral_amount, debt_amount) = swap(core, liquidate_swap.clone(), liquidate_swap_limit_amount);
            assert!(collateral_amount.token == collateral_asset, "invalid-liquidate-swap-assets");

            // - handleDelta: settle the remaining debt asset flash loan (1.)
            handle_delta(
                core,
                debt_amount.token,
                i129 { mag: (debt_to_repay - debt_paid).try_into().unwrap(), sign: false },
                get_contract_address(),
            );

            // - handleDelta: settle collateral asset swap (1.)
            handle_delta(
                core,
                collateral_amount.token,
                i129 { mag: collateral_amount.amount.mag, sign: false },
                get_contract_address(),
            );

            let residual_collateral = collateral_delta.abs().try_into().unwrap() - collateral_amount.amount.mag;

            self
                .emit(
                    LiquidatePosition {
                        pool: pool.contract_address,
                        collateral_asset,
                        debt_asset,
                        user,
                        residual: residual_collateral.into(),
                        collateral_delta: collateral_delta.abs(),
                        debt_delta: debt_delta.abs().try_into().unwrap(),
                    },
                );

            // avoid withdraw_swap moving error by returning early here
            if withdraw_swap.len() == 0 {
                assert!(
                    IERC20Dispatcher { contract_address: collateral_asset }
                        .transfer(recipient, residual_collateral.into()),
                    "transfer-failed",
                );
                return LiquidateResponse {
                    liquidated_collateral: collateral_delta.abs(),
                    repaid_debt: debt_delta.abs(),
                    residual_collateral: residual_collateral.into(),
                    residual_token: collateral_asset,
                };
            }

            // - swap residual / margin collateral amount to arbitrary asset and handle delta
            assert_matching_token_amounts(withdraw_swap.clone());
            assert_empty_token_amounts(withdraw_swap.clone());
            // apply weights to withdraw_swap token amounts
            withdraw_swap =
                apply_weights(withdraw_swap, withdraw_swap_weights, residual_collateral.try_into().unwrap());

            // collateral_asset to arbitrary_asset
            // token_amount is always positive, limit_amount is min. amount out:
            let (collateral_margin_amount, out_amount) = swap(core, withdraw_swap.clone(), withdraw_swap_limit_amount);

            handle_delta(
                core,
                collateral_margin_amount.token,
                i129 { mag: collateral_margin_amount.amount.mag, sign: false },
                get_contract_address(),
            );
            handle_delta(core, out_amount.token, i129 { mag: out_amount.amount.mag, sign: true }, recipient);

            return LiquidateResponse {
                liquidated_collateral: collateral_delta.abs(),
                repaid_debt: debt_delta.abs(),
                residual_collateral: out_amount.amount.mag.into(),
                residual_token: out_amount.token,
            };
        }
    }

    #[abi(embed_v0)]
    impl LockerImpl of ILocker<ContractState> {
        fn locked(ref self: ContractState, id: u32, mut data: Span<felt252>) -> Span<felt252> {
            let core = self.core.read();

            // asserts that caller is core
            let liquidate_params: LiquidateParams = consume_callback_data(core, data);
            let liquidate_response = self.liquidate_position(liquidate_params);

            let mut data: Array<felt252> = array![];
            Serde::serialize(@liquidate_response, ref data);
            data.span()
        }
    }

    #[abi(embed_v0)]
    impl LiquidateImpl of ILiquidate<ContractState> {
        fn liquidate(ref self: ContractState, params: LiquidateParams) -> LiquidateResponse {
            call_core_with_callback(self.core.read(), @params)
        }
    }
}
