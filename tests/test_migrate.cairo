use starknet::ContractAddress;

#[starknet::interface]
trait IStarkgateERC20<TContractState> {
    fn permissioned_mint(ref self: TContractState, account: ContractAddress, amount: u256);
}

// test v1 to v2 partial, full
// test v1 to v2 collateral asset is usdc.e, partial, full
// test v1 to v2 debt asset is usdc.e, partial, full

// test v2 to v2 partial, full
// test v2 to v2 collateral asset is usdc.e, partial, full
// test v2 to v2 debt asset is usdc.e, partial, full

// test reentrant call

#[starknet::interface]
trait IReentrantPool<TContractState> {
    fn delegation(ref self: TContractState, delegatee: ContractAddress, delegation: bool) -> bool;
    fn flash_loan(
        ref self: TContractState,
        receiver: ContractAddress,
        asset: ContractAddress,
        amount: u256,
        is_legacy: bool,
        data: Span<felt252>,
    );
}

#[starknet::contract]
pub mod ReentrantPool {
    use starknet::ContractAddress;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use vesu_v2_periphery::migrate::{
        IMigrateDispatcher, IMigrateDispatcherTrait, MigrateAction, MigratePositionFromV2Params,
    };
    use super::IReentrantPool;

    #[storage]
    struct Storage {
        migrate: IMigrateDispatcher,
    }

    #[constructor]
    fn constructor(ref self: ContractState, migrate: IMigrateDispatcher) {
        self.migrate.write(migrate);
    }

    #[abi(embed_v0)]
    impl ReentrantPoolImpl of IReentrantPool<ContractState> {
        fn delegation(ref self: ContractState, delegatee: ContractAddress, delegation: bool) -> bool {
            true
        }

        fn flash_loan(
            ref self: ContractState,
            receiver: ContractAddress,
            asset: ContractAddress,
            amount: u256,
            is_legacy: bool,
            mut data: Span<felt252>,
        ) {
            let migrate_action: MigrateAction = Serde::deserialize(ref data).unwrap();

            match migrate_action {
                MigrateAction::MigratePositionFromV1(_) => (),
                MigrateAction::MigratePositionFromV2(params) => {
                    self
                        .migrate
                        .read()
                        .migrate_position_from_v2(
                            MigratePositionFromV2Params {
                                from_pool: params.from_pool,
                                to_pool: params.to_pool,
                                collateral_asset: params.collateral_asset,
                                debt_asset: params.debt_asset,
                                from_user: params.from_user,
                                to_user: params.to_user,
                                collateral_to_migrate: params.collateral_to_migrate,
                                debt_to_migrate: params.debt_to_migrate,
                                from_ltv_max_delta: params.from_ltv_max_delta,
                                from_to_max_ltv_delta: params.from_to_max_ltv_delta,
                            },
                        );
                },
            }
        }
    }
}

#[starknet::interface]
trait IUSDC<TContractState> {
    fn master_minter(ref self: TContractState) -> ContractAddress;
    fn mint(ref self: TContractState, to: ContractAddress, amount: u256);
    fn configure_minter(ref self: TContractState, minter_allowance: u256);
    fn configure_controller(ref self: TContractState, controller: ContractAddress, minter: ContractAddress);
}

#[cfg(test)]
mod Test_3845057_Migrate {
    use alexandria_math::i257::I257Trait;
    use ekubo::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use openzeppelin::token::erc20::interface::{IERC20MetadataDispatcher, IERC20MetadataDispatcherTrait};
    use snforge_std::{load, start_cheat_caller_address, stop_cheat_caller_address, store};
    #[feature("deprecated-starknet-consts")]
    use starknet::{ContractAddress, contract_address_const, get_contract_address};
    use vesu::data_model::{Amount, AmountDenomination, AssetParams, ModifyPositionParams, VTokenParams};
    use vesu::oracle::{IPragmaOracleDispatcher, IPragmaOracleDispatcherTrait};
    use vesu::pool::{IPoolDispatcher, IPoolDispatcherTrait};
    use vesu::pool_factory::{IPoolFactoryDispatcher, IPoolFactoryDispatcherTrait};
    use vesu::test::setup_v2::deploy_with_args;
    use vesu::units::{SCALE, SCALE_128};
    use vesu_v2_periphery::migrate::{
        AmountSingletonV2, AmountType, IMigrateDispatcher, IMigrateDispatcherTrait, ISingletonV2Dispatcher,
        ISingletonV2DispatcherTrait, ITokenMigrationDispatcher, MigratePositionFromV1Params,
        MigratePositionFromV2Params, ModifyPositionParamsSingletonV2,
    };
    use super::{
        IReentrantPoolDispatcher, IStarkgateERC20Dispatcher, IStarkgateERC20DispatcherTrait, IUSDCDispatcher,
        IUSDCDispatcherTrait,
    };

    const COLLATERAL_AMOUNT: u256 = 10_000_000_000;
    const DEBT_AMOUNT: u256 = 1000000000000000000; // SCALE

    struct TestConfig {
        migrate: IMigrateDispatcher,
        eth: IERC20Dispatcher,
        wbtc: IERC20Dispatcher,
        usdt: IERC20Dispatcher,
        legacy_usdc: IERC20Dispatcher,
        new_usdc: IERC20Dispatcher,
        user: ContractAddress,
        pool_1: IPoolDispatcher,
        pool_2: IPoolDispatcher,
        singleton_v2: ISingletonV2Dispatcher,
        pool_id: felt252,
    }

