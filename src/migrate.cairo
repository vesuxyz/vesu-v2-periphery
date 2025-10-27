use alexandria_math::i257::i257;
use starknet::ContractAddress;
use vesu::data_model::{AmountDenomination, AssetPrice, Position, UpdatePositionResponse};

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
    fn modify_delegation(ref self: TContractState, pool_id: felt252, delegatee: ContractAddress, delegation: bool);
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
    pub max_ltv_delta: u256,
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
    use vesu::units::SCALE;
    use vesu_v2_periphery::migrate::{
        AmountSingletonV2, AmountType, IExtensionDispatcher, IExtensionDispatcherTrait, IMigrate,
        ISingletonV2Dispatcher, ISingletonV2DispatcherTrait, MigratePositionParams, ModifyPositionParamsSingletonV2,
        UpdatePositionResponse,
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
                from_pool_id, to_pool, collateral_asset, debt_asset, from_user, to_user, max_ltv_delta,
            } = Serde::deserialize(ref data).unwrap();

            let singleton_v2 = self.singleton_v2.read();
            let pool = IPoolDispatcher { contract_address: to_pool };

            let (_, collateral_value, debt_value) = singleton_v2
                .check_collateralization(from_pool_id, collateral_asset, debt_asset, from_user);
            let ltv = debt_value * SCALE / collateral_value;

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
                            collateral: AmountSingletonV2 {
                                amount_type: AmountType::Target,
                                denomination: AmountDenomination::Native,
                                value: I257Trait::new(0, false),
                            },
                            debt: AmountSingletonV2 {
                                amount_type: AmountType::Target,
                                denomination: AmountDenomination::Native,
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

            let (_, collateral_value, debt_value) = pool
                .check_collateralization(collateral_asset, debt_asset, from_user);
            let new_ltv = debt_value * SCALE / collateral_value;
            assert!(ltv - max_ltv_delta <= new_ltv && new_ltv <= ltv + max_ltv_delta, "ltv-out-of-range");

            IERC20Dispatcher { contract_address: debt_asset }.approve(pool.contract_address, debt_delta.abs());
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
