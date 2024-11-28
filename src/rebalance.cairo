use ekubo::types::i129::{i129};
use ekubo::types::keys::{PoolKey};
use starknet::{ContractAddress};
use vesu::common::{i257, i257_new};
use vesu_periphery::swap::{Swap};

#[derive(Serde, Drop, Clone)]
pub struct RebalanceResponse {
    pub collateral_delta: i257,
    pub debt_delta: i257
}

#[derive(Serde, Drop, Clone)]
pub struct RebalanceParams {
    pub pool_id: felt252,
    pub collateral_asset: ContractAddress,
    pub debt_asset: ContractAddress,
    pub user: ContractAddress,
    pub rebalance_swap: Array<Swap>,
    pub rebalance_swap_limit_amount: u128,
    pub fee_recipient: ContractAddress
}

#[starknet::interface]
pub trait IRebalance<TContractState> {
    fn set_owner(ref self: TContractState, owner: ContractAddress);
    fn set_rebalancer(ref self: TContractState, rebalancer: ContractAddress, allowed: bool);
    fn approved_rebalancer(self: @TContractState) -> bool;
    fn fee_rate(self: @TContractState) -> u128;
    fn set_target_ltv_config(
        ref self: TContractState,
        pool_id: felt252,
        collateral_asset: ContractAddress,
        debt_asset: ContractAddress,
        target_ltv: u128,
        target_ltv_tolerance: u128,
        target_ltv_min_delta: u128
    );
    fn delta(
        self: @TContractState,
        pool_id: felt252,
        collateral_asset: ContractAddress,
        debt_asset: ContractAddress,
        user: ContractAddress
    ) -> (u256, i257, i257, i257);
    fn rebalance_position(
        ref self: TContractState, rebalance_params: RebalanceParams
    ) -> RebalanceResponse;
}

#[starknet::contract]
pub mod Rebalance {
    use starknet::{ContractAddress, get_contract_address, get_caller_address};

    use core::num::traits::{Zero};

    use ekubo::{
        components::{shared_locker::{consume_callback_data, handle_delta, call_core_with_callback}},
        interfaces::{
            core::{ICoreDispatcher, ICoreDispatcherTrait, ILocker, SwapParameters},
            erc20::{IERC20Dispatcher, IERC20DispatcherTrait}
        },
        types::{i129::{i129, i129Trait, i129_new}, delta::{Delta}, keys::{PoolKey}}
    };

    use vesu::{
        singleton::{ISingleton, ISingletonDispatcher, ISingletonDispatcherTrait},
        data_model::{
            ModifyPositionParams, Amount, AmountType, AmountDenomination, UpdatePositionResponse,
            AssetConfig
        },
        extension::interface::{IExtensionDispatcher, IExtensionDispatcherTrait},
        common::{i257, i257_new}, units::{SCALE, SCALE_128}
    };

    use vesu_periphery::swap::{Swap, RouteNode, TokenAmount, swap};

    use super::{IRebalance, RebalanceParams, RebalanceResponse};

    #[derive(PartialEq, Copy, Drop, Serde, starknet::Store)]
    struct TargetLTVConfig {
        target_ltv: u128,
        target_ltv_tolerance: u128,
        target_ltv_min_delta: u128
    }

    #[storage]
    struct Storage {
        core: ICoreDispatcher,
        singleton: ISingletonDispatcher,
        owner: ContractAddress,
        rebalancers: LegacyMap::<ContractAddress, bool>,
        fee_rate: u128,
        // (pool_id, collateral_asset, debt_asset, user) -> target_ltv_config
        target_ltv_config: LegacyMap::<
            (felt252, ContractAddress, ContractAddress, ContractAddress), TargetLTVConfig
        >,
    }

    #[derive(Drop, starknet::Event)]
    struct SetOwner {
        #[key]
        new_owner: ContractAddress,
        #[key]
        prev_owner: ContractAddress
    }

    #[derive(Drop, starknet::Event)]
    struct SetRebalancer {
        #[key]
        rebalancer: ContractAddress,
        allowed: bool
    }

    #[derive(Drop, starknet::Event)]
    struct SetTargetLTVConfig {
        #[key]
        pool_id: felt252,
        #[key]
        collateral_asset: ContractAddress,
        #[key]
        debt_asset: ContractAddress,
        target_ltv: u128,
        target_ltv_tolerance: u128,
        target_ltv_min_delta: u128
    }