    fn create_position_v1(
        singleton_v2: ISingletonV2Dispatcher,
        pool_id: felt252,
        collateral_asset: ContractAddress,
        debt_asset: ContractAddress,
        user: ContractAddress,
        collateral_amount: u256,
        debt_amount: u256,
    ) {
        singleton_v2
            .modify_position(
                ModifyPositionParamsSingletonV2 {
                    pool_id,
                    collateral_asset,
                    debt_asset,
                    user,
                    collateral: AmountSingletonV2 {
                        amount_type: AmountType::Delta,
                        denomination: AmountDenomination::Assets,
                        value: I257Trait::new(collateral_amount.try_into().unwrap(), false),
                    },
                    debt: AmountSingletonV2 {
                        amount_type: AmountType::Delta,
                        denomination: AmountDenomination::Assets,
                        value: I257Trait::new(debt_amount.try_into().unwrap(), false),
                    },
                    data: ArrayTrait::new().span(),
                },
            );
    }

    fn create_position_v2(
        pool: IPoolDispatcher,
        collateral_asset: ContractAddress,
        debt_asset: ContractAddress,
        user: ContractAddress,
        collateral_amount: u256,
        debt_amount: u256,
    ) {
        pool
            .modify_position(
                ModifyPositionParams {
                    collateral_asset,
                    debt_asset,
                    user,
                    collateral: Amount {
                        denomination: AmountDenomination::Assets,
                        value: I257Trait::new(collateral_amount.try_into().unwrap(), false),
                    },
                    debt: Amount {
                        denomination: AmountDenomination::Assets,
                        value: I257Trait::new(debt_amount.try_into().unwrap(), false),
                    },
                },
            );
    }

    fn assert_position_v1(
        singleton_v2: ISingletonV2Dispatcher,
        pool_id: felt252,
        collateral_asset: ContractAddress,
        debt_asset: ContractAddress,
        user: ContractAddress,
        expected_collateral: u256,
        expected_debt: u256,
    ) {
        let (_, collateral, debt) = singleton_v2.position(pool_id, collateral_asset, debt_asset, user);
        assert!(collateral == expected_collateral, "v1 collateral mismatch");
        assert!(debt == expected_debt, "v1 debt mismatch");
    }

    fn assert_position_v2(
        pool: IPoolDispatcher,
        collateral_asset: ContractAddress,
        debt_asset: ContractAddress,
        user: ContractAddress,
        expected_collateral: u256,
        expected_debt: u256,
    ) {
        let (_, collateral, debt) = pool.position(collateral_asset, debt_asset, user);
        assert!(collateral == expected_collateral, "v2 collateral mismatch");
        assert!(debt == expected_debt, "v2 debt mismatch");
    }

