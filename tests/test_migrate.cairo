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

#[cfg(test)]
mod Test_3494530_Migrate {
    use alexandria_math::i257::I257Trait;
    use ekubo::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use snforge_std::{load, start_cheat_caller_address, stop_cheat_caller_address, store};
    #[feature("deprecated-starknet-consts")]
    use starknet::{ContractAddress, contract_address_const, get_contract_address};
    use vesu::data_model::{Amount, AmountDenomination, ModifyPositionParams};
    use vesu::pool::{IPoolDispatcher, IPoolDispatcherTrait};
    use vesu::test::setup_v2::deploy_with_args;
    use vesu::units::SCALE;
    use vesu_v2_periphery::migrate::{
        AmountSingletonV2, AmountType, IMigrateDispatcher, IMigrateDispatcherTrait, ISingletonV2Dispatcher,
        ISingletonV2DispatcherTrait, ITokenMigrationDispatcher, MigratePositionFromV1Params,
        MigratePositionFromV2Params, ModifyPositionParamsSingletonV2,
    };
    use super::{IStarkgateERC20Dispatcher, IStarkgateERC20DispatcherTrait};

    struct TestConfig {
        migrate: IMigrateDispatcher,
        eth: IERC20Dispatcher,
        legacy_usdc: IERC20Dispatcher,
        new_usdc: IERC20Dispatcher,
        user: ContractAddress,
        pool_1: IPoolDispatcher,
        pool_2: IPoolDispatcher,
        singleton_v2: ISingletonV2Dispatcher,
        pool_id: felt252,
    }

