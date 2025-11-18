use alexandria_math::i257::i257;
use starknet::ContractAddress;
use vesu::data_model::{AmountDenomination, AssetPrice, Position, UpdatePositionResponse};

#[starknet::interface]
pub trait ITokenMigration<T> {
    fn swap_to_new(ref self: T, amount: u256);
    fn swap_to_legacy(ref self: T, amount: u256);
    fn get_legacy_token(self: @T) -> ContractAddress;
    fn get_new_token(self: @T) -> ContractAddress;
}

#[derive(PartialEq, Copy, Drop, Serde, Default)]
pub enum AmountType {
    #[default]
    Delta,
    Target,
}

#[derive(PartialEq, Copy, Drop, Serde, Default)]
pub struct AmountSingletonV2 {
    pub amount_type: AmountType,
    pub denomination: AmountDenomination,
    pub value: i257,
}

#[derive(PartialEq, Copy, Drop, Serde)]
pub struct ModifyPositionParamsSingletonV2 {
    pub pool_id: felt252,
    pub collateral_asset: ContractAddress,
    pub debt_asset: ContractAddress,
    pub user: ContractAddress,
    pub collateral: AmountSingletonV2,
    pub debt: AmountSingletonV2,
    pub data: Span<felt252>,
}

#[starknet::interface]
pub trait IExtension<TContractState> {
    fn price(self: @TContractState, pool_id: felt252, asset: ContractAddress) -> AssetPrice;
}

#[starknet::interface]
pub trait ISingletonV2<TContractState> {
    fn extension(self: @TContractState, pool_id: felt252) -> ContractAddress;
    fn position(
        ref self: TContractState,
        pool_id: felt252,
        collateral_asset: ContractAddress,
        debt_asset: ContractAddress,
        user: ContractAddress,
    ) -> (Position, u256, u256);
    fn check_collateralization(
        ref self: TContractState,
        pool_id: felt252,
        collateral_asset: ContractAddress,
        debt_asset: ContractAddress,
        user: ContractAddress,
    ) -> (bool, u256, u256);
    fn delegation(
        self: @TContractState, pool_id: felt252, delegator: ContractAddress, delegatee: ContractAddress,
    ) -> bool;
    fn modify_delegation(ref self: TContractState, pool_id: felt252, delegatee: ContractAddress, delegation: bool);
    fn modify_position(ref self: TContractState, params: ModifyPositionParamsSingletonV2) -> UpdatePositionResponse;
}

#[derive(Serde, Drop, Clone)]
pub struct MigratePositionFromV1Params {
    pub from_pool_id: felt252,
    pub to_pool: ContractAddress,
    pub collateral_asset: ContractAddress,
    pub debt_asset: ContractAddress,
    pub from_user: ContractAddress,
    pub to_user: ContractAddress,
    pub collateral_to_migrate: u256,
    pub debt_to_migrate: u256,
    pub from_ltv_max_delta: u256,
    pub from_to_max_ltv_delta: u256,
}

#[derive(Serde, Drop, Clone)]
pub struct MigratePositionFromV2Params {
    pub from_pool: ContractAddress,
    pub to_pool: ContractAddress,
    pub collateral_asset: ContractAddress,
    pub debt_asset: ContractAddress,
    pub from_user: ContractAddress,
    pub to_user: ContractAddress,
    pub collateral_to_migrate: u256,
    pub debt_to_migrate: u256,
    pub from_ltv_max_delta: u256,
    pub from_to_max_ltv_delta: u256,
}

#[derive(Serde, Drop, Clone)]
pub enum MigrateAction {
    MigratePositionFromV1: MigratePositionFromV1Params,
    MigratePositionFromV2: MigratePositionFromV2Params,
}

#[starknet::interface]
pub trait IMigrate<TContractState> {
    fn migrate_position_from_v1(ref self: TContractState, params: MigratePositionFromV1Params);
    fn migrate_position_from_v2(ref self: TContractState, params: MigratePositionFromV2Params);
}

#[starknet::contract]
pub mod Migrate {
    use alexandria_math::i257::I257Trait;
    use ekubo::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use vesu::data_model::{Amount, AmountDenomination, ModifyPositionParams};
    use vesu::pool::{IFlashLoanReceiver, IPoolDispatcher, IPoolDispatcherTrait};
    use vesu::units::SCALE;
    use vesu_v2_periphery::migrate::{
        AmountSingletonV2, AmountType, IMigrate, ISingletonV2Dispatcher, ISingletonV2DispatcherTrait,
        ITokenMigrationDispatcher, ITokenMigrationDispatcherTrait, MigrateAction, MigratePositionFromV1Params,
        MigratePositionFromV2Params, ModifyPositionParamsSingletonV2, UpdatePositionResponse,
    };