    fn setup() -> TestConfig {
        let eth = IERC20Dispatcher {
            contract_address: contract_address_const::<
                0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7,
            >(),
        };
        let wbtc = IERC20Dispatcher {
            contract_address: contract_address_const::<
                0x03fe2b97c1fd336e750087d68b9b867997fd64a2661ff3ca5a7c771641e8e7ac,
            >(),
        };
        let usdt = IERC20Dispatcher {
            contract_address: contract_address_const::<
                0x068f5c6a61780768455de69077e07e89787839bf8166decfbf92b645209c0fb8,
            >(),
        };
        let legacy_usdc = IERC20Dispatcher {
            contract_address: contract_address_const::<
                0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8,
            >(),
        };
        let new_usdc = IERC20Dispatcher {
            contract_address: contract_address_const::<
                0x033068F6539f8e6e6b131e6B2B814e6c34A5224bC66947c47DaB9dFeE93b35fb,
            >(),
        };

        let usdc_migrator = ITokenMigrationDispatcher {
            contract_address: contract_address_const::<
                0x07bffc7f6bda62b7bee9b7880579633a38f7ef910e0ad5e686b0b8712e216a19,
            >(),
        };
        store(usdc_migrator.contract_address, selector!("l1_recipient_verified"), array![true.into()].span());
        store(usdc_migrator.contract_address, selector!("allow_swap_to_legacy"), array![true.into()].span());
        store(usdc_migrator.contract_address, selector!("batch_size"), array![1_000_000_000_000.into()].span());
        store(
            usdc_migrator.contract_address,
            selector!("token_supplier"),
            array![usdc_migrator.contract_address.into()].span(),
        );

        start_cheat_caller_address(new_usdc.contract_address, usdc_migrator.contract_address);
        new_usdc.approve(usdc_migrator.contract_address, 100000_000_000);
        stop_cheat_caller_address(new_usdc.contract_address);

        start_cheat_caller_address(legacy_usdc.contract_address, usdc_migrator.contract_address);
        legacy_usdc.approve(usdc_migrator.contract_address, 100000_000_000);
        stop_cheat_caller_address(legacy_usdc.contract_address);

        let pool_factory = IPoolFactoryDispatcher {
            contract_address: contract_address_const::<
                0x3760f903a37948f97302736f89ce30290e45f441559325026842b7a6fb388c0,
            >(),
        };
        let singleton_v2 = ISingletonV2Dispatcher {
            contract_address: contract_address_const::<
                0x000d8d6dfec4d33bfb6895de9f3852143a17c6f92fd2a21da3d6924d34870160,
            >(),
        };
        let pool_id = 0x4dc4f0ca6ea4961e4c8373265bfd5317678f4fe374d76f3fd7135f57763bf28;
        let pool_1 = IPoolDispatcher {
            contract_address: contract_address_const::<
                0x02eef0c13b10b487ea5916b54c0a7f98ec43fb3048f60fdeedaf5b08f6f88aaf,
            >(),
        };
        let pool_2 = IPoolDispatcher {
            contract_address: contract_address_const::<
                0x451fe483d5921a2919ddd81d0de6696669bccdacd859f72a4fba7656b97c3b5,
            >(),
        };

        let migrate = IMigrateDispatcher {
            contract_address: deploy_with_args(
                "Migrate", array![singleton_v2.contract_address.into(), usdc_migrator.contract_address.into()],
            ),
        };

        let user = get_contract_address();
        let lp = contract_address_const::<'lp'>();

        let loaded = load(eth.contract_address, selector!("permitted_minter"), 1);
        let minter: ContractAddress = (*loaded[0]).try_into().unwrap();
        start_cheat_caller_address(eth.contract_address, minter);
        IStarkgateERC20Dispatcher { contract_address: eth.contract_address }.permissioned_mint(lp, 100 * SCALE);
        IStarkgateERC20Dispatcher { contract_address: eth.contract_address }.permissioned_mint(user, 100 * SCALE);
        stop_cheat_caller_address(eth.contract_address);

        let loaded = load(usdt.contract_address, selector!("permitted_minter"), 1);
        let minter: ContractAddress = (*loaded[0]).try_into().unwrap();
        start_cheat_caller_address(usdt.contract_address, minter);
        IStarkgateERC20Dispatcher { contract_address: usdt.contract_address }.permissioned_mint(user, 100000_000_000);
        IStarkgateERC20Dispatcher { contract_address: usdt.contract_address }
            .permissioned_mint(pool_1.curator(), 500000_000_000);
        IStarkgateERC20Dispatcher { contract_address: usdt.contract_address }
            .permissioned_mint(pool_2.curator(), 500000_000_000);
        stop_cheat_caller_address(usdt.contract_address);

        let loaded = load(legacy_usdc.contract_address, selector!("permitted_minter"), 1);
        let minter: ContractAddress = (*loaded[0]).try_into().unwrap();
        start_cheat_caller_address(legacy_usdc.contract_address, minter);
        IStarkgateERC20Dispatcher { contract_address: legacy_usdc.contract_address }
            .permissioned_mint(user, 100000_000_000);
        IStarkgateERC20Dispatcher { contract_address: legacy_usdc.contract_address }
            .permissioned_mint(usdc_migrator.contract_address, 100000_000_000);
        IStarkgateERC20Dispatcher { contract_address: legacy_usdc.contract_address }
            .permissioned_mint(pool_1.curator(), 100000_000_000);
        IStarkgateERC20Dispatcher { contract_address: legacy_usdc.contract_address }
            .permissioned_mint(pool_2.curator(), 100000_000_000);
        stop_cheat_caller_address(legacy_usdc.contract_address);

        let loaded = load(wbtc.contract_address, selector!("permitted_minter"), 1);
        let minter: ContractAddress = (*loaded[0]).try_into().unwrap();
        start_cheat_caller_address(wbtc.contract_address, minter);
        IStarkgateERC20Dispatcher { contract_address: wbtc.contract_address }.permissioned_mint(user, 100000_000_000);
        IStarkgateERC20Dispatcher { contract_address: wbtc.contract_address }
            .permissioned_mint(pool_1.curator(), 100000_000_000);
        IStarkgateERC20Dispatcher { contract_address: wbtc.contract_address }
            .permissioned_mint(pool_2.curator(), 100000_000_000);
        stop_cheat_caller_address(wbtc.contract_address);

        let loaded = load(new_usdc.contract_address, selector!("master_minter"), 1);
        let minter: ContractAddress = (*loaded[0]).try_into().unwrap();
        start_cheat_caller_address(new_usdc.contract_address, minter);
        IUSDCDispatcher { contract_address: new_usdc.contract_address }.configure_controller(minter, minter);
        IUSDCDispatcher { contract_address: new_usdc.contract_address }.configure_minter(10000000_000_000);
        IUSDCDispatcher { contract_address: new_usdc.contract_address }.mint(user, 100000_000_000);
        IUSDCDispatcher { contract_address: new_usdc.contract_address }
            .mint(usdc_migrator.contract_address, 100000_000_000);
        IUSDCDispatcher { contract_address: new_usdc.contract_address }.mint(pool_1.curator(), 500000_000_000);
        IUSDCDispatcher { contract_address: new_usdc.contract_address }.mint(pool_2.curator(), 500000_000_000);
        stop_cheat_caller_address(new_usdc.contract_address);

        start_cheat_caller_address(legacy_usdc.contract_address, pool_2.curator());
        legacy_usdc.approve(pool_2.contract_address, 100000_000_000);
        stop_cheat_caller_address(legacy_usdc.contract_address);
        start_cheat_caller_address(usdt.contract_address, pool_2.curator());
        usdt.approve(pool_2.contract_address, 100000_000_000);
        stop_cheat_caller_address(usdt.contract_address);

        start_cheat_caller_address(pool_2.contract_address, pool_2.curator());
        pool_2.donate_to_reserve(legacy_usdc.contract_address, 100000_000_000);
        pool_2.donate_to_reserve(usdt.contract_address, 100000_000_000);
        stop_cheat_caller_address(pool_2.contract_address);

        let asset_config = pool_2.asset_config(legacy_usdc.contract_address);
        let interest_rate_config = pool_2.interest_rate_config(legacy_usdc.contract_address);
        let v_token = IERC20MetadataDispatcher {
            contract_address: pool_factory.v_token_for_asset(pool_2.contract_address, legacy_usdc.contract_address),
        };

        start_cheat_caller_address(pool_2.contract_address, pool_2.curator());
        pool_2.nominate_curator(pool_factory.contract_address);
        stop_cheat_caller_address(pool_2.contract_address);

        start_cheat_caller_address(new_usdc.contract_address, pool_2.curator());
        new_usdc.approve(pool_factory.contract_address, 100000_000_000.into());
        stop_cheat_caller_address(new_usdc.contract_address);

        let oracle = IPragmaOracleDispatcher { contract_address: pool_2.oracle() };
        start_cheat_caller_address(oracle.contract_address, pool_2.curator());
        oracle.add_asset(new_usdc.contract_address, oracle.oracle_config(legacy_usdc.contract_address));
        stop_cheat_caller_address(oracle.contract_address);

        start_cheat_caller_address(pool_factory.contract_address, pool_2.curator());
        pool_factory
            .add_asset(
                pool: pool_2.contract_address,
                asset: new_usdc.contract_address,
                asset_params: AssetParams {
                    asset: new_usdc.contract_address,
                    floor: asset_config.floor,
                    initial_full_utilization_rate: 13035786672,
                    max_utilization: asset_config.max_utilization,
                    is_legacy: asset_config.is_legacy,
                    fee_rate: asset_config.fee_rate,
                },
                interest_rate_config: interest_rate_config,
                v_token_params: VTokenParams {
                    v_token_name: v_token.name(), v_token_symbol: v_token.symbol(), debt_asset: eth.contract_address,
                },
            );
        stop_cheat_caller_address(pool_factory.contract_address);

        start_cheat_caller_address(pool_2.contract_address, pool_2.pending_curator());
        pool_2.accept_curator_ownership();
        stop_cheat_caller_address(pool_2.contract_address);

        start_cheat_caller_address(new_usdc.contract_address, pool_2.curator());
        new_usdc.approve(pool_2.contract_address, 100000_000_000);
        stop_cheat_caller_address(new_usdc.contract_address);

        start_cheat_caller_address(wbtc.contract_address, pool_2.curator());
        wbtc.approve(pool_2.contract_address, 1_000_000_00);
        stop_cheat_caller_address(wbtc.contract_address);

        start_cheat_caller_address(pool_1.contract_address, pool_1.curator());
        pool_1.set_pair_parameter(legacy_usdc.contract_address, wbtc.contract_address, 'max_ltv', SCALE_128);
        stop_cheat_caller_address(pool_1.contract_address);

        start_cheat_caller_address(pool_2.contract_address, pool_2.curator());
        pool_2.donate_to_reserve(new_usdc.contract_address, 100000_000_000);
        pool_2.donate_to_reserve(wbtc.contract_address, 1_000_000_00);
        pool_2.set_pair_parameter(new_usdc.contract_address, eth.contract_address, 'max_ltv', SCALE_128);
        pool_2.set_pair_parameter(eth.contract_address, new_usdc.contract_address, 'max_ltv', SCALE_128);
        pool_2.set_pair_parameter(new_usdc.contract_address, wbtc.contract_address, 'max_ltv', SCALE_128);
        pool_2.set_pair_parameter(wbtc.contract_address, new_usdc.contract_address, 'max_ltv', SCALE_128);
        stop_cheat_caller_address(pool_2.contract_address);

        let test_config = TestConfig {
            migrate, eth, wbtc, usdt, legacy_usdc, new_usdc, user, pool_1, pool_2, singleton_v2, pool_id,
        };

        test_config
    }

