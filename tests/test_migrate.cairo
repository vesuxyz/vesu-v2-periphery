use starknet::ContractAddress;

#[starknet::interface]
trait IStarkgateERC20<TContractState> {
    fn permissioned_mint(ref self: TContractState, account: ContractAddress, amount: u256);
}

// test v1 to v2
// test v1 to v2 collateral asset is usdc.e
// test v1 to v2 debt asset is usdc.e

// test v2 to v2
// test v2 to v2 collateral asset is usdc.e
// test v2 to v2 debt asset is usdc.e

#[cfg(test)]
mod Test_3251219_Migrate {
    use alexandria_math::i257::I257Trait;
    use ekubo::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use snforge_std::{load, start_cheat_caller_address, stop_cheat_caller_address};
    #[feature("deprecated-starknet-consts")]
    use starknet::{ContractAddress, contract_address_const, get_contract_address};
    use vesu::data_model::{Amount, AmountDenomination, ModifyPositionParams};
    use vesu::pool::{IPoolDispatcher, IPoolDispatcherTrait};
    use vesu::test::setup_v2::deploy_with_args;
    use vesu::units::SCALE;
    use vesu_v2_periphery::migrate::{
        AmountSingletonV2, AmountType, IMigrateDispatcher, IMigrateDispatcherTrait, ISingletonV2Dispatcher,
        ISingletonV2DispatcherTrait, ITokenMigrationDispatcher, ITokenMigrationDispatcherTrait,
        MigratePositionFromV1Params, MigratePositionFromV2Params, ModifyPositionParamsSingletonV2,
    };
    use super::{IStarkgateERC20Dispatcher, IStarkgateERC20DispatcherTrait};

    struct TestConfig {
        migrate: IMigrateDispatcher,
        eth: IERC20Dispatcher,
        usdc: IERC20Dispatcher,
        usdc_e: IERC20Dispatcher,
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
        let usdc = IERC20Dispatcher {
            contract_address: contract_address_const::<
                0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8,
            >(),
        };
        let usdc_e = IERC20Dispatcher { contract_address: contract_address_const::<0x0>() };
        let usdc_migrator = ITokenMigrationDispatcher {
            contract_address: contract_address_const::<
                0x06D4A1EC34c85b6129Ed433C46accfbE8B4B1225A3401C2767ea1060Ded208e7,
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
                "Migrate",
                array![
                    singleton_v2.contract_address.into(),
                    usdc_e.contract_address.into(),
                    usdc.contract_address.into(),
                    usdc_migrator.contract_address.into(),
                ],
            ),
        };

        let user = get_contract_address();
        let lp = contract_address_const::<'lp'>();

        let loaded = load(eth.contract_address, selector!("permitted_minter"), 1);
        let minter: ContractAddress = (*loaded[0]).try_into().unwrap();
        start_cheat_caller_address(eth.contract_address, minter);
        IStarkgateERC20Dispatcher { contract_address: eth.contract_address }.permissioned_mint(lp, 100 * SCALE);
        stop_cheat_caller_address(eth.contract_address);

        let loaded = load(usdc.contract_address, selector!("permitted_minter"), 1);
        let minter: ContractAddress = (*loaded[0]).try_into().unwrap();
        start_cheat_caller_address(usdc.contract_address, minter);
        IStarkgateERC20Dispatcher { contract_address: usdc.contract_address }.permissioned_mint(user, 100000_000_000);
        stop_cheat_caller_address(usdc.contract_address);

        let test_config = TestConfig { migrate, eth, usdc, usdc_e, user, pool_1, pool_2, singleton_v2, pool_id };

        test_config
    }

    #[test]
    #[fork("Mainnet")]
    fn test_migrate_position_from_v1() {
        let TestConfig { pool_1, migrate, eth, usdc, user, singleton_v2, pool_id, .. } = setup();

        usdc.approve(singleton_v2.contract_address, 10000_000_000.into());

        singleton_v2
            .modify_position(
                ModifyPositionParamsSingletonV2 {
                    pool_id,
                    collateral_asset: usdc.contract_address,
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

        let (_, collateral, debt) = singleton_v2.position(pool_id, usdc.contract_address, eth.contract_address, user);
        assert!(collateral == 10000_000_000 - 1);
        assert!(debt == SCALE.into() + 1);

        singleton_v2.modify_delegation(pool_id, migrate.contract_address, true);
        pool_1.modify_delegation(migrate.contract_address, true);

        migrate
            .migrate_position_from_v1(
                MigratePositionFromV1Params {
                    from_pool_id: pool_id,
                    to_pool: pool_1.contract_address,
                    collateral_asset: usdc.contract_address,
                    debt_asset: eth.contract_address,
                    from_user: user,
                    to_user: user,
                    max_ltv_delta: SCALE / 1000,
                },
            );

        let (_, collateral, debt) = singleton_v2.position(pool_id, usdc.contract_address, eth.contract_address, user);
        assert!(collateral == 0);
        assert!(debt == 0);

        let (_, collateral, debt) = pool_1.position(usdc.contract_address, eth.contract_address, user);
        assert!(collateral == 10000_000_000 - 2);
        assert!(debt == SCALE.into() + 2);
    }

    // #[test]
    // #[fork("Mainnet")]
    // fn test_migrate_position_from_v2_usdc_e_to_usdc() {
    //     let TestConfig { pool_1, migrate, eth, usdc, usdc_e, user, .. } = setup();

    //     usdc_e.approve(pool_1.contract_address, 10000_000_000.into());

    //     pool_1
    //         .modify_position(
    //             ModifyPositionParams {
    //                 collateral_asset: usdc_e.contract_address,
    //                 debt_asset: eth.contract_address,
    //                 user,
    //                 collateral: Amount {
    //                     denomination: AmountDenomination::Assets, value: I257Trait::new(10000_000_000, false),
    //                 },
    //                 debt: Amount {
    //                     denomination: AmountDenomination::Assets, value: I257Trait::new(SCALE.into(), false),
    //                 },
    //             },
    //         );

    //     let (_, collateral, debt) = pool_1.position(usdc.contract_address, eth.contract_address, user);
    //     assert!(collateral == 10000_000_000 - 1);
    //     assert!(debt == SCALE.into() + 1);

    //     pool_1.modify_delegation(migrate.contract_address, true);

    //     migrate
    //         .migrate_position_from_v2(
    //             MigratePositionFromV2Params {
    //                 from_pool: pool_1.contract_address,
    //                 to_pool: pool_1.contract_address,
    //                 collateral_asset: usdc.contract_address,
    //                 debt_asset: eth.contract_address,
    //                 from_user: user,
    //                 to_user: user,
    //                 max_ltv_delta: SCALE / 1000,
    //             },
    //         );

    //     let (_, collateral, debt) = pool_1.position(usdc.contract_address, eth.contract_address, user);
    //     assert!(collateral == 0);
    //     assert!(debt == 0);

    //     let (_, collateral, debt) = pool_1.position(usdc.contract_address, eth.contract_address, user);
    //     assert!(collateral == 10000_000_000 - 2);
    //     assert!(debt == SCALE.into() + 2);
    // }
}