    #[storage]
    struct Storage {
        singleton_v2: ISingletonV2Dispatcher,
        pool: ContractAddress,
        usdc_e: ContractAddress,
        usdc: ContractAddress,
        migrator: ITokenMigrationDispatcher,
    }

    #[constructor]
    fn constructor(ref self: ContractState, singleton_v2: ISingletonV2Dispatcher, migrator: ITokenMigrationDispatcher) {
        self.singleton_v2.write(singleton_v2);
        self.migrator.write(migrator);
    }

    fn compute_ltv(collateral_value: u256, debt_value: u256) -> u256 {
        if debt_value == 0 {
            0
        } else {
            debt_value * SCALE / collateral_value
        }
    }

    fn validate_ltv_range(old_ltv: u256, new_ltv: u256, ltv_max_delta: u256) {
        assert!(
            (old_ltv < ltv_max_delta || old_ltv - ltv_max_delta <= new_ltv) && new_ltv <= old_ltv + ltv_max_delta,
            "ltv-out-of-range",
        );
    }

    fn validate_ownership_v1(
        singleton_v2: ISingletonV2Dispatcher, pool_id: felt252, user: ContractAddress, caller: ContractAddress,
    ) {
        assert!(user == caller || singleton_v2.delegation(pool_id, user, caller), "unauthorized-caller");
    }