    #[test]
    #[fork("Mainnet")]
    fn test_migrate_position_from_v1() {
        let TestConfig { pool_2, migrate, eth, usdt, user, singleton_v2, pool_id, .. } = setup();

        usdt.approve(singleton_v2.contract_address, COLLATERAL_AMOUNT.into());

        create_position_v1(
            singleton_v2, pool_id, usdt.contract_address, eth.contract_address, user, COLLATERAL_AMOUNT, DEBT_AMOUNT,
        );

        assert_position_v1(
            singleton_v2,
            pool_id,
            usdt.contract_address,
            eth.contract_address,
            user,
            COLLATERAL_AMOUNT.into() - 1,
            DEBT_AMOUNT.into() + 1,
        );

        singleton_v2.modify_delegation(pool_id, migrate.contract_address, true);
        pool_2.modify_delegation(migrate.contract_address, true);

        migrate
            .migrate_position_from_v1(
                MigratePositionFromV1Params {
                    from_pool_id: pool_id,
                    to_pool: pool_2.contract_address,
                    collateral_asset: usdt.contract_address,
                    debt_asset: eth.contract_address,
                    from_user: user,
                    to_user: user,
                    collateral_to_migrate: COLLATERAL_AMOUNT.into() / 2,
                    debt_to_migrate: DEBT_AMOUNT.into() / 2,
                    from_ltv_max_delta: SCALE,
                    from_to_max_ltv_delta: SCALE / 1000,
                },
            );

        assert_position_v1(
            singleton_v2,
            pool_id,
            usdt.contract_address,
            eth.contract_address,
            user,
            COLLATERAL_AMOUNT.into() / 2 - 1,
            DEBT_AMOUNT.into() / 2 + 2,
        );

        assert_position_v2(
            pool_2,
            usdt.contract_address,
            eth.contract_address,
            user,
            COLLATERAL_AMOUNT.into() / 2 - 1,
            DEBT_AMOUNT.into() / 2 + 1,
        );

        migrate
            .migrate_position_from_v1(
                MigratePositionFromV1Params {
                    from_pool_id: pool_id,
                    to_pool: pool_2.contract_address,
                    collateral_asset: usdt.contract_address,
                    debt_asset: eth.contract_address,
                    from_user: user,
                    to_user: user,
                    collateral_to_migrate: 0,
                    debt_to_migrate: 0,
                    from_ltv_max_delta: SCALE,
                    from_to_max_ltv_delta: SCALE / 1000,
                },
            );

        assert_position_v1(singleton_v2, pool_id, usdt.contract_address, eth.contract_address, user, 0, 0);

        assert_position_v2(
            pool_2,
            usdt.contract_address,
            eth.contract_address,
            user,
            COLLATERAL_AMOUNT.into() - 2,
            DEBT_AMOUNT.into() + 4,
        );
    }

