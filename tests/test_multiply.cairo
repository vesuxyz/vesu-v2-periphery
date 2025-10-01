use starknet::ContractAddress;

#[starknet::interface]
trait IStarkgateERC20<TContractState> {
    fn permissioned_mint(ref self: TContractState, account: ContractAddress, amount: u256);
}

#[cfg(test)]
mod Test_896150_Multiply {
    use alexandria_math::i257::I257Trait;
    use core::num::traits::Zero;
    use ekubo::interfaces::core::ICoreDispatcher;
    use ekubo::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use ekubo::types::i129::i129;
    use ekubo::types::keys::PoolKey;
    use snforge_std::{
        load, start_cheat_caller_address, stop_cheat_caller_address,
    };
    #[feature("deprecated-starknet-consts")]
    use starknet::{ContractAddress, contract_address_const, get_contract_address};
    use vesu::data_model::{Amount, AmountDenomination, ModifyPositionParams};
    use vesu::pool::{IPoolDispatcher, IPoolDispatcherTrait};
    use vesu::test::setup_v2::deploy_with_args;
    use vesu::units::{SCALE, SCALE_128};
    use vesu_v2_periphery::multiply::{
        DecreaseLeverParams, IMultiplyDispatcher, IMultiplyDispatcherTrait, IncreaseLeverParams, ModifyLeverAction,
        ModifyLeverParams,
    };
    use vesu_v2_periphery::swap::{RouteNode, Swap, TokenAmount};
    use super::{IStarkgateERC20Dispatcher, IStarkgateERC20DispatcherTrait};

    const MIN_SQRT_RATIO_LIMIT: u256 = 18446748437148339061;
    const MAX_SQRT_RATIO_LIMIT: u256 = 6277100250585753475930931601400621808602321654880405518632;

    struct TestConfig {
        ekubo: ICoreDispatcher,
        pool: IPoolDispatcher,
        multiply: IMultiplyDispatcher,
        pool_key: PoolKey,
        pool_key_2: PoolKey,
        pool_key_3: PoolKey,
        pool_key_4: PoolKey,
        eth: IERC20Dispatcher,
        usdc: IERC20Dispatcher,
        usdt: IERC20Dispatcher,
        user: ContractAddress,
    }

    fn setup() -> TestConfig {
        let pool = IPoolDispatcher {
            contract_address: contract_address_const::<
                0x451fe483d5921a2919ddd81d0de6696669bccdacd859f72a4fba7656b97c3b5,
            >(),
        };

        let ekubo = ICoreDispatcher {
            contract_address: contract_address_const::<
                0x00000005dd3D2F4429AF886cD1a3b08289DBcEa99A294197E9eB43b0e0325b4b,
            >(),
        };

        let multiply = IMultiplyDispatcher {
            contract_address: deploy_with_args("Multiply", array![ekubo.contract_address.into()]),
        };

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
        let usdt = IERC20Dispatcher {
            contract_address: contract_address_const::<
                0x068f5c6a61780768455de69077e07e89787839bf8166decfbf92b645209c0fb8,
            >(),
        };
        let strk = IERC20Dispatcher {
            contract_address: contract_address_const::<
                0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d,
            >(),
        };

        let pool_key = PoolKey {
            token0: eth.contract_address,
            token1: usdc.contract_address,
            fee: 170141183460469235273462165868118016,
            tick_spacing: 1000,
            extension: contract_address_const::<0x0>(),
        };

        let pool_key_2 = PoolKey {
            token0: usdc.contract_address,
            token1: usdt.contract_address,
            fee: 8507159232437450533281168781287096,
            tick_spacing: 25,
            extension: contract_address_const::<0x0>(),
        };

        let pool_key_3 = PoolKey {
            token0: strk.contract_address,
            token1: usdc.contract_address,
            fee: 34028236692093847977029636859101184,
            tick_spacing: 200,
            extension: contract_address_const::<0x0>(),
        };

        let pool_key_4 = PoolKey {
            token0: strk.contract_address,
            token1: eth.contract_address,
            fee: 34028236692093847977029636859101184,
            tick_spacing: 200,
            extension: contract_address_const::<0x0>(),
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

        let loaded = load(usdt.contract_address, selector!("permitted_minter"), 1);
        let minter: ContractAddress = (*loaded[0]).try_into().unwrap();
        start_cheat_caller_address(usdt.contract_address, minter);
        IStarkgateERC20Dispatcher { contract_address: usdt.contract_address }.permissioned_mint(user, 100000_000_000);
        stop_cheat_caller_address(usdt.contract_address);

        // seed liquidity
        start_cheat_caller_address(eth.contract_address, lp);
        eth.approve(pool.contract_address, 100 * SCALE);
        stop_cheat_caller_address(eth.contract_address);
        start_cheat_caller_address(pool.contract_address, lp);
        pool
            .modify_position(
                ModifyPositionParams {
                    collateral_asset: eth.contract_address,
                    debt_asset: usdc.contract_address,
                    user: user,
                    collateral: Amount { denomination: AmountDenomination::Assets, value: (10 * SCALE).into() },
                    debt: Default::default(),
                },
            );
        stop_cheat_caller_address(pool.contract_address);

        let test_config = TestConfig {
            ekubo, multiply, pool_key, pool_key_2, pool_key_3, pool_key_4, eth, usdc, usdt, user, pool,
        };

        test_config
    }

    #[test]
    #[fork("Mainnet")]
    fn test_modify_lever_no_lever_swap() {
        let TestConfig { pool, multiply, eth, usdc, user, .. } = setup();

        let usdc_balance_before = usdc.balanceOf(user);

        usdc.approve(multiply.contract_address, 10000_000_000.into());
        pool.modify_delegation(multiply.contract_address, true);

        let increase_lever_params = IncreaseLeverParams {
            pool: pool.contract_address,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            add_margin: 10000_000_000_u128,
            margin_swap: array![],
            margin_swap_limit_amount: 0,
            lever_swap: array![],
            lever_swap_limit_amount: 0,
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone()),
        };

        multiply.modify_lever(modify_lever_params);

        let (_, collateral, _) = pool.position(usdc.contract_address, eth.contract_address, user);

        assert!(collateral == increase_lever_params.add_margin.into());
        assert!(usdc.balanceOf(user) == usdc_balance_before - increase_lever_params.add_margin.into());
    }