    fn validate_ownership_v2(pool: IPoolDispatcher, user: ContractAddress, caller: ContractAddress) {
        assert!(user == caller || pool.delegation(user, caller), "unauthorized-caller");
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn call_flash_loan(
            ref self: ContractState, pool: IPoolDispatcher, asset: ContractAddress, amount: u256, data: Span<felt252>,
        ) {
            assert!(self.pool.read() == 0.try_into().unwrap(), "reentrant-call");
            self.pool.write(pool.contract_address);
            pool.flash_loan(get_contract_address(), asset, amount, false, data);
            self.pool.write(0.try_into().unwrap());
        }

        fn _migrate_position_from_v1(ref self: ContractState, params: MigratePositionFromV1Params, amount: u256) {
            let singleton_v2 = self.singleton_v2.read();

            let MigratePositionFromV1Params {
                from_pool_id,
                to_pool,
                collateral_asset,
                debt_asset,
                from_user,
                to_user,
                collateral_to_migrate,
                debt_to_migrate,
                from_ltv_max_delta,
                from_to_max_ltv_delta,
            } = params;

            let to_pool = IPoolDispatcher { contract_address: to_pool };

            let (_, collateral_value, debt_value) = singleton_v2
                .check_collateralization(from_pool_id, collateral_asset, debt_asset, from_user);
            let from_ltv = debt_value * SCALE / collateral_value;
            let (_, collateral, debt) = singleton_v2.position(from_pool_id, collateral_asset, debt_asset, from_user);

            assert!(
                IERC20Dispatcher { contract_address: debt_asset }.approve(singleton_v2.contract_address, amount),
                "approve-failed",
            );

            let UpdatePositionResponse {
                collateral_delta, debt_delta, ..,
            } =
                singleton_v2
                    .modify_position(
                        ModifyPositionParamsSingletonV2 {
                            pool_id: from_pool_id,
                            collateral_asset,
                            debt_asset,
                            user: from_user,
                            collateral: if (collateral_to_migrate == 0 || collateral_to_migrate > collateral) {
                                AmountSingletonV2 {
                                    amount_type: AmountType::Target,
                                    denomination: AmountDenomination::Native,
                                    value: I257Trait::new(0, false),
                                }
                            } else {
                                AmountSingletonV2 {
                                    amount_type: AmountType::Delta,
                                    denomination: AmountDenomination::Assets,
                                    value: I257Trait::new(collateral_to_migrate, true),
                                }
                            },
                            debt: if (debt_to_migrate == 0 || debt_to_migrate > debt) {
                                AmountSingletonV2 {
                                    amount_type: AmountType::Target,
                                    denomination: AmountDenomination::Native,
                                    value: I257Trait::new(0, false),
                                }
                            } else {
                                AmountSingletonV2 {
                                    amount_type: AmountType::Delta,
                                    denomination: AmountDenomination::Assets,
                                    value: I257Trait::new(debt_to_migrate, true),
                                }
                            },
                            data: ArrayTrait::new().span(),
                        },
                    );

            assert!(debt_delta.abs() == amount, "debt-amount-mismatch");

            let (_, collateral_value, debt_value) = singleton_v2
                .check_collateralization(from_pool_id, collateral_asset, debt_asset, from_user);
            validate_ltv_range(from_ltv, compute_ltv(collateral_value, debt_value), from_ltv_max_delta);

            self
                .create_v2_position(
                    to_pool,
                    to_user,
                    collateral_asset,
                    debt_asset,
                    collateral_delta.abs(),
                    debt_delta.abs(),
                    from_ltv,
                    from_to_max_ltv_delta,
                );
        }

        fn _migrate_position_from_v2(ref self: ContractState, params: MigratePositionFromV2Params, amount: u256) {
            let MigratePositionFromV2Params {
                from_pool,
                to_pool,
                collateral_asset,
                debt_asset,
                from_user,
                to_user,
                collateral_to_migrate,
                debt_to_migrate,
                from_ltv_max_delta,
                from_to_max_ltv_delta,
            } = params;

            let from_pool = IPoolDispatcher { contract_address: from_pool };
            let to_pool = IPoolDispatcher { contract_address: to_pool };

            let (position, collateral, debt) = from_pool.position(collateral_asset, debt_asset, from_user);
            let (_, collateral_value, debt_value) = from_pool
                .check_collateralization(collateral_asset, debt_asset, from_user);
            let from_ltv = debt_value * SCALE / collateral_value;

            assert!(
                IERC20Dispatcher { contract_address: debt_asset }.approve(from_pool.contract_address, amount),
                "approve-failed",
            );

            let UpdatePositionResponse {
                collateral_delta, debt_delta, ..,
            } =
                from_pool
                    .modify_position(
                        ModifyPositionParams {
                            collateral_asset,
                            debt_asset,
                            user: from_user,
                            collateral: if (collateral_to_migrate == 0 || collateral_to_migrate > collateral) {
                                Amount {
                                    denomination: AmountDenomination::Native,
                                    value: I257Trait::new(position.collateral_shares, true),
                                }
                            } else {
                                Amount {
                                    denomination: AmountDenomination::Assets,
                                    value: I257Trait::new(collateral_to_migrate, true),
                                }
                            },
                            debt: if (debt_to_migrate == 0 || debt_to_migrate > debt) {
                                Amount {
                                    denomination: AmountDenomination::Native,
                                    value: I257Trait::new(position.nominal_debt, true),
                                }
                            } else {
                                Amount {
                                    denomination: AmountDenomination::Assets,
                                    value: I257Trait::new(debt_to_migrate, true),
                                }
                            },
                        },
                    );

            assert!(debt_delta.abs() == amount, "debt-amount-mismatch");

            let (_, collateral_value, debt_value) = from_pool
                .check_collateralization(collateral_asset, debt_asset, from_user);
            validate_ltv_range(from_ltv, compute_ltv(collateral_value, debt_value), from_ltv_max_delta);

            self
                .create_v2_position(
                    to_pool,
                    to_user,
                    collateral_asset,
                    debt_asset,
                    collateral_delta.abs(),
                    debt_delta.abs(),
                    from_ltv,
                    from_to_max_ltv_delta,
                );
        }

        fn create_v2_position(
            ref self: ContractState,
            to_pool: IPoolDispatcher,
            to_user: ContractAddress,
            mut collateral_asset: ContractAddress,
            mut debt_asset: ContractAddress,
            collateral_delta: u256,
            debt_delta: u256,
            from_ltv: u256,
            from_to_max_ltv_delta: u256,
        ) {
            let migrator = self.migrator.read();
            let legacy_token = migrator.get_legacy_token();
            let new_token = migrator.get_new_token();

            // if legacy token is collateral asset, then convert to the new token
            collateral_asset =
                if collateral_asset == legacy_token {
                    assert!(
                        IERC20Dispatcher { contract_address: collateral_asset }
                            .approve(migrator.contract_address, collateral_delta),
                        "approve-failed",
                    );
                    // assume swap amounts are 1:1
                    migrator.swap_to_new(collateral_delta);
                    new_token
                } else {
                    collateral_asset
                };

            assert!(
                IERC20Dispatcher { contract_address: collateral_asset }
                    .approve(to_pool.contract_address, collateral_delta),
                "approve-failed",
            );

            // if legacy token is debt asset, then borrow the new token
            let debt_asset_is_legacy_token = debt_asset == legacy_token;
            debt_asset = if debt_asset_is_legacy_token {
                new_token
            } else {
                debt_asset
            };

            to_pool
                .modify_position(
                    ModifyPositionParams {
                        collateral_asset,
                        debt_asset,
                        user: to_user,
                        collateral: Amount {
                            denomination: AmountDenomination::Assets, value: I257Trait::new(collateral_delta, false),
                        },
                        debt: Amount {
                            denomination: AmountDenomination::Assets, value: I257Trait::new(debt_delta, false),
                        },
                    },
                );

            let (_, collateral_value, debt_value) = to_pool
                .check_collateralization(collateral_asset, debt_asset, to_user);
            validate_ltv_range(from_ltv, compute_ltv(collateral_value, debt_value), from_to_max_ltv_delta);

            // if legacy token is debt asset, then convert borrowed new token back to the legacy token
            if debt_asset_is_legacy_token {
                assert!(
                    IERC20Dispatcher { contract_address: new_token }.approve(migrator.contract_address, debt_delta),
                    "approve-failed",
                );
                // assume swap amounts are 1:1
                migrator.swap_to_legacy(debt_delta);
            }
        }
    }