    #[derive(Drop, starknet::Event)]
    struct Rebalance {
        #[key]
        pool_id: felt252,
        #[key]
        collateral_asset: ContractAddress,
        #[key]
        debt_asset: ContractAddress,
        #[key]
        user: ContractAddress,
        margin: u256,
        collateral_delta: u256,
        debt_delta: u256
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        SetOwner: SetOwner,
        SetRebalancer: SetRebalancer,
        SetTargetLTVConfig: SetTargetLTVConfig,
        Rebalance: Rebalance,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        core: ICoreDispatcher,
        singleton: ISingletonDispatcher,
        owner: ContractAddress,
        fee_rate: u128
    ) {
        self.core.write(core);
        self.singleton.write(singleton);
        self.fee_rate.write(fee_rate);

        self.owner.write(owner);
        self.emit(SetOwner { new_owner: owner, prev_owner: Zero::zero() });
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn rebalance(
            ref self: ContractState, rebalance_params: RebalanceParams
        ) -> RebalanceResponse {
            let RebalanceParams { pool_id, collateral_asset, debt_asset, user, .., } =
                rebalance_params
                .clone();

            let TargetLTVConfig { target_ltv, target_ltv_tolerance, target_ltv_min_delta } = self
                .target_ltv_config
                .read((pool_id, collateral_asset, debt_asset, user));

            let (current_ltv, delta_usd, _, _) = self
                .delta(pool_id, collateral_asset, debt_asset, user);
            assert!(delta_usd.abs != 0, "zero-delta");

            let ltv_delta = if target_ltv.into() > current_ltv {
                target_ltv.into() - current_ltv
            } else {
                current_ltv - target_ltv.into()
            };
            assert!(ltv_delta >= target_ltv_min_delta.into(), "target-ltv-min-delta");

            let (collateral_delta, debt_delta) = if !delta_usd.is_negative {
                self.increase_lever(rebalance_params)
            } else {
                self.decrease_lever(rebalance_params)
            };

            let (current_ltv, _, _, _) = self.delta(pool_id, collateral_asset, debt_asset, user);

            assert!(
                (target_ltv < target_ltv_tolerance
                    || (target_ltv - target_ltv_tolerance).into() <= current_ltv)
                    && current_ltv <= (target_ltv + target_ltv_tolerance).into(),
                "target-ltv-tolerance"
            );

            RebalanceResponse { collateral_delta, debt_delta }
        }

        fn increase_lever(
            ref self: ContractState, rebalance_params: RebalanceParams
        ) -> (i257, i257) {
            let RebalanceParams { pool_id,
            collateral_asset,
            debt_asset,
            user,
            fee_recipient,
            mut rebalance_swap,
            rebalance_swap_limit_amount } =
                rebalance_params;

            let core = self.core.read();

            // - swap debt asset to collateral asset (2.)
            // for borrowing an exact amount of debt
            //   - input token: debt asset and output token: collateral asset, since we specify a positive input amount
            //     of the debt asset
            // for depositing an exact amount of collateral:
            //   - input token: collateral asset and output token: debt asset, since we specify a negative input amount
            //     of the collateral asset (swap direction is reversed)
            assert!(rebalance_swap.len() != 0, "invalid-rebalance-swap");
            let (debt_amount, mut collateral_amount) = swap(
                core, rebalance_swap.clone(), rebalance_swap_limit_amount
            );

            assert!(
                debt_amount.token == debt_asset && collateral_amount.token == collateral_asset,
                "invalid-rebalance-swap-assets"
            );

            // - handleDelta (2.): withdraw collateral asset
            handle_delta(
                core,
                collateral_amount.token,
                i129_new(collateral_amount.amount.mag, true),
                get_contract_address()
            );

            // charge swap fee
            let fee = self.fee_rate.read() * collateral_amount.amount.mag / SCALE_128;
            if fee > 0 {
                assert!(fee_recipient != Zero::zero(), "zero-fee-recipient");
                collateral_amount.amount.mag -= fee;
                assert!(
                    IERC20Dispatcher { contract_address: collateral_asset }
                        .transfer(fee_recipient, fee.into()),
                    "transfer-failed"
                );
            }

            let singleton = self.singleton.read();

            assert!(
                IERC20Dispatcher { contract_address: collateral_asset }
                    .approve(singleton.contract_address, collateral_amount.amount.mag.into()),
                "approve-failed"
            );

            // - deposit collateral asset and draw borrow asset
            let UpdatePositionResponse { collateral_delta, debt_delta, .. } = singleton
                .modify_position(
                    ModifyPositionParams {
                        pool_id,
                        collateral_asset,
                        debt_asset,
                        user,
                        collateral: Amount {
                            amount_type: AmountType::Delta,
                            denomination: AmountDenomination::Assets,
                            value: i257_new(collateral_amount.amount.mag.into(), false)
                        },
                        debt: Amount {
                            amount_type: AmountType::Delta,
                            denomination: AmountDenomination::Assets,
                            value: i257_new(debt_amount.amount.mag.into(), false)
                        },
                        data: ArrayTrait::new().span()
                    }
                );

            // - handleDelta (2.): settle borrow asset
            handle_delta(
                core,
                debt_amount.token,
                i129_new(debt_amount.amount.mag, false),
                get_contract_address()
            );

            (collateral_delta, debt_delta)
        }

        fn decrease_lever(
            ref self: ContractState, rebalance_params: RebalanceParams
        ) -> (i257, i257) {
            let RebalanceParams { pool_id,
            collateral_asset,
            debt_asset,
            user,
            mut rebalance_swap,
            rebalance_swap_limit_amount,
            .. } =
                rebalance_params;

            let core = self.core.read();

            // - swap collateral asset to debt asset (1.)
            // for withdrawing an exact amount of collateral:
            //   - input token: collateral asset and output token: debt asset, since we specify a positive input amount
            //     of the collateral asset
            // for repaying an exact amount of debt:
            //   - input token: debt asset and output token: collateral asset, since we specify a negative input amount
            //     of the debt asset (swap direction is reversed)
            assert!(rebalance_swap.len() != 0, "invalid-rebalance-swap");
            let (collateral_amount, debt_amount) = swap(
                core, rebalance_swap.clone(), rebalance_swap_limit_amount
            );

            assert!(
                collateral_amount.token == collateral_asset && debt_amount.token == debt_asset,
                "invalid-rebalance-swap-assets"
            );

            // - handleDelta: withdraw debt asset (1.)
            handle_delta(
                core,
                debt_amount.token,
                i129_new(debt_amount.amount.mag, true),
                get_contract_address()
            );

            let singleton = self.singleton.read();

            assert!(
                IERC20Dispatcher { contract_address: debt_asset }
                    .approve(singleton.contract_address, debt_amount.amount.mag.into()),
                "approve-failed"
            );

            // - withdraw collateral asset and repay borrow asset
            let UpdatePositionResponse { collateral_delta, debt_delta, .. } = self
                .singleton
                .read()
                .modify_position(
                    ModifyPositionParams {
                        pool_id,
                        collateral_asset,
                        debt_asset,
                        user,
                        collateral: Amount {
                            amount_type: AmountType::Delta,
                            denomination: AmountDenomination::Assets,
                            value: i257_new(collateral_amount.amount.mag.into(), true)
                        },
                        debt: Amount {
                            amount_type: AmountType::Delta,
                            denomination: AmountDenomination::Assets,
                            value: i257_new(debt_amount.amount.mag.into(), true)
                        },
                        data: ArrayTrait::new().span()
                    }
                );

            assert!(collateral_amount.amount.mag.into() == collateral_delta.abs, "excess-collateral-withdrawal");
            assert!(debt_amount.amount.mag.into() == debt_delta.abs, "excess-debt-repayment");

            // - handleDelta: settle collateral asset (1.)
            handle_delta(
                self.core.read(),
                collateral_amount.token,
                i129_new(collateral_amount.amount.mag, false),
                get_contract_address()
            );

            (collateral_delta, debt_delta)
        }
    }

