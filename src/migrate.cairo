use alexandria_math::i257::i257;
use starknet::ContractAddress;

#[derive(PartialEq, Copy, Drop, Serde, Default)]
pub enum AmountTypeSingletonV2 {
    #[default]
    Delta,
    Target,
}

#[derive(PartialEq, Copy, Drop, Serde, Default)]
pub enum AmountDenominationSingletonV2 {
    #[default]
    Native,
    Assets,
}

#[derive(PartialEq, Copy, Drop, Serde, Default)]
pub struct AmountSingletonV2 {
    pub amount_type: AmountTypeSingletonV2,
    pub denomination: AmountDenominationSingletonV2,
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

#[derive(PartialEq, Copy, Drop, Serde)]
pub struct UpdatePositionResponse {
    pub collateral_delta: i257, // [asset scale]
    pub collateral_shares_delta: i257, // [SCALE]
    pub debt_delta: i257, // [asset scale]
    pub nominal_debt_delta: i257, // [SCALE]
    pub bad_debt: u256 // [asset scale]
}

#[derive(PartialEq, Copy, Drop, Serde)]
pub struct PositionSingletonV2 {
    pub collateral_shares: u256, // packed as u128 [SCALE] 
    pub nominal_debt: u256 // packed as u123 [SCALE]
}

#[starknet::interface]
pub trait ISingletonV2<TContractState> {
    fn position(
        ref self: TContractState,
        pool_id: felt252,
        collateral_asset: ContractAddress,
        debt_asset: ContractAddress,
        user: ContractAddress,
    ) -> (PositionSingletonV2, u256, u256);
    fn modify_position(ref self: TContractState, params: ModifyPositionParamsSingletonV2) -> UpdatePositionResponse;
}

#[derive(Serde, Drop, Clone)]
pub struct MigratePositionParams {
    pub from_pool_id: felt252,
    pub to_pool: ContractAddress,
    pub collateral_asset: ContractAddress,
    pub debt_asset: ContractAddress,
    pub from_user: ContractAddress,
    pub to_user: ContractAddress,
}

#[starknet::interface]
pub trait IMigrate<TContractState> {
    fn migrate_position(ref self: TContractState, params: MigratePositionParams);
}

#[starknet::contract]
pub mod Migrate {
    use alexandria_math::i257::I257Trait;
    use ekubo::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use vesu::data_model::{Amount, AmountDenomination, ModifyPositionParams};
    use vesu::pool::{IFlashLoanReceiver, IPoolDispatcher, IPoolDispatcherTrait};
    use vesu_v2_periphery::migrate::{
        AmountDenominationSingletonV2, AmountSingletonV2, AmountTypeSingletonV2, IMigrate, ISingletonV2Dispatcher,
        ISingletonV2DispatcherTrait, MigratePositionParams, ModifyPositionParamsSingletonV2, UpdatePositionResponse,
    };

    #[storage]
    struct Storage {
        singleton_v2: ISingletonV2Dispatcher,
        pool: ContractAddress,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {}

    #[constructor]
    fn constructor(ref self: ContractState, singleton_v2: ISingletonV2Dispatcher) {
        self.singleton_v2.write(singleton_v2);
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {}

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

            let MigratePositionParams {
                from_pool_id, to_pool, collateral_asset, debt_asset, from_user, to_user,
            } = Serde::deserialize(ref data).unwrap();

            let singleton_v2 = self.singleton_v2.read();
            let pool = IPoolDispatcher { contract_address: to_pool };

            assert!(
                IERC20Dispatcher { contract_address: debt_asset }.approve(pool.contract_address, amount),
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
                            collateral: AmountSingletonV2 {
                                amount_type: AmountTypeSingletonV2::Target,
                                denomination: AmountDenominationSingletonV2::Native,
                                value: I257Trait::new(0, false),
                            },
                            debt: AmountSingletonV2 {
                                amount_type: AmountTypeSingletonV2::Target,
                                denomination: AmountDenominationSingletonV2::Native,
                                value: I257Trait::new(0, false),
                            },
                            data: ArrayTrait::new().span(),
                        },
                    );

            assert!(debt_delta.abs() == amount, "debt-amount-mismatch");

            assert!(
                IERC20Dispatcher { contract_address: collateral_asset }
                    .approve(pool.contract_address, collateral_delta.abs()),
                "approve-failed",
            );

            pool
                .modify_position(
                    ModifyPositionParams {
                        collateral_asset,
                        debt_asset,
                        user: to_user,
                        collateral: Amount {
                            denomination: AmountDenomination::Assets,
                            value: I257Trait::new(collateral_delta.abs(), false),
                        },
                        debt: Amount {
                            denomination: AmountDenomination::Assets, value: I257Trait::new(debt_delta.abs(), false),
                        },
                    },
                );
        }
    }

    #[abi(embed_v0)]
    impl MigrateImpl of IMigrate<ContractState> {
        fn migrate_position(ref self: ContractState, params: MigratePositionParams) {
            let MigratePositionParams {
                from_pool_id, to_pool, collateral_asset, debt_asset, from_user, ..,
            } = params.clone();

            let singleton_v2 = self.singleton_v2.read();
            let pool = IPoolDispatcher { contract_address: to_pool };
            let (_, _, debt) = singleton_v2.position(from_pool_id, collateral_asset, debt_asset, from_user);

            let mut data: Array<felt252> = array![];
            Serde::serialize(@params, ref data);

            self.pool.write(to_pool);
            pool.flash_loan(get_contract_address(), debt_asset, debt, false, data.span());
            self.pool.write(0.try_into().unwrap());
        }
    }
}