    #[test]
    #[should_panic(expected: "unauthorized-caller")]
    #[fork("Mainnet")]
    fn test_migrate_position_from_v1_unauthorized_caller() {
        let TestConfig { pool_2, migrate, eth, usdt, user, singleton_v2, pool_id, .. } = setup();

        usdt.approve(singleton_v2.contract_address, COLLATERAL_AMOUNT.into());

        create_position_v1(
            singleton_v2, pool_id, usdt.contract_address, eth.contract_address, user, COLLATERAL_AMOUNT, DEBT_AMOUNT,
        );

        assert_position_v1(
            singleton_v2,
            pool_id,
            usdt.contract_address,
            eth.contract_address,
            user,
            COLLATERAL_AMOUNT.into() - 1,
            DEBT_AMOUNT.into() + 1,
        );

        singleton_v2.modify_delegation(pool_id, migrate.contract_address, true);
        pool_2.modify_delegation(migrate.contract_address, true);

        start_cheat_caller_address(migrate.contract_address, 0x1.try_into().unwrap());
        migrate
            .migrate_position_from_v1(
                MigratePositionFromV1Params {
                    from_pool_id: pool_id,
                    to_pool: pool_2.contract_address,
                    collateral_asset: usdt.contract_address,
                    debt_asset: eth.contract_address,
                    from_user: user,
                    to_user: user,
                    collateral_to_migrate: COLLATERAL_AMOUNT.into() / 2,
                    debt_to_migrate: DEBT_AMOUNT.into() / 2,
                    from_ltv_max_delta: SCALE,
                    from_to_max_ltv_delta: SCALE / 1000,
                },
            );
    }
    #[test]
    #[fork("Mainnet")]
    fn test_migrate_position_from_v1_no_debt_to_debt_position() {
        let TestConfig { pool_2, migrate, eth, usdt, user, singleton_v2, pool_id, .. } = setup();

        usdt.approve(singleton_v2.contract_address, COLLATERAL_AMOUNT.into());

        create_position_v1(
            singleton_v2, pool_id, usdt.contract_address, eth.contract_address, user, COLLATERAL_AMOUNT, DEBT_AMOUNT,
        );

        assert_position_v1(
            singleton_v2,
            pool_id,
            usdt.contract_address,
            eth.contract_address,
            user,
            COLLATERAL_AMOUNT.into() - 1,
            DEBT_AMOUNT.into() + 1,
        );

        singleton_v2.modify_delegation(pool_id, migrate.contract_address, true);
        pool_2.modify_delegation(migrate.contract_address, true);

        migrate
            .migrate_position_from_v1(
                MigratePositionFromV1Params {
                    from_pool_id: pool_id,
                    to_pool: pool_2.contract_address,
                    collateral_asset: usdt.contract_address,
                    debt_asset: eth.contract_address,
                    from_user: user,
                    to_user: user,
                    collateral_to_migrate: COLLATERAL_AMOUNT.into() / 2,
                    debt_to_migrate: DEBT_AMOUNT.into() / 2,
                    from_ltv_max_delta: SCALE,
                    from_to_max_ltv_delta: SCALE / 1000,
                },
            );

        assert_position_v1(
            singleton_v2,
            pool_id,
            usdt.contract_address,
            eth.contract_address,
            user,
            COLLATERAL_AMOUNT.into() / 2 - 1,
            DEBT_AMOUNT.into() / 2 + 2,
        );

        assert_position_v2(
            pool_2,
            usdt.contract_address,
            eth.contract_address,
            user,
            COLLATERAL_AMOUNT.into() / 2 - 1,
            DEBT_AMOUNT.into() / 2 + 1,
        );

        eth.approve(singleton_v2.contract_address, SCALE.into());

        // repay debt
        singleton_v2
            .modify_position(
                ModifyPositionParamsSingletonV2 {
                    pool_id,
                    collateral_asset: usdt.contract_address,
                    debt_asset: eth.contract_address,
                    user,
                    collateral: Default::default(),
                    debt: AmountSingletonV2 {
                        amount_type: AmountType::Target,
                        denomination: AmountDenomination::Native,
                        value: 0.try_into().unwrap(),
                    },
                    data: ArrayTrait::new().span(),
                },
            );

        let (_, collateral, debt) = singleton_v2.position(pool_id, usdt.contract_address, eth.contract_address, user);
        assert!(collateral == 5000_000_000 - 1);
        assert!(debt == 0);

        migrate
            .migrate_position_from_v1(
                MigratePositionFromV1Params {
                    from_pool_id: pool_id,
                    to_pool: pool_2.contract_address,
                    collateral_asset: usdt.contract_address,
                    debt_asset: eth.contract_address,
                    from_user: user,
                    to_user: user,
                    collateral_to_migrate: 0,
                    debt_to_migrate: 0,
                    from_ltv_max_delta: SCALE,
                    from_to_max_ltv_delta: SCALE,
                },
            );

        let (_, collateral, debt) = singleton_v2.position(pool_id, usdt.contract_address, eth.contract_address, user);
        assert!(collateral == 0);
        assert!(debt == 0);

        let (_, collateral, debt) = pool_2.position(usdt.contract_address, eth.contract_address, user);
        assert!(collateral == 10000_000_000 - 2);
        assert!(debt == SCALE / 2 + 1);
    }
    #[test]
    #[should_panic(expected: "ltv-out-of-range")]
    #[fork("Mainnet")]
    fn test_migrate_position_from_v1_ltv_out_of_range() {
        let TestConfig { pool_2, migrate, eth, usdt, user, singleton_v2, pool_id, .. } = setup();

        usdt.approve(singleton_v2.contract_address, COLLATERAL_AMOUNT.into());

        create_position_v1(
            singleton_v2, pool_id, usdt.contract_address, eth.contract_address, user, COLLATERAL_AMOUNT, DEBT_AMOUNT,
        );

        assert_position_v1(
            singleton_v2,
            pool_id,
            usdt.contract_address,
            eth.contract_address,
            user,
            COLLATERAL_AMOUNT.into() - 1,
            DEBT_AMOUNT.into() + 1,
        );

        singleton_v2.modify_delegation(pool_id, migrate.contract_address, true);
        pool_2.modify_delegation(migrate.contract_address, true);

        migrate
            .migrate_position_from_v1(
                MigratePositionFromV1Params {
                    from_pool_id: pool_id,
                    to_pool: pool_2.contract_address,
                    collateral_asset: usdt.contract_address,
                    debt_asset: eth.contract_address,
                    from_user: user,
                    to_user: user,
                    collateral_to_migrate: COLLATERAL_AMOUNT.into() / 2,
                    debt_to_migrate: DEBT_AMOUNT.into() / 2,
                    from_ltv_max_delta: SCALE,
                    from_to_max_ltv_delta: SCALE / 1000,
                },
            );

        assert_position_v1(
            singleton_v2,
            pool_id,
            usdt.contract_address,
            eth.contract_address,
            user,
            COLLATERAL_AMOUNT.into() / 2 - 1,
            DEBT_AMOUNT.into() / 2 + 2,
        );

        assert_position_v2(
            pool_2,
            usdt.contract_address,
            eth.contract_address,
            user,
            COLLATERAL_AMOUNT.into() / 2 - 1,
            DEBT_AMOUNT.into() / 2 + 1,
        );

        migrate
            .migrate_position_from_v1(
                MigratePositionFromV1Params {
                    from_pool_id: pool_id,
                    to_pool: pool_2.contract_address,
                    collateral_asset: usdt.contract_address,
                    debt_asset: eth.contract_address,
                    from_user: user,
                    to_user: user,
                    collateral_to_migrate: 0,
                    debt_to_migrate: 0,
                    from_ltv_max_delta: SCALE,
                    from_to_max_ltv_delta: SCALE / 1000000,
                },
            );
    }