    #[abi(embed_v0)]
    impl LockerImpl of ILocker<ContractState> {
        fn locked(ref self: ContractState, id: u32, mut data: Span<felt252>) -> Span<felt252> {
            let core = self.core.read();

            // asserts that caller is core
            let rebalance_params: RebalanceParams = consume_callback_data(core, data);
            let rebalance_response = self.rebalance(rebalance_params);

            let mut data: Array<felt252> = array![];
            Serde::serialize(@rebalance_response, ref data);
            data.span()
        }
    }

    #[abi(embed_v0)]
    impl RebalanceImpl of IRebalance<ContractState> {
        fn set_owner(ref self: ContractState, owner: ContractAddress) {
            assert!(get_caller_address() == self.owner.read(), "only-owner");
            let prev_owner = self.owner.read();
            self.owner.write(owner);
            self.emit(SetOwner { new_owner: owner, prev_owner });
        }

        fn set_rebalancer(ref self: ContractState, rebalancer: ContractAddress, allowed: bool) {
            assert!(get_caller_address() == self.owner.read(), "only-owner");
            self.rebalancers.write(rebalancer, allowed);
            self.emit(SetRebalancer { rebalancer, allowed });
        }

        fn approved_rebalancer(self: @ContractState) -> bool {
            self.rebalancers.read(get_caller_address())
        }