    #[abi(embed_v0)]
    impl FlashLoanReceiverImpl of IFlashLoanReceiver<ContractState> {
        fn on_flash_loan(
            ref self: ContractState,
            sender: ContractAddress,
            asset: ContractAddress,
            amount: u256,
            mut data: Span<felt252>,
        ) {
            assert!(get_caller_address() == self.pool.read(), "caller-not-pool");
            assert!(sender == get_contract_address(), "unknown-sender");

            let migrate_action: MigrateAction = Serde::deserialize(ref data).unwrap();

            match migrate_action {
                MigrateAction::MigratePositionFromV1(params) => self._migrate_position_from_v1(params, amount),
                MigrateAction::MigratePositionFromV2(params) => self._migrate_position_from_v2(params, amount),
            }

            IERC20Dispatcher { contract_address: asset }.approve(get_caller_address(), amount);
        }
    }

    #[abi(embed_v0)]
    impl MigrateImpl of IMigrate<ContractState> {
        fn migrate_position_from_v1(ref self: ContractState, params: MigratePositionFromV1Params) {
            let MigratePositionFromV1Params {
                from_pool_id, to_pool, collateral_asset, debt_asset, from_user, to_user, debt_to_migrate, ..,
            } = params.clone();

            let singleton_v2 = self.singleton_v2.read();
            let to_pool = IPoolDispatcher { contract_address: to_pool };
            let (_, _, debt) = singleton_v2.position(from_pool_id, collateral_asset, debt_asset, from_user);
            let debt = if (debt_to_migrate == 0 || debt_to_migrate > debt) {
                debt
            } else {
                debt_to_migrate
            };

            validate_ownership_v1(singleton_v2, from_pool_id, from_user, get_caller_address());
            validate_ownership_v2(to_pool, to_user, get_caller_address());

            let migrate_action = MigrateAction::MigratePositionFromV1(params);
            let mut data: Array<felt252> = array![];
            Serde::serialize(@migrate_action, ref data);

            self.call_flash_loan(pool: to_pool, asset: debt_asset, amount: debt, data: data.span());
        }

        fn migrate_position_from_v2(ref self: ContractState, params: MigratePositionFromV2Params) {
            let MigratePositionFromV2Params {
                from_pool, to_pool, collateral_asset, debt_asset, from_user, to_user, debt_to_migrate, ..,
            } = params.clone();

            let from_pool = IPoolDispatcher { contract_address: from_pool };
            let to_pool = IPoolDispatcher { contract_address: to_pool };
            let (_, _, debt) = from_pool.position(collateral_asset, debt_asset, from_user);
            let debt = if (debt_to_migrate == 0 || debt_to_migrate > debt) {
                debt
            } else {
                debt_to_migrate
            };

            validate_ownership_v2(from_pool, from_user, get_caller_address());
            validate_ownership_v2(to_pool, to_user, get_caller_address());

            let migrate_action = MigrateAction::MigratePositionFromV2(params);
            let mut data: Array<felt252> = array![];
            Serde::serialize(@migrate_action, ref data);

            self.call_flash_loan(pool: to_pool, asset: debt_asset, amount: debt, data: data.span());
        }
    }
}