    #[test]
    #[fork("Mainnet")]
    fn test_modify_lever_exact_collateral_deposit() {
        let TestConfig { pool, multiply, pool_key, eth, usdc, user, .. } = setup();

        let usdc_balance_before = usdc.balanceOf(user);

        usdc.approve(multiply.contract_address, 10000_000_000.into());
        pool.modify_delegation(multiply.contract_address, true);

        let increase_lever_params = IncreaseLeverParams {
            pool: pool.contract_address,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            add_margin: 10000_000_000_u128,
            margin_swap: array![],
            margin_swap_limit_amount: 0,
            lever_swap: array![
                Swap {
                    route: array![RouteNode { pool_key, sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT, skip_ahead: 0 }],
                    token_amount: TokenAmount {
                        token: usdc.contract_address, amount: i129 { mag: 110_000_000.try_into().unwrap(), sign: true },
                    },
                },
            ],
            lever_swap_limit_amount: 44000000000000000 // 0.044 ETH
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone()),
        };

        multiply.modify_lever(modify_lever_params);

        let (_, collateral, _) = pool.position(usdc.contract_address, eth.contract_address, user);

        let y: @Swap = (increase_lever_params.lever_swap[0]);
        let x: u256 = (*y.token_amount.amount.mag).into();
        assert!(collateral == increase_lever_params.add_margin.into() + x);