        fn fee_rate(self: @ContractState) -> u128 {
            self.fee_rate.read()
        }

        fn set_target_ltv_config(
            ref self: ContractState,
            pool_id: felt252,
            collateral_asset: ContractAddress,
            debt_asset: ContractAddress,
            target_ltv: u128,
            target_ltv_tolerance: u128,
            target_ltv_min_delta: u128
        ) {
            let ltv_config = self
                .singleton
                .read()
                .ltv_config(pool_id, collateral_asset, debt_asset);

            assert!(target_ltv < ltv_config.max_ltv.into() * 90 / 100, "invalid-target-ltv");
            assert!(target_ltv_tolerance < target_ltv_min_delta, "invalid-target-ltv-tolerance");

            self
                .target_ltv_config
                .write(
                    (pool_id, collateral_asset, debt_asset, get_caller_address()),
                    TargetLTVConfig { target_ltv, target_ltv_tolerance, target_ltv_min_delta }
                );

            self
                .emit(
                    SetTargetLTVConfig {
                        pool_id,
                        collateral_asset,
                        debt_asset,
                        target_ltv,
                        target_ltv_tolerance,
                        target_ltv_min_delta
                    }
                );
        }

        fn delta(
            self: @ContractState,
            pool_id: felt252,
            collateral_asset: ContractAddress,
            debt_asset: ContractAddress,
            user: ContractAddress
        ) -> (u256, i257, i257, i257) {
            let singleton = self.singleton.read();

            let TargetLTVConfig { target_ltv, .. } = self
                .target_ltv_config
                .read((pool_id, collateral_asset, debt_asset, user));

            if target_ltv == 0 {
                return (0, i257_new(0, false), i257_new(0, false), i257_new(0, false));
            }

            let (_, collateral, debt) = singleton
                .position(pool_id, collateral_asset, debt_asset, user);

            let extension = IExtensionDispatcher { contract_address: singleton.extension(pool_id) };

            let collateral_asset_price = extension.price(pool_id, collateral_asset);
            let debt_asset_price = extension.price(pool_id, debt_asset);
            let (collateral_asset_config, _) = singleton.asset_config(pool_id, collateral_asset);
            let (debt_asset_config, _) = singleton.asset_config(pool_id, debt_asset);

            let collateral_usd = (collateral * collateral_asset_price.value.into())
                / collateral_asset_config.scale;
            let debt_usd = (debt * debt_asset_price.value.into()) / debt_asset_config.scale;
            let delta_usd = (i257_new(debt_usd, false) * i257_new(SCALE, false)
                - (i257_new(collateral_usd, false) * i257_new(target_ltv.into(), false)))
                / (i257_new(target_ltv.into(), false) - i257_new(SCALE, false));
            let current_ltv = debt_usd * SCALE / collateral_usd;

            let collateral_delta = delta_usd
                * collateral_asset_config.scale.into()
                / collateral_asset_price.value.into();
            let debt_delta = delta_usd
                * debt_asset_config.scale.into()
                / debt_asset_price.value.into();

            (current_ltv, delta_usd, collateral_delta, debt_delta)
        }

        fn rebalance_position(
            ref self: ContractState, rebalance_params: RebalanceParams
        ) -> RebalanceResponse {
            assert!(self.rebalancers.read(get_caller_address()), "only-rebalancer");
            call_core_with_callback(self.core.read(), @rebalance_params)
        }
    }
}