    #[test]
    #[fork("Mainnet")]
    fn test_migrate_position_from_v1_legacy_usdc_to_new_usdc_collateral_asset() {
        let TestConfig { pool_2, migrate, eth, legacy_usdc, new_usdc, user, singleton_v2, pool_id, .. } = setup();

        legacy_usdc.approve(singleton_v2.contract_address, COLLATERAL_AMOUNT.into());

        create_position_v1(
            singleton_v2,
            pool_id,
            legacy_usdc.contract_address,
            eth.contract_address,
            user,
            COLLATERAL_AMOUNT,
            DEBT_AMOUNT,
        );

        assert_position_v1(
            singleton_v2,
            pool_id,
            legacy_usdc.contract_address,
            eth.contract_address,
            user,
            COLLATERAL_AMOUNT.into() - 1,
            DEBT_AMOUNT.into() + 1,
        );

        singleton_v2.modify_delegation(pool_id, migrate.contract_address, true);
        pool_2.modify_delegation(migrate.contract_address, true);

        migrate
            .migrate_position_from_v1(
                MigratePositionFromV1Params {
                    from_pool_id: pool_id,
                    to_pool: pool_2.contract_address,
                    collateral_asset: legacy_usdc.contract_address,
                    debt_asset: eth.contract_address,
                    from_user: user,
                    to_user: user,
                    collateral_to_migrate: COLLATERAL_AMOUNT.into() / 2,
                    debt_to_migrate: DEBT_AMOUNT.into() / 2,
                    from_ltv_max_delta: SCALE,
                    from_to_max_ltv_delta: SCALE / 1000,
                },
            );

        assert_position_v1(
            singleton_v2,
            pool_id,
            legacy_usdc.contract_address,
            eth.contract_address,
            user,
            COLLATERAL_AMOUNT.into() / 2 - 1,
            DEBT_AMOUNT.into() / 2 + 2,
        );

        assert_position_v2(
            pool_2,
            new_usdc.contract_address,
            eth.contract_address,
            user,
            COLLATERAL_AMOUNT.into() / 2 - 1,
            DEBT_AMOUNT.into() / 2 + 1,
        );

        migrate
            .migrate_position_from_v1(
                MigratePositionFromV1Params {
                    from_pool_id: pool_id,
                    to_pool: pool_2.contract_address,
                    collateral_asset: legacy_usdc.contract_address,
                    debt_asset: eth.contract_address,
                    from_user: user,
                    to_user: user,
                    collateral_to_migrate: 0,
                    debt_to_migrate: 0,
                    from_ltv_max_delta: SCALE,
                    from_to_max_ltv_delta: SCALE / 1000,
                },
            );

        assert_position_v1(singleton_v2, pool_id, new_usdc.contract_address, eth.contract_address, user, 0, 0);

        assert_position_v2(
            pool_2,
            new_usdc.contract_address,
            eth.contract_address,
            user,
            COLLATERAL_AMOUNT.into() - 2,
            DEBT_AMOUNT.into() + 4,
        );
    }