    fn setup() -> TestConfig {
        let eth = IERC20Dispatcher {
            contract_address: contract_address_const::<
                0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7,
            >(),
        };
        let legacy_usdc = IERC20Dispatcher {
            contract_address: contract_address_const::<
                0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8,
            >(),
        };
        let new_usdc = IERC20Dispatcher {
            contract_address: contract_address_const::<
                0x068f5c6a61780768455de69077e07e89787839bf8166decfbf92b645209c0fb8,
            >(),
        };

        let usdc_migrator = ITokenMigrationDispatcher {
            contract_address: contract_address_const::<
                0x06D4A1EC34c85b6129Ed433C46accfbE8B4B1225A3401C2767ea1060Ded208e7,
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

        let singleton_v2 = ISingletonV2Dispatcher {
            contract_address: contract_address_const::<
                0x000d8d6dfec4d33bfb6895de9f3852143a17c6f92fd2a21da3d6924d34870160,
            >(),
        };
        let pool_id = 0x4dc4f0ca6ea4961e4c8373265bfd5317678f4fe374d76f3fd7135f57763bf28;
        let pool_1 = IPoolDispatcher {
            contract_address: contract_address_const::<
                0x451fe483d5921a2919ddd81d0de6696669bccdacd859f72a4fba7656b97c3b5,
            >(),
        };
        let pool_2 = IPoolDispatcher {
            contract_address: contract_address_const::<
                0x03976cac265a12609934089004df458ea29c776d77da423c96dc761d09d24124,
            >(),
        };

        let migrate = IMigrateDispatcher {
            contract_address: deploy_with_args(
                "Migrate", array![singleton_v2.contract_address.into(), usdc_migrator.contract_address.into()],
            ),
        };

        let user = get_contract_address();
        let lp = contract_address_const::<'lp'>();
        let curator = pool_1.curator();

        let loaded = load(eth.contract_address, selector!("permitted_minter"), 1);
        let minter: ContractAddress = (*loaded[0]).try_into().unwrap();
        start_cheat_caller_address(eth.contract_address, minter);
        IStarkgateERC20Dispatcher { contract_address: eth.contract_address }.permissioned_mint(lp, 100 * SCALE);
        IStarkgateERC20Dispatcher { contract_address: eth.contract_address }.permissioned_mint(user, 100 * SCALE);
        stop_cheat_caller_address(eth.contract_address);

        let loaded = load(legacy_usdc.contract_address, selector!("permitted_minter"), 1);
        let minter: ContractAddress = (*loaded[0]).try_into().unwrap();
        start_cheat_caller_address(legacy_usdc.contract_address, minter);
        IStarkgateERC20Dispatcher { contract_address: legacy_usdc.contract_address }
            .permissioned_mint(user, 100000_000_000);
        IStarkgateERC20Dispatcher { contract_address: legacy_usdc.contract_address }
            .permissioned_mint(usdc_migrator.contract_address, 100000_000_000);
        IStarkgateERC20Dispatcher { contract_address: legacy_usdc.contract_address }
            .permissioned_mint(curator, 100000_000_000);
        stop_cheat_caller_address(legacy_usdc.contract_address);

        let loaded = load(new_usdc.contract_address, selector!("permitted_minter"), 1);
        let minter: ContractAddress = (*loaded[0]).try_into().unwrap();
        start_cheat_caller_address(new_usdc.contract_address, minter);
        IStarkgateERC20Dispatcher { contract_address: new_usdc.contract_address }
            .permissioned_mint(user, 100000_000_000);
        IStarkgateERC20Dispatcher { contract_address: new_usdc.contract_address }
            .permissioned_mint(usdc_migrator.contract_address, 100000_000_000);
        IStarkgateERC20Dispatcher { contract_address: new_usdc.contract_address }
            .permissioned_mint(curator, 100000_000_000);
        stop_cheat_caller_address(new_usdc.contract_address);

        start_cheat_caller_address(new_usdc.contract_address, curator);
        new_usdc.approve(pool_1.contract_address, 100000_000_000);
        stop_cheat_caller_address(new_usdc.contract_address);
        
        start_cheat_caller_address(legacy_usdc.contract_address, curator);
        legacy_usdc.approve(pool_1.contract_address, 100000_000_000);
        stop_cheat_caller_address(legacy_usdc.contract_address);
        
        start_cheat_caller_address(pool_1.contract_address, curator);
        pool_1.donate_to_reserve(new_usdc.contract_address, 100000_000_000);
        pool_1.donate_to_reserve(legacy_usdc.contract_address, 100000_000_000);
        stop_cheat_caller_address(pool_1.contract_address);

        let test_config = TestConfig {
            migrate, eth, legacy_usdc, new_usdc, user, pool_1, pool_2, singleton_v2, pool_id,
        };

        test_config
    }

    #[test]
    #[fork("Mainnet")]
    fn test_migrate_position_from_v1() {
        let TestConfig { pool_1, migrate, eth, new_usdc, user, singleton_v2, pool_id, .. } = setup();

        new_usdc.approve(singleton_v2.contract_address, 10000_000_000.into());

        singleton_v2
            .modify_position(
                ModifyPositionParamsSingletonV2 {
                    pool_id,
                    collateral_asset: new_usdc.contract_address,
                    debt_asset: eth.contract_address,
                    user,
                    collateral: AmountSingletonV2 {
                        amount_type: AmountType::Delta,
                        denomination: AmountDenomination::Assets,
                        value: I257Trait::new(10000_000_000, false),
                    },
                    debt: AmountSingletonV2 {
                        amount_type: AmountType::Delta,
                        denomination: AmountDenomination::Assets,
                        value: I257Trait::new(SCALE.into(), false),
                    },
                    data: ArrayTrait::new().span(),
                },
            );

        let (_, collateral, debt) = singleton_v2
            .position(pool_id, new_usdc.contract_address, eth.contract_address, user);
        assert!(collateral == 10000_000_000 - 1);
        assert!(debt == SCALE.into() + 1);

        singleton_v2.modify_delegation(pool_id, migrate.contract_address, true);
        pool_1.modify_delegation(migrate.contract_address, true);

        migrate
            .migrate_position_from_v1(
                MigratePositionFromV1Params {
                    from_pool_id: pool_id,
                    to_pool: pool_1.contract_address,
                    collateral_asset: new_usdc.contract_address,
                    debt_asset: eth.contract_address,
                    from_user: user,
                    to_user: user,
                    max_ltv_delta: SCALE / 1000,
                    collateral_to_migrate: 5000_000_000,
                    debt_to_migrate: SCALE / 2,
                },
            );

        let (_, collateral, debt) = singleton_v2
            .position(pool_id, new_usdc.contract_address, eth.contract_address, user);
        assert!(collateral == 5000_000_000 - 1);
        assert!(debt == SCALE / 2 + 2);

        let (_, collateral, debt) = pool_1.position(new_usdc.contract_address, eth.contract_address, user);
        assert!(collateral == 5000_000_000 - 1);
        assert!(debt == SCALE / 2 + 1);

        migrate
            .migrate_position_from_v1(
                MigratePositionFromV1Params {
                    from_pool_id: pool_id,
                    to_pool: pool_1.contract_address,
                    collateral_asset: new_usdc.contract_address,
                    debt_asset: eth.contract_address,
                    from_user: user,
                    to_user: user,
                    max_ltv_delta: SCALE / 1000,
                    collateral_to_migrate: 0,
                    debt_to_migrate: 0,
                },
            );

        let (_, collateral, debt) = singleton_v2
            .position(pool_id, new_usdc.contract_address, eth.contract_address, user);
        assert!(collateral == 0);
        assert!(debt == 0);

        let (_, collateral, debt) = pool_1.position(new_usdc.contract_address, eth.contract_address, user);
        assert!(collateral == 10000_000_000 - 2);
        assert!(debt == SCALE.into() + 4);
    }

    #[test]
    #[fork("Mainnet")]
    fn test_migrate_position_from_v1_legacy_usdc_to_new_usdc_collateral_asset() {
        let TestConfig { pool_1, migrate, eth, legacy_usdc, new_usdc, user, singleton_v2, pool_id, .. } = setup();

        legacy_usdc.approve(singleton_v2.contract_address, 10000_000_000.into());

        singleton_v2
            .modify_position(
                ModifyPositionParamsSingletonV2 {
                    pool_id,
                    collateral_asset: legacy_usdc.contract_address,
                    debt_asset: eth.contract_address,
                    user,
                    collateral: AmountSingletonV2 {
                        amount_type: AmountType::Delta,
                        denomination: AmountDenomination::Assets,
                        value: I257Trait::new(10000_000_000, false),
                    },
                    debt: AmountSingletonV2 {
                        amount_type: AmountType::Delta,
                        denomination: AmountDenomination::Assets,
                        value: I257Trait::new(SCALE.into(), false),
                    },
                    data: ArrayTrait::new().span(),
                },
            );

        let (_, collateral, debt) = singleton_v2
            .position(pool_id, legacy_usdc.contract_address, eth.contract_address, user);
        assert!(collateral == 10000_000_000 - 1);
        assert!(debt == SCALE.into() + 1);

        singleton_v2.modify_delegation(pool_id, migrate.contract_address, true);
        pool_1.modify_delegation(migrate.contract_address, true);

        migrate
            .migrate_position_from_v1(
                MigratePositionFromV1Params {
                    from_pool_id: pool_id,
                    to_pool: pool_1.contract_address,
                    collateral_asset: legacy_usdc.contract_address,
                    debt_asset: eth.contract_address,
                    from_user: user,
                    to_user: user,
                    max_ltv_delta: SCALE / 1000,
                    collateral_to_migrate: 5000_000_000,
                    debt_to_migrate: SCALE / 2,
                },
            );

        let (_, collateral, debt) = singleton_v2
            .position(pool_id, legacy_usdc.contract_address, eth.contract_address, user);
        assert!(collateral == 5000_000_000 - 1);
        assert!(debt == SCALE / 2 + 2);

        let (_, collateral, debt) = pool_1.position(new_usdc.contract_address, eth.contract_address, user);
        assert!(collateral == 5000_000_000 - 1);
        assert!(debt == SCALE / 2 + 1);

        migrate
            .migrate_position_from_v1(
                MigratePositionFromV1Params {
                    from_pool_id: pool_id,
                    to_pool: pool_1.contract_address,
                    collateral_asset: legacy_usdc.contract_address,
                    debt_asset: eth.contract_address,
                    from_user: user,
                    to_user: user,
                    max_ltv_delta: SCALE / 1000,
                    collateral_to_migrate: 0,
                    debt_to_migrate: 0,
                },
            );

        let (_, collateral, debt) = singleton_v2
            .position(pool_id, new_usdc.contract_address, eth.contract_address, user);
        assert!(collateral == 0);
        assert!(debt == 0);

        let (_, collateral, debt) = pool_1.position(new_usdc.contract_address, eth.contract_address, user);
        assert!(collateral == 10000_000_000 - 2);
        assert!(debt == SCALE.into() + 4);
    }

    #[test]
    #[fork("Mainnet")]
    fn test_migrate_position_from_v1_legacy_usdc_to_new_usdc_debt_asset() {
        let TestConfig { pool_1, migrate, eth, legacy_usdc, new_usdc, user, singleton_v2, pool_id, .. } = setup();

        eth.approve(singleton_v2.contract_address, SCALE.into());

        singleton_v2
            .modify_position(
                ModifyPositionParamsSingletonV2 {
                    pool_id,
                    collateral_asset: eth.contract_address,
                    debt_asset: legacy_usdc.contract_address,
                    user,
                    collateral: AmountSingletonV2 {
                        amount_type: AmountType::Delta,
                        denomination: AmountDenomination::Assets,
                        value: I257Trait::new(SCALE.into(), false),
                    },
                    debt: AmountSingletonV2 {
                        amount_type: AmountType::Delta,
                        denomination: AmountDenomination::Assets,
                        value: I257Trait::new(1000_000_000, false),
                    },
                    data: ArrayTrait::new().span(),
                },
            );

        let (_, collateral, debt) = singleton_v2
            .position(pool_id, eth.contract_address, legacy_usdc.contract_address, user);
        assert!(collateral == SCALE.into() - 1);
        assert!(debt == 1000_000_000 + 1);

        singleton_v2.modify_delegation(pool_id, migrate.contract_address, true);
        pool_1.modify_delegation(migrate.contract_address, true);

        migrate
            .migrate_position_from_v1(
                MigratePositionFromV1Params {
                    from_pool_id: pool_id,
                    to_pool: pool_1.contract_address,
                    collateral_asset: eth.contract_address,
                    debt_asset: legacy_usdc.contract_address,
                    from_user: user,
                    to_user: user,
                    max_ltv_delta: SCALE / 1000,
                    collateral_to_migrate: SCALE / 2,
                    debt_to_migrate: 500_000_000,
                },
            );

        let (_, collateral, debt) = singleton_v2
            .position(pool_id, eth.contract_address, legacy_usdc.contract_address, user);
        assert!(collateral == SCALE / 2 - 2);
        assert!(debt == 500_000_000 + 1);

        let (_, collateral, debt) = pool_1.position(eth.contract_address, new_usdc.contract_address, user);
        assert!(collateral == SCALE / 2 - 1);
        assert!(debt == 500_000_000 + 1);

        migrate
            .migrate_position_from_v1(
                MigratePositionFromV1Params {
                    from_pool_id: pool_id,
                    to_pool: pool_1.contract_address,
                    collateral_asset: eth.contract_address,
                    debt_asset: legacy_usdc.contract_address,
                    from_user: user,
                    to_user: user,
                    max_ltv_delta: SCALE / 1000,
                    collateral_to_migrate: 0,
                    debt_to_migrate: 0,
                },
            );

        let (_, collateral, debt) = singleton_v2
            .position(pool_id, eth.contract_address, legacy_usdc.contract_address, user);
        assert!(collateral == 0);
        assert!(debt == 0);

        let (_, collateral, debt) = pool_1.position(eth.contract_address, new_usdc.contract_address, user);
        assert!(collateral == SCALE - 4);
        assert!(debt == 1000_000_000 + 2);
    }

    #[test]
    #[fork("Mainnet")]
    fn test_migrate_position_from_v2_legacy_usdc_to_new_usdc_collateral_asset() {
        let TestConfig { pool_1, migrate, eth, legacy_usdc, new_usdc, user, .. } = setup();

        legacy_usdc.approve(pool_1.contract_address, 10000_000_000.into());

        pool_1
            .modify_position(
                ModifyPositionParams {
                    collateral_asset: legacy_usdc.contract_address,
                    debt_asset: eth.contract_address,
                    user,
                    collateral: Amount {
                        denomination: AmountDenomination::Assets, value: I257Trait::new(10000_000_000, false),
                    },
                    debt: Amount {
                        denomination: AmountDenomination::Assets, value: I257Trait::new(SCALE.into(), false),
                    },
                },
            );

        let (_, collateral, debt) = pool_1.position(legacy_usdc.contract_address, eth.contract_address, user);
        assert!(collateral == 10000_000_000 - 1);
        assert!(debt == SCALE.into() + 1);

        pool_1.modify_delegation(migrate.contract_address, true);

        migrate
            .migrate_position_from_v2(
                MigratePositionFromV2Params {
                    from_pool: pool_1.contract_address,
                    to_pool: pool_1.contract_address,
                    collateral_asset: legacy_usdc.contract_address,
                    debt_asset: eth.contract_address,
                    from_user: user,
                    to_user: user,
                    max_ltv_delta: SCALE / 1000,
                    collateral_to_migrate: 5000_000_000,
                    debt_to_migrate: SCALE / 2,
                },
            );

        let (_, collateral, debt) = pool_1.position(legacy_usdc.contract_address, eth.contract_address, user);
        assert!(collateral == 5000_000_000 - 1);
        assert!(debt == SCALE / 2 + 1);

        let (_, collateral, debt) = pool_1.position(new_usdc.contract_address, eth.contract_address, user);
        assert!(collateral == 5000_000_000 - 1);
        assert!(debt == SCALE / 2 + 1);

        migrate
            .migrate_position_from_v2(
                MigratePositionFromV2Params {
                    from_pool: pool_1.contract_address,
                    to_pool: pool_1.contract_address,
                    collateral_asset: legacy_usdc.contract_address,
                    debt_asset: eth.contract_address,
                    from_user: user,
                    to_user: user,
                    max_ltv_delta: SCALE / 1000,
                    collateral_to_migrate: 0,
                    debt_to_migrate: 0,
                },
            );

        let (_, collateral, debt) = pool_1.position(legacy_usdc.contract_address, eth.contract_address, user);
        assert!(collateral == 0);
        assert!(debt == 0);

        let (_, collateral, debt) = pool_1.position(new_usdc.contract_address, eth.contract_address, user);
        assert!(collateral == 10000_000_000 - 2);
        assert!(debt == SCALE.into() + 3);
    }

    #[test]
    #[fork("Mainnet")]
    fn test_migrate_position_from_v2_legacy_usdc_to_new_usdc_debt_asset() {
        let TestConfig { pool_1, migrate, eth, legacy_usdc, new_usdc, user, .. } = setup();

        eth.approve(pool_1.contract_address, SCALE.into());

        pool_1
            .modify_position(
                ModifyPositionParams {
                    collateral_asset: eth.contract_address,
                    debt_asset: legacy_usdc.contract_address,
                    user,
                    collateral: Amount {
                        denomination: AmountDenomination::Assets, value: I257Trait::new(SCALE.into(), false),
                    },
                    debt: Amount {
                        denomination: AmountDenomination::Assets, value: I257Trait::new(1000_000_000, false),
                    },
                },
            );

        let (_, collateral, debt) = pool_1.position(eth.contract_address, legacy_usdc.contract_address, user);
        assert!(collateral == SCALE.into() - 1);
        assert!(debt == 1000_000_000 + 1);

        pool_1.modify_delegation(migrate.contract_address, true);

        migrate
            .migrate_position_from_v2(
                MigratePositionFromV2Params {
                    from_pool: pool_1.contract_address,
                    to_pool: pool_1.contract_address,
                    collateral_asset: eth.contract_address,
                    debt_asset: legacy_usdc.contract_address,
                    from_user: user,
                    to_user: user,
                    max_ltv_delta: SCALE / 1000,
                    collateral_to_migrate: SCALE / 2,
                    debt_to_migrate: 500_000_000,
                },
            );

        let (_, collateral, debt) = pool_1.position(eth.contract_address, legacy_usdc.contract_address, user);
        assert!(collateral == SCALE / 2 - 1);
        assert!(debt == 500_000_000 + 1);

        let (_, collateral, debt) = pool_1.position(eth.contract_address, new_usdc.contract_address, user);
        assert!(collateral == SCALE / 2 - 1);
        assert!(debt == 500_000_000 + 1);

        migrate
            .migrate_position_from_v2(
                MigratePositionFromV2Params {
                    from_pool: pool_1.contract_address,
                    to_pool: pool_1.contract_address,
                    collateral_asset: eth.contract_address,
                    debt_asset: legacy_usdc.contract_address,
                    from_user: user,
                    to_user: user,
                    max_ltv_delta: SCALE / 1000,
                    collateral_to_migrate: 0,
                    debt_to_migrate: 0,
                },
            );

        let (_, collateral, debt) = pool_1.position(eth.contract_address, legacy_usdc.contract_address, user);
        assert!(collateral == 0);
        assert!(debt == 0);

        let (_, collateral, debt) = pool_1.position(eth.contract_address, new_usdc.contract_address, user);
        assert!(collateral == SCALE - 3);
        assert!(debt == 1000_000_000 + 2);
    }
}