        assert!(usdc.balanceOf(user) == usdc_balance_before - increase_lever_params.add_margin.into());
    }

    #[test]
    #[fork("Mainnet")]
    fn test_modify_lever_exact_debt_borrow() {
        let TestConfig { pool, multiply, pool_key, eth, usdc, user, .. } = setup();

        let usdc_balance_before = usdc.balanceOf(user);

        usdc.approve(multiply.contract_address, 10000_000_000.into());
        pool.modify_delegation(multiply.contract_address, true);

        let increase_lever_params = IncreaseLeverParams {
            pool: pool.contract_address,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            add_margin: 10000_000_000_u128,
            margin_swap: array![],
            margin_swap_limit_amount: 0,
            lever_swap: array![
                Swap {
                    route: array![RouteNode { pool_key, sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT, skip_ahead: 0 }],
                    token_amount: TokenAmount {
                        token: eth.contract_address,
                        amount: i129 { mag: 44000000000000000.try_into().unwrap(), sign: false },
                    },
                },
            ],
            lever_swap_limit_amount: 0,
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone()),
        };

        multiply.modify_lever(modify_lever_params);

        let (_, _, debt) = pool.position(usdc.contract_address, eth.contract_address, user);

        let y: @Swap = (increase_lever_params.lever_swap[0]);
        let x: u256 = (*y.token_amount.amount.mag).into();
        assert!(debt == x);

        assert!(usdc.balanceOf(user) == usdc_balance_before - increase_lever_params.add_margin.into());
    }

    #[test]
    #[fork("Mainnet")]
    fn test_modify_lever_margin_asset_swap_exact_out() {
        let TestConfig { pool, multiply, pool_key, pool_key_2, eth, usdc, usdt, user, .. } = setup();

        let usdt_balance_before = usdt.balanceOf(user);

        usdt.approve(multiply.contract_address, 10010_000_000.into());
        pool.modify_delegation(multiply.contract_address, true);

        let increase_lever_params = IncreaseLeverParams {
            pool: pool.contract_address,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            add_margin: 0_u128,
            margin_swap: array![
                Swap {
                    route: array![
                        RouteNode { pool_key: pool_key_2, sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT, skip_ahead: 0 },
                    ],
                    token_amount: TokenAmount {
                        token: usdc.contract_address,
                        amount: i129 { mag: 10000_000_000.try_into().unwrap(), sign: true },
                    },
                },
            ],
            margin_swap_limit_amount: (10010_000_000).try_into().unwrap(),
            lever_swap: array![
                Swap {
                    route: array![RouteNode { pool_key, sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT, skip_ahead: 0 }],
                    token_amount: TokenAmount {
                        token: usdc.contract_address, amount: i129 { mag: 110_000_000.try_into().unwrap(), sign: true },
                    },
                },
            ],
            lever_swap_limit_amount: 44000000000000000 // 0.044 ETH
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone()),
        };

        multiply.modify_lever(modify_lever_params);

        let (_, collateral, _) = pool.position(usdc.contract_address, eth.contract_address, user);

        let margin_swap: @Swap = (increase_lever_params.margin_swap[0]);
        let margin_swap_amount: u256 = (*margin_swap.token_amount.amount.mag).into();
        let lever_swap: @Swap = (increase_lever_params.lever_swap[0]);
        let lever_swap_amount: u256 = (*lever_swap.token_amount.amount.mag).into();
        assert!(collateral == margin_swap_amount + lever_swap_amount);

        assert!(usdt.balanceOf(user) < usdt_balance_before);
        assert!(usdt.balanceOf(user) != 0);
    }

    #[test]
    #[fork("Mainnet")]
    fn test_modify_lever_margin_asset_swap_exact_in() {
        let TestConfig { pool, multiply, pool_key, pool_key_2, eth, usdc, usdt, user, .. } = setup();

        let usdt_balance_before = usdt.balanceOf(user);

        usdt.approve(multiply.contract_address, 10010_000_000.into());
        pool.modify_delegation(multiply.contract_address, true);

        let increase_lever_params = IncreaseLeverParams {
            pool: pool.contract_address,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            add_margin: 0_u128,
            margin_swap: array![
                Swap {
                    route: array![
                        RouteNode { pool_key: pool_key_2, sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT, skip_ahead: 0 },
                    ],
                    token_amount: TokenAmount {
                        token: usdt.contract_address,
                        amount: i129 { mag: 10010_000_000.try_into().unwrap(), sign: false },
                    },
                },
            ],
            margin_swap_limit_amount: Zero::zero(),
            lever_swap: array![
                Swap {
                    route: array![RouteNode { pool_key, sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT, skip_ahead: 0 }],
                    token_amount: TokenAmount {
                        token: usdc.contract_address, amount: i129 { mag: 110_000_000.try_into().unwrap(), sign: true },
                    },
                },
            ],
            lever_swap_limit_amount: 44000000000000000 // 0.044 ETH
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone()),
        };

        multiply.modify_lever(modify_lever_params);

        let (_, collateral, _) = pool.position(usdc.contract_address, eth.contract_address, user);

        let margin_swap: @Swap = (increase_lever_params.margin_swap[0]);
        let margin_swap_amount: u256 = (*margin_swap.token_amount.amount.mag).into();
        let lever_swap: @Swap = (increase_lever_params.lever_swap[0]);
        let lever_swap_amount: u256 = (*lever_swap.token_amount.amount.mag).into();
        assert!(collateral == (margin_swap_amount + lever_swap_amount) + 3704524); // positive swap slippage

        assert!(usdt.balanceOf(user) < usdt_balance_before);
    }

    #[test]
    #[fork("Mainnet")]
    fn test_modify_lever_exact_collateral_withdrawal() {
        let TestConfig { pool, multiply, pool_key, eth, usdc, user, .. } = setup();

        usdc.approve(multiply.contract_address, 10000_000_000.into());
        pool.modify_delegation(multiply.contract_address, true);

        let increase_lever_params = IncreaseLeverParams {
            pool: pool.contract_address,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            add_margin: 10000_000_000_u128,
            margin_swap: array![],
            margin_swap_limit_amount: 0,
            lever_swap: array![
                Swap {
                    route: array![RouteNode { pool_key, sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT, skip_ahead: 0 }],
                    token_amount: TokenAmount {
                        token: usdc.contract_address, amount: i129 { mag: 300_000_000.try_into().unwrap(), sign: true },
                    },
                },
            ],
            lever_swap_limit_amount: 120000000000000000 // 0.12 ETH
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone()),
        };

        multiply.modify_lever(modify_lever_params);

        let (_, collateral_amount, _) = pool.position(usdc.contract_address, eth.contract_address, user);

        let usdc_balance_before = usdc.balanceOf(user);

        let decrease_lever_params = DecreaseLeverParams {
            pool: pool.contract_address,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            sub_margin: 0,
            recipient: user,
            lever_swap: array![
                Swap {
                    route: array![RouteNode { pool_key, sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT, skip_ahead: 0 }],
                    token_amount: TokenAmount {
                        token: usdc.contract_address,
                        amount: i129 { mag: (collateral_amount / 200).try_into().unwrap(), sign: false },
                    },
                },
            ],
            lever_swap_limit_amount: 0,
            lever_swap_weights: array![],
            withdraw_swap: array![],
            withdraw_swap_limit_amount: 0,
            withdraw_swap_weights: array![],
            close_position: false,
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::DecreaseLever(decrease_lever_params.clone()),
        };

        multiply.modify_lever(modify_lever_params);

        let (_, collateral, _) = pool.position(usdc.contract_address, eth.contract_address, user);

        let lever_swap: @Swap = (decrease_lever_params.lever_swap[0]);
        let lever_swap_amount: u256 = (*lever_swap.token_amount.amount.mag).into();
        assert!(collateral == collateral_amount - lever_swap_amount);

        assert!(usdc.balanceOf(user) == usdc_balance_before);
    }

    #[test]
    #[fork("Mainnet")]
    fn test_modify_lever_exact_collateral_withdrawal_no_lever_swap() {
        let TestConfig { pool, multiply, pool_key, eth, usdc, user, .. } = setup();

        usdc.approve(multiply.contract_address, 10000_000_000.into());
        pool.modify_delegation(multiply.contract_address, true);

        let increase_lever_params = IncreaseLeverParams {
            pool: pool.contract_address,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            add_margin: 10000_000_000_u128,
            margin_swap: array![],
            margin_swap_limit_amount: 0,
            lever_swap: array![
                Swap {
                    route: array![RouteNode { pool_key, sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT, skip_ahead: 0 }],
                    token_amount: TokenAmount {
                        token: usdc.contract_address, amount: i129 { mag: 300_000_000.try_into().unwrap(), sign: true },
                    },
                },
            ],
            lever_swap_limit_amount: 120000000000000000 // 0.12 ETH
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone()),
        };

        multiply.modify_lever(modify_lever_params);

        let (_, collateral_amount, _) = pool.position(usdc.contract_address, eth.contract_address, user);

        let usdc_balance_before = usdc.balanceOf(user);

        let decrease_lever_params = DecreaseLeverParams {
            pool: pool.contract_address,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            sub_margin: 1000_000_000_u128,
            recipient: user,
            lever_swap: array![],
            lever_swap_limit_amount: 0,
            lever_swap_weights: array![],
            withdraw_swap: array![],
            withdraw_swap_limit_amount: 0,
            withdraw_swap_weights: array![],
            close_position: false,
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::DecreaseLever(decrease_lever_params.clone()),
        };

        multiply.modify_lever(modify_lever_params);

        let (_, collateral, _) = pool.position(usdc.contract_address, eth.contract_address, user);

        assert!(collateral == collateral_amount - decrease_lever_params.sub_margin.into());
        assert!(usdc.balanceOf(user) > usdc_balance_before);
    }

    #[test]
    #[fork("Mainnet")]
    fn test_modify_lever_exact_debt_repay() {
        let TestConfig { pool, multiply, pool_key, eth, usdc, user, .. } = setup();

        usdc.approve(multiply.contract_address, 10000_000_000.into());
        pool.modify_delegation(multiply.contract_address, true);

        let increase_lever_params = IncreaseLeverParams {
            pool: pool.contract_address,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            add_margin: 10000_000_000_u128,
            margin_swap: array![],
            margin_swap_limit_amount: 0,
            lever_swap: array![
                Swap {
                    route: array![RouteNode { pool_key, sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT, skip_ahead: 0 }],
                    token_amount: TokenAmount {
                        token: usdc.contract_address, amount: i129 { mag: 110_000_000.try_into().unwrap(), sign: true },
                    },
                },
            ],
            lever_swap_limit_amount: 44000000000000000 // 0.044 ETH
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone()),
        };

        multiply.modify_lever(modify_lever_params);

        let usdc_balance_before = usdc.balanceOf(user);

        let (_, _, debt_amount) = pool.position(usdc.contract_address, eth.contract_address, user);

        let decrease_lever_params = DecreaseLeverParams {
            pool: pool.contract_address,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            sub_margin: 9999_000_000_u128,
            recipient: user,
            lever_swap: array![
                Swap {
                    route: array![RouteNode { pool_key, sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT, skip_ahead: 0 }],
                    token_amount: TokenAmount {
                        token: eth.contract_address, amount: i129 { mag: debt_amount.try_into().unwrap(), sign: true },
                    },
                },
            ],
            lever_swap_limit_amount: 121_000_000_u128,
            lever_swap_weights: array![],
            withdraw_swap: array![],
            withdraw_swap_limit_amount: 0,
            withdraw_swap_weights: array![],
            close_position: false,
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::DecreaseLever(decrease_lever_params.clone()),
        };

        multiply.modify_lever(modify_lever_params);

        let (_, _, debt) = pool.position(usdc.contract_address, eth.contract_address, user);

        let lever_swap: @Swap = (decrease_lever_params.lever_swap[0]);
        let lever_swap_amount: u256 = (*lever_swap.token_amount.amount.mag).into();
        assert!(debt == debt_amount - lever_swap_amount);

        assert!(usdc.balanceOf(user) == usdc_balance_before + decrease_lever_params.sub_margin.into());
    }

    #[test]
    #[fork("Mainnet")]
    fn test_modify_lever_withdraw_swap_exact_in() {
        let TestConfig { pool, multiply, pool_key, pool_key_2, eth, usdc, usdt, user, .. } = setup();

        usdc.approve(multiply.contract_address, 10000_000_000.into());
        pool.modify_delegation(multiply.contract_address, true);

        let increase_lever_params = IncreaseLeverParams {
            pool: pool.contract_address,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            add_margin: 10000_000_000_u128,
            margin_swap: array![],
            margin_swap_limit_amount: 0,
            lever_swap: array![
                Swap {
                    route: array![RouteNode { pool_key, sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT, skip_ahead: 0 }],
                    token_amount: TokenAmount {
                        token: usdc.contract_address, amount: i129 { mag: 300_000_000.try_into().unwrap(), sign: true },
                    },
                },
            ],
            lever_swap_limit_amount: 120000000000000000 // 0.12 ETH
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone()),
        };

        multiply.modify_lever(modify_lever_params);

        let (_, collateral_amount, _) = pool.position(usdc.contract_address, eth.contract_address, user);

        let usdc_balance_before = usdc.balanceOf(user);
        let usdt_balance_before = usdt.balanceOf(user);

        let decrease_lever_params = DecreaseLeverParams {
            pool: pool.contract_address,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            sub_margin: 0_u128,
            recipient: user,
            lever_swap: array![
                Swap {
                    route: array![RouteNode { pool_key, sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT, skip_ahead: 0 }],
                    token_amount: TokenAmount {
                        token: usdc.contract_address,
                        amount: i129 { mag: (collateral_amount / 200).try_into().unwrap(), sign: false },
                    },
                },
            ],
            lever_swap_limit_amount: 0,
            lever_swap_weights: array![],
            withdraw_swap: array![
                Swap {
                    route: array![
                        RouteNode { pool_key: pool_key_2, sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT, skip_ahead: 0 },
                    ],
                    token_amount: TokenAmount { token: usdc.contract_address, amount: Zero::zero() },
                },
            ],
            withdraw_swap_limit_amount: 0,
            withdraw_swap_weights: array![SCALE_128],
            close_position: false,
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::DecreaseLever(decrease_lever_params.clone()),
        };

        multiply.modify_lever(modify_lever_params);

        let (_, collateral, _) = pool.position(usdc.contract_address, eth.contract_address, user);

        let lever_swap: @Swap = (decrease_lever_params.lever_swap[0]);
        let lever_swap_amount: u256 = (*lever_swap.token_amount.amount.mag).into();
        assert!(collateral == collateral_amount - lever_swap_amount);

        assert!(usdc.balanceOf(user) == usdc_balance_before);
        assert!(usdt.balanceOf(user) >= usdt_balance_before);
        assert!(usdt.balanceOf(user) <= usdt_balance_before + decrease_lever_params.sub_margin.into());
    }

    #[test]
    #[should_panic(expected: "weight-sum-not-1")]
    #[fork("Mainnet")]
    fn test_modify_lever_close_weight_sum_not_1() {
        let TestConfig { pool, multiply, pool_key, eth, usdc, user, .. } = setup();

        usdc.approve(multiply.contract_address, 10000_000_000.into());
        pool.modify_delegation(multiply.contract_address, true);

        let increase_lever_params = IncreaseLeverParams {
            pool: pool.contract_address,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            add_margin: 10000_000_000_u128,
            margin_swap: array![],
            margin_swap_limit_amount: 0,
            lever_swap: array![
                Swap {
                    route: array![RouteNode { pool_key, sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT, skip_ahead: 0 }],
                    token_amount: TokenAmount {
                        token: usdc.contract_address, amount: i129 { mag: 110_000_000.try_into().unwrap(), sign: true },
                    },
                },
            ],
            lever_swap_limit_amount: 44000000000000000 // 0.044 ETH
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone()),
        };

        multiply.modify_lever(modify_lever_params);

        let decrease_lever_params = DecreaseLeverParams {
            pool: pool.contract_address,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            sub_margin: 0,
            recipient: user,
            lever_swap: array![
                Swap {
                    route: array![RouteNode { pool_key, sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT, skip_ahead: 0 }],
                    token_amount: TokenAmount { token: eth.contract_address, amount: Zero::zero() },
                },
            ],
            lever_swap_limit_amount: 121_000_000_u128,
            lever_swap_weights: array![SCALE_128 * 2],
            withdraw_swap: array![],
            withdraw_swap_limit_amount: 0,
            withdraw_swap_weights: array![],
            close_position: true,
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::DecreaseLever(decrease_lever_params.clone()),
        };

        multiply.modify_lever(modify_lever_params);
    }

    #[test]
    #[fork("Mainnet")]
    fn test_modify_lever_close() {
        let TestConfig { pool, multiply, pool_key, eth, usdc, user, .. } = setup();

        usdc.approve(multiply.contract_address, 10000_000_000.into());
        pool.modify_delegation(multiply.contract_address, true);

        let increase_lever_params = IncreaseLeverParams {
            pool: pool.contract_address,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            add_margin: 10000_000_000_u128,
            margin_swap: array![],
            margin_swap_limit_amount: 0,
            lever_swap: array![
                Swap {
                    route: array![RouteNode { pool_key, sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT, skip_ahead: 0 }],
                    token_amount: TokenAmount {
                        token: usdc.contract_address, amount: i129 { mag: 110_000_000.try_into().unwrap(), sign: true },
                    },
                },
            ],
            lever_swap_limit_amount: 44000000000000000 // 0.044 ETH
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone()),
        };

        multiply.modify_lever(modify_lever_params);

        let user_balance_before = usdc.balanceOf(user);

        let decrease_lever_params = DecreaseLeverParams {
            pool: pool.contract_address,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            sub_margin: 0,
            recipient: user,
            lever_swap: array![
                Swap {
                    route: array![RouteNode { pool_key, sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT, skip_ahead: 0 }],
                    token_amount: TokenAmount { token: eth.contract_address, amount: Zero::zero() },
                },
            ],
            lever_swap_limit_amount: 121_000_000_u128,
            lever_swap_weights: array![SCALE_128],
            withdraw_swap: array![],
            withdraw_swap_limit_amount: 0,
            withdraw_swap_weights: array![],
            close_position: true,
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::DecreaseLever(decrease_lever_params.clone()),
        };

        let (_, collateral, debt) = pool.position(usdc.contract_address, eth.contract_address, user);

        let modify_lever_response = multiply.modify_lever(modify_lever_params);

        assert!(modify_lever_response.collateral_delta == I257Trait::new(collateral, true));
        assert!(modify_lever_response.debt_delta == I257Trait::new(debt, true));
        assert!(modify_lever_response.margin_delta <= I257Trait::new(9999_000_000, true));

        let (position, collateral, debt) = pool.position(usdc.contract_address, eth.contract_address, user);
        assert!(position.collateral_shares == 0);
        assert!(position.nominal_debt == 0);
        assert!(collateral == 0);
        assert!(debt == 0);

        assert!(usdc.balanceOf(user) >= user_balance_before + decrease_lever_params.sub_margin.into());
    }

    // https://quoter-mainnet-api.ekubo.org/-110000000/0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8/0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7?max_splits=0&max_hops=0

    #[test]
    #[fork("Mainnet")]
    fn test_modify_lever_multi_swap() {
        let TestConfig { pool, multiply, eth, usdc, user, .. } = setup();

        let usdc_balance_before = usdc.balanceOf(user);

        usdc.approve(multiply.contract_address, 10000_000_000.into());
        pool.modify_delegation(multiply.contract_address, true);

        let increase_lever_params = IncreaseLeverParams {
            pool: pool.contract_address,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            add_margin: 10000_000_000_u128,
            margin_swap: array![],
            margin_swap_limit_amount: 0,
            lever_swap: array![
                Swap {
                    route: array![
                        RouteNode {
                            pool_key: PoolKey {
                                token0: contract_address_const::<
                                    0x4daa17763b286d1e59b97c283c0b8c949994c361e426a28f743c67bdfe9a32f,
                                >(),
                                token1: contract_address_const::<
                                    0x53c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8,
                                >(),
                                fee: 0x20c49ba5e353f80000000000000000,
                                tick_spacing: 1000,
                                extension: contract_address_const::<0x0>(),
                            },
                            sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT,
                            skip_ahead: 0,
                        },
                        RouteNode {
                            pool_key: PoolKey {
                                token0: contract_address_const::<
                                    0x3fe2b97c1fd336e750087d68b9b867997fd64a2661ff3ca5a7c771641e8e7ac,
                                >(),
                                token1: contract_address_const::<
                                    0x4daa17763b286d1e59b97c283c0b8c949994c361e426a28f743c67bdfe9a32f,
                                >(),
                                fee: 0x68db8bac710cb4000000000000000,
                                tick_spacing: 200,
                                extension: contract_address_const::<0x0>(),
                            },
                            sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT,
                            skip_ahead: 0,
                        },
                        RouteNode {
                            pool_key: PoolKey {
                                token0: contract_address_const::<
                                    0x3fe2b97c1fd336e750087d68b9b867997fd64a2661ff3ca5a7c771641e8e7ac,
                                >(),
                                token1: contract_address_const::<
                                    0x49d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7,
                                >(),
                                fee: 0x20c49ba5e353f80000000000000000,
                                tick_spacing: 1000,
                                extension: contract_address_const::<0x0>(),
                            },
                            sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT,
                            skip_ahead: 0,
                        },
                    ],
                    token_amount: TokenAmount {
                        token: usdc.contract_address, amount: i129 { mag: 110_000_000.try_into().unwrap(), sign: true },
                    },
                },
            ],
            lever_swap_limit_amount: 44000000000000000 // 0.044 ETH
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone()),
        };

        let modify_lever_response = multiply.modify_lever(modify_lever_params);
        assert!(modify_lever_response.collateral_delta == I257Trait::new(10110_000_000, false));
        assert!(modify_lever_response.debt_delta > I257Trait::new(0, false));
        assert!(modify_lever_response.margin_delta == I257Trait::new(10000_000_000, false));

        let (_, collateral, _) = pool.position(usdc.contract_address, eth.contract_address, user);

        let lever_swap: @Swap = (increase_lever_params.lever_swap[0]);
        let lever_swap_amount: u256 = (*lever_swap.token_amount.amount.mag).into();
        assert!(collateral == increase_lever_params.add_margin.into() + lever_swap_amount);

        assert!(usdc.balanceOf(user) == usdc_balance_before - increase_lever_params.add_margin.into());
    }

    #[test]
    #[fork("Mainnet")]
    fn test_modify_lever_split_multi_swap() {
        let TestConfig { pool, multiply, eth, usdc, user, .. } = setup();

        let usdc_balance_before = usdc.balanceOf(user);

        usdc.approve(multiply.contract_address, 10000_000_000.into());
        pool.modify_delegation(multiply.contract_address, true);

        let increase_lever_params = IncreaseLeverParams {
            pool: pool.contract_address,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            add_margin: 10000_000_000_u128,
            margin_swap: array![],
            margin_swap_limit_amount: 0,
            lever_swap: array![
                Swap {
                    route: array![
                        RouteNode {
                            pool_key: PoolKey {
                                token0: eth.contract_address,
                                token1: usdc.contract_address,
                                fee: 0x20c49ba5e353f80000000000000000,
                                tick_spacing: 1000,
                                extension: contract_address_const::<0x0>(),
                            },
                            sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT,
                            skip_ahead: 0,
                        },
                    ],
                    token_amount: TokenAmount {
                        token: usdc.contract_address, amount: i129 { mag: 103125000.try_into().unwrap(), sign: true },
                    },
                },
                Swap {
                    route: array![
                        RouteNode {
                            pool_key: PoolKey {
                                token0: contract_address_const::<
                                    0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d,
                                >(),
                                token1: usdc.contract_address,
                                fee: 0xc49ba5e353f7d00000000000000000,
                                tick_spacing: 354892,
                                extension: contract_address_const::<
                                    0x43e4f09c32d13d43a880e85f69f7de93ceda62d6cf2581a582c6db635548fdc,
                                >(),
                            },
                            sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT,
                            skip_ahead: 0,
                        },
                        RouteNode {
                            pool_key: PoolKey {
                                token0: contract_address_const::<
                                    0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d,
                                >(),
                                token1: eth.contract_address,
                                fee: 0x20c49ba5e353f80000000000000000,
                                tick_spacing: 354892,
                                extension: contract_address_const::<
                                    0x43e4f09c32d13d43a880e85f69f7de93ceda62d6cf2581a582c6db635548fdc,
                                >(),
                            },
                            sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT,
                            skip_ahead: 0,
                        },
                    ],
                    token_amount: TokenAmount {
                        token: usdc.contract_address, amount: i129 { mag: 6875000.try_into().unwrap(), sign: true },
                    },
                },
            ],
            lever_swap_limit_amount: 44000000000000000 // 0.044 ETH
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone()),
        };

        let modify_lever_response = multiply.modify_lever(modify_lever_params);
        assert!(modify_lever_response.collateral_delta == I257Trait::new(10110_000_000, false));
        assert!(modify_lever_response.debt_delta > I257Trait::new(0, false));
        assert!(modify_lever_response.margin_delta == I257Trait::new(10000_000_000, false));

        let (_, collateral, _) = pool.position(usdc.contract_address, eth.contract_address, user);

        let lever_swap_1: @Swap = (increase_lever_params.lever_swap[0]);
        let lever_swap_amount_1: u256 = (*lever_swap_1.token_amount.amount.mag).into();
        let lever_swap_2: @Swap = (increase_lever_params.lever_swap[1]);
        let lever_swap_amount_2: u256 = (*lever_swap_2.token_amount.amount.mag).into();
        assert!(lever_swap_amount_1 + lever_swap_amount_2 == 110_000_000);
        assert!(collateral == increase_lever_params.add_margin.into() + lever_swap_amount_1 + lever_swap_amount_2);

        assert!(usdc.balanceOf(user) == usdc_balance_before - increase_lever_params.add_margin.into());
    }

    #[test]
    #[available_gas(20000000)]
    #[should_panic(expected: "limit-amount-exceeded")]
    #[fork("Mainnet")]
    fn test_modify_lever_multi_swap_limit_amount_exceeded() {
        let TestConfig { pool, multiply, eth, usdc, user, .. } = setup();

        usdc.approve(multiply.contract_address, 10000_000_000.into());
        pool.modify_delegation(multiply.contract_address, true);

        let increase_lever_params = IncreaseLeverParams {
            pool: pool.contract_address,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            add_margin: 10000_000_000_u128,
            margin_swap: array![],
            margin_swap_limit_amount: 0,
            lever_swap: array![
                Swap {
                    route: array![
                        RouteNode {
                            pool_key: PoolKey {
                                token0: contract_address_const::<
                                    0x4daa17763b286d1e59b97c283c0b8c949994c361e426a28f743c67bdfe9a32f,
                                >(),
                                token1: contract_address_const::<
                                    0x53c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8,
                                >(),
                                fee: 0x20c49ba5e353f80000000000000000,
                                tick_spacing: 1000,
                                extension: contract_address_const::<0x0>(),
                            },
                            sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT,
                            skip_ahead: 0,
                        },
                        RouteNode {
                            pool_key: PoolKey {
                                token0: contract_address_const::<
                                    0x3fe2b97c1fd336e750087d68b9b867997fd64a2661ff3ca5a7c771641e8e7ac,
                                >(),
                                token1: contract_address_const::<
                                    0x4daa17763b286d1e59b97c283c0b8c949994c361e426a28f743c67bdfe9a32f,
                                >(),
                                fee: 0x68db8bac710cb4000000000000000,
                                tick_spacing: 200,
                                extension: contract_address_const::<0x0>(),
                            },
                            sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT,
                            skip_ahead: 0,
                        },
                        RouteNode {
                            pool_key: PoolKey {
                                token0: contract_address_const::<
                                    0x3fe2b97c1fd336e750087d68b9b867997fd64a2661ff3ca5a7c771641e8e7ac,
                                >(),
                                token1: contract_address_const::<
                                    0x49d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7,
                                >(),
                                fee: 0x20c49ba5e353f80000000000000000,
                                tick_spacing: 1000,
                                extension: contract_address_const::<0x0>(),
                            },
                            sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT,
                            skip_ahead: 0,
                        },
                    ],
                    token_amount: TokenAmount {
                        token: usdc.contract_address, amount: i129 { mag: 110_000_000.try_into().unwrap(), sign: true },
                    },
                },
            ],
            lever_swap_limit_amount: 14000000000000000 // 0.044 ETH
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone()),
        };

        multiply.modify_lever(modify_lever_params);
    }

    #[test]
    #[available_gas(20000000)]
    #[fork("Mainnet")]
    fn test_modify_lever_close_multi_swap() {
        let TestConfig { pool, multiply, pool_key, eth, usdc, user, .. } = setup();

        usdc.approve(multiply.contract_address, 10000_000_000.into());
        pool.modify_delegation(multiply.contract_address, true);

        let increase_lever_params = IncreaseLeverParams {
            pool: pool.contract_address,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            add_margin: 10000_000_000_u128,
            margin_swap: array![],
            margin_swap_limit_amount: 0,
            lever_swap: array![
                Swap {
                    route: array![RouteNode { pool_key, sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT, skip_ahead: 0 }],
                    token_amount: TokenAmount {
                        token: usdc.contract_address, amount: i129 { mag: 110_000_000.try_into().unwrap(), sign: true },
                    },
                },
            ],
            lever_swap_limit_amount: 35000000000000000 // 0.035 ETH
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone()),
        };

        multiply.modify_lever(modify_lever_params);

        let user_balance_before = usdc.balanceOf(user);

        let decrease_lever_params = DecreaseLeverParams {
            pool: pool.contract_address,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            sub_margin: 0,
            recipient: user,
            lever_swap: array![
                Swap {
                    route: array![
                        RouteNode {
                            pool_key: PoolKey {
                                token0: contract_address_const::<
                                    0x49d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7,
                                >(),
                                token1: contract_address_const::<
                                    0x53c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8,
                                >(),
                                fee: 0x20c49ba5e353f80000000000000000,
                                tick_spacing: 1000,
                                extension: contract_address_const::<0x0>(),
                            },
                            sqrt_ratio_limit: 0x4c835c3c828894f3ddac2085f1211,
                            skip_ahead: 0,
                        },
                    ],
                    token_amount: TokenAmount { token: eth.contract_address, amount: Zero::zero() },
                },
                Swap {
                    route: array![
                        RouteNode {
                            pool_key: PoolKey {
                                token0: contract_address_const::<
                                    0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d,
                                >(),
                                token1: contract_address_const::<
                                    0x49d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7,
                                >(),
                                fee: 0xc49ba5e353f7d00000000000000000,
                                tick_spacing: 5982,
                                extension: contract_address_const::<0x0>(),
                            },
                            sqrt_ratio_limit: 0xb0dd63cf9d7e17d384023dfb4aeb13,
                            skip_ahead: 0,
                        },
                        RouteNode {
                            pool_key: PoolKey {
                                token0: contract_address_const::<
                                    0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d,
                                >(),
                                token1: contract_address_const::<
                                    0x75afe6402ad5a5c20dd25e10ec3b3986acaa647b77e4ae24b0cbc9a54a27a87,
                                >(),
                                fee: 0xc49ba5e353f7d00000000000000000,
                                tick_spacing: 354892,
                                extension: contract_address_const::<
                                    0x43e4f09c32d13d43a880e85f69f7de93ceda62d6cf2581a582c6db635548fdc,
                                >(),
                            },
                            sqrt_ratio_limit: 0xfffffc080ed7b4556f3528fe26840249f4b191ef6dff7928,
                            skip_ahead: 0,
                        },
                        RouteNode {
                            pool_key: PoolKey {
                                token0: contract_address_const::<
                                    0x53c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8,
                                >(),
                                token1: contract_address_const::<
                                    0x75afe6402ad5a5c20dd25e10ec3b3986acaa647b77e4ae24b0cbc9a54a27a87,
                                >(),
                                fee: 0x0,
                                tick_spacing: 354892,
                                extension: contract_address_const::<
                                    0x5e470ff654d834983a46b8f29dfa99963d5044b993cb7b9c92243a69dab38f,
                                >(),
                            },
                            sqrt_ratio_limit: 0x1000003f7f1380b75,
                            skip_ahead: 0,
                        },
                    ],
                    token_amount: TokenAmount { token: eth.contract_address, amount: Zero::zero() },
                },
            ],
            lever_swap_limit_amount: 110_000_000
                + (110_000_000 * 1 / 100), // 1% slippage of the original levered amount
            lever_swap_weights: array![SCALE_128 / 2, SCALE_128 / 2],
            withdraw_swap: array![],
            withdraw_swap_limit_amount: 0,
            withdraw_swap_weights: array![],
            close_position: true,
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::DecreaseLever(decrease_lever_params.clone()),
        };

        let (_, collateral, debt) = pool.position(usdc.contract_address, eth.contract_address, user);
        println!("collateral: {}", collateral);
        println!("debt:       {}", debt);

        let modify_lever_response = multiply.modify_lever(modify_lever_params);

        assert!(modify_lever_response.collateral_delta == I257Trait::new(collateral, true));
        assert!(modify_lever_response.debt_delta == I257Trait::new(debt, true));
        assert!(modify_lever_response.margin_delta <= I257Trait::new(9999_000_000, true));

        let (position, collateral, debt) = pool.position(usdc.contract_address, eth.contract_address, user);
        assert!(position.collateral_shares == 0);
        assert!(position.nominal_debt == 0);
        assert!(collateral == 0);
        assert!(debt == 0);

        assert!(usdc.balanceOf(user) >= user_balance_before + decrease_lever_params.sub_margin.into());
    }
}