    #[test]
    #[fork("Mainnet")]
    fn test_migrate_position_from_v1_legacy_usdc_to_new_usdc_debt_asset() {
        let TestConfig { pool_2, migrate, eth, legacy_usdc, new_usdc, user, singleton_v2, pool_id, .. } = setup();

        eth.approve(singleton_v2.contract_address, DEBT_AMOUNT.into());

        create_position_v1(
            singleton_v2, pool_id, eth.contract_address, legacy_usdc.contract_address, user, DEBT_AMOUNT, 1000_000_000,
        );

        assert_position_v1(
            singleton_v2,
            pool_id,
            eth.contract_address,
            legacy_usdc.contract_address,
            user,
            DEBT_AMOUNT.into() - 1,
            1000_000_000 + 1,
        );

        singleton_v2.modify_delegation(pool_id, migrate.contract_address, true);
        pool_2.modify_delegation(migrate.contract_address, true);

        migrate
            .migrate_position_from_v1(
                MigratePositionFromV1Params {
                    from_pool_id: pool_id,
                    to_pool: pool_2.contract_address,
                    collateral_asset: eth.contract_address,
                    debt_asset: legacy_usdc.contract_address,
                    from_user: user,
                    to_user: user,
                    collateral_to_migrate: DEBT_AMOUNT.into() / 2,
                    debt_to_migrate: 500_000_000,
                    from_ltv_max_delta: SCALE,
                    from_to_max_ltv_delta: SCALE / 1000,
                },
            );

        assert_position_v1(
            singleton_v2,
            pool_id,
            eth.contract_address,
            legacy_usdc.contract_address,
            user,
            DEBT_AMOUNT.into() / 2 - 1,
            500_000_000 + 1,
        );

        assert_position_v2(
            pool_2, eth.contract_address, new_usdc.contract_address, user, DEBT_AMOUNT.into() / 2 - 1, 500_000_000,
        );

        migrate
            .migrate_position_from_v1(
                MigratePositionFromV1Params {
                    from_pool_id: pool_id,
                    to_pool: pool_2.contract_address,
                    collateral_asset: eth.contract_address,
                    debt_asset: legacy_usdc.contract_address,
                    from_user: user,
                    to_user: user,
                    collateral_to_migrate: 0,
                    debt_to_migrate: 0,
                    from_ltv_max_delta: SCALE,
                    from_to_max_ltv_delta: SCALE / 1000,
                },
            );

        assert_position_v1(singleton_v2, pool_id, eth.contract_address, legacy_usdc.contract_address, user, 0, 0);

        assert_position_v2(
            pool_2, eth.contract_address, new_usdc.contract_address, user, DEBT_AMOUNT.into() - 3, 1000_000_000 + 1,
        );
    }

    #[test]
    #[should_panic(expected: "unauthorized-caller")]
    #[fork("Mainnet")]
    fn test_migrate_position_from_v2_unauthorized_caller() {
        let TestConfig { pool_1, pool_2, migrate, wbtc, legacy_usdc, user, .. } = setup();

        legacy_usdc.approve(pool_1.contract_address, COLLATERAL_AMOUNT.into());

        create_position_v2(
            pool_1, legacy_usdc.contract_address, wbtc.contract_address, user, COLLATERAL_AMOUNT, 1000000,
        );

        assert_position_v2(
            pool_1,
            legacy_usdc.contract_address,
            wbtc.contract_address,
            user,
            COLLATERAL_AMOUNT.into() - 1,
            1000000 + 1,
        );

        pool_1.modify_delegation(migrate.contract_address, true);
        pool_2.modify_delegation(migrate.contract_address, true);

        migrate
            .migrate_position_from_v2(
                MigratePositionFromV2Params {
                    from_pool: pool_1.contract_address,
                    to_pool: pool_2.contract_address,
                    collateral_asset: legacy_usdc.contract_address,
                    debt_asset: wbtc.contract_address,
                    from_user: wbtc.contract_address,
                    to_user: user,
                    collateral_to_migrate: 5000_000_000,
                    debt_to_migrate: 1000000 / 2,
                    from_ltv_max_delta: SCALE,
                    from_to_max_ltv_delta: SCALE / 1000,
                },
            );
    }

    #[test]
    #[fork("Mainnet")]
    fn test_migrate_position_from_v2_legacy_usdc_to_new_usdc_collateral_asset() {
        let TestConfig { pool_1, pool_2, migrate, wbtc, legacy_usdc, new_usdc, user, .. } = setup();

        legacy_usdc.approve(pool_1.contract_address, COLLATERAL_AMOUNT.into());

        create_position_v2(
            pool_1, legacy_usdc.contract_address, wbtc.contract_address, user, COLLATERAL_AMOUNT, 1000000,
        );

        assert_position_v2(
            pool_1,
            legacy_usdc.contract_address,
            wbtc.contract_address,
            user,
            COLLATERAL_AMOUNT.into() - 1,
            1000000 + 1,
        );

        pool_1.modify_delegation(migrate.contract_address, true);
        pool_2.modify_delegation(migrate.contract_address, true);

        migrate
            .migrate_position_from_v2(
                MigratePositionFromV2Params {
                    from_pool: pool_1.contract_address,
                    to_pool: pool_2.contract_address,
                    collateral_asset: legacy_usdc.contract_address,
                    debt_asset: wbtc.contract_address,
                    from_user: user,
                    to_user: user,
                    collateral_to_migrate: COLLATERAL_AMOUNT.into() / 2,
                    debt_to_migrate: 1000000 / 2,
                    from_ltv_max_delta: SCALE,
                    from_to_max_ltv_delta: SCALE / 1000,
                },
            );

        assert_position_v2(
            pool_1,
            legacy_usdc.contract_address,
            wbtc.contract_address,
            user,
            COLLATERAL_AMOUNT.into() / 2 - 1,
            1000000 / 2 + 1,
        );

        assert_position_v2(
            pool_2,
            new_usdc.contract_address,
            wbtc.contract_address,
            user,
            COLLATERAL_AMOUNT.into() / 2 - 1,
            1000000 / 2 + 1,
        );

        migrate
            .migrate_position_from_v2(
                MigratePositionFromV2Params {
                    from_pool: pool_1.contract_address,
                    to_pool: pool_2.contract_address,
                    collateral_asset: legacy_usdc.contract_address,
                    debt_asset: wbtc.contract_address,
                    from_user: user,
                    to_user: user,
                    collateral_to_migrate: 0,
                    debt_to_migrate: 0,
                    from_ltv_max_delta: SCALE,
                    from_to_max_ltv_delta: SCALE / 1000,
                },
            );

        assert_position_v2(pool_1, legacy_usdc.contract_address, wbtc.contract_address, user, 0, 0);

        assert_position_v2(
            pool_2, new_usdc.contract_address, wbtc.contract_address, user, COLLATERAL_AMOUNT.into() - 2, 1000000 + 2,
        );
    }

    #[test]
    #[fork("Mainnet")]
    fn test_migrate_position_from_v2_legacy_usdc_to_new_usdc_debt_asset() {
        let TestConfig { pool_1, pool_2, migrate, wbtc, legacy_usdc, new_usdc, user, .. } = setup();

        wbtc.approve(pool_1.contract_address, 10000000.into());

        create_position_v2(pool_1, wbtc.contract_address, legacy_usdc.contract_address, user, 10000000, 1000_000_000);

        assert_position_v2(
            pool_1, wbtc.contract_address, legacy_usdc.contract_address, user, 10000000, 1000_000_000 + 1,
        );

        pool_1.modify_delegation(migrate.contract_address, true);
        pool_2.modify_delegation(migrate.contract_address, true);

        migrate
            .migrate_position_from_v2(
                MigratePositionFromV2Params {
                    from_pool: pool_1.contract_address,
                    to_pool: pool_2.contract_address,
                    collateral_asset: wbtc.contract_address,
                    debt_asset: legacy_usdc.contract_address,
                    from_user: user,
                    to_user: user,
                    collateral_to_migrate: 5000000,
                    debt_to_migrate: 500_000_000,
                    from_ltv_max_delta: SCALE,
                    from_to_max_ltv_delta: SCALE / 1000,
                },
            );

        assert_position_v2(pool_1, wbtc.contract_address, legacy_usdc.contract_address, user, 5000000, 500_000_000 + 1);

        assert_position_v2(pool_2, wbtc.contract_address, new_usdc.contract_address, user, 5000000 - 1, 500_000_000);

        migrate
            .migrate_position_from_v2(
                MigratePositionFromV2Params {
                    from_pool: pool_1.contract_address,
                    to_pool: pool_2.contract_address,
                    collateral_asset: wbtc.contract_address,
                    debt_asset: legacy_usdc.contract_address,
                    from_user: user,
                    to_user: user,
                    collateral_to_migrate: 0,
                    debt_to_migrate: 0,
                    from_ltv_max_delta: SCALE,
                    from_to_max_ltv_delta: SCALE / 1000,
                },
            );

        assert_position_v2(pool_1, wbtc.contract_address, legacy_usdc.contract_address, user, 0, 0);

        assert_position_v2(
            pool_2, wbtc.contract_address, new_usdc.contract_address, user, 10000000 - 1, 1000_000_000 + 1,
        );
    }

    #[test]
    #[should_panic(expected: "reentrant-call")]
    #[fork("Mainnet")]
    fn test_migrate_reentrant_call() {
        let TestConfig { pool_2, migrate, eth, legacy_usdc, user, .. } = setup();

        eth.approve(pool_2.contract_address, DEBT_AMOUNT.into());

        create_position_v2(pool_2, eth.contract_address, legacy_usdc.contract_address, user, DEBT_AMOUNT, 1000_000_000);

        assert_position_v2(
            pool_2, eth.contract_address, legacy_usdc.contract_address, user, DEBT_AMOUNT.into() - 1, 1000_000_000 + 1,
        );

        pool_2.modify_delegation(migrate.contract_address, true);

        let reentrant_pool = IReentrantPoolDispatcher {
            contract_address: deploy_with_args("ReentrantPool", array![migrate.contract_address.into()]),
        };

        pool_2.modify_delegation(reentrant_pool.contract_address, true);

        migrate
            .migrate_position_from_v2(
                MigratePositionFromV2Params {
                    from_pool: pool_2.contract_address,
                    to_pool: reentrant_pool.contract_address,
                    collateral_asset: eth.contract_address,
                    debt_asset: legacy_usdc.contract_address,
                    from_user: user,
                    to_user: user,
                    collateral_to_migrate: 0,
                    debt_to_migrate: 0,
                    from_ltv_max_delta: 0,
                    from_to_max_ltv_delta: 0,
                },
            );
    }
}
