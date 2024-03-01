//! Test file for `src/withdrawal/withdrawal_vault.cairo`.

// *************************************************************************
//                                  IMPORTS
// *************************************************************************
// Core lib imports.
use integer::{u256_from_felt252};
use result::ResultTrait;
use starknet::{
    ContractAddress, get_caller_address, Felt252TryIntoContractAddress, contract_address_const,
    ClassHash,
};
use snforge_std::{declare, start_prank, stop_prank, start_mock_call, ContractClassTrait};
use traits::{TryInto, Into};

// Local imports.
use satoru::data::data_store::{IDataStoreDispatcher, IDataStoreDispatcherTrait};
use satoru::withdrawal::withdrawal_vault::{
    IWithdrawalVaultDispatcher, IWithdrawalVaultDispatcherTrait
};
use satoru::role::role_store::{IRoleStoreDispatcher, IRoleStoreDispatcherTrait};
use satoru::role::role;
use satoru::tests_lib;
use satoru::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};

// *********************************************************************************************
// *                                     TEST CONSTANTS                                        *
// *********************************************************************************************
/// Initial amount of ERC20 tokens minted to the withdrawal vault
const INITIAL_TOKENS_MINTED: felt252 = 1000;

// *********************************************************************************************
// *                                      TEST LOGIC                                           *
// *********************************************************************************************
#[test]
#[should_panic(expected: ('already_initialized',))]
fn given_already_intialized_when_initialize_then_fails() {
    let (_, _, role_store, data_store, withdrawal_vault, _) = setup();

    withdrawal_vault.initialize(data_store.contract_address, role_store.contract_address);

    teardown(data_store, withdrawal_vault);
}

#[test]
fn given_normal_conditions_when_transfer_out_then_works() {
    let (caller_address, receiver_address, _, data_store, withdrawal_vault, erc20) = setup();

    start_prank(withdrawal_vault.contract_address, caller_address);

    let amount_to_transfer: u256 = 100;
    withdrawal_vault.transfer_out(erc20.contract_address, receiver_address, amount_to_transfer);

    // check that the contract balance reduces
    let contract_balance = erc20.balance_of(withdrawal_vault.contract_address);
    let expected_balance: u256 = u256_from_felt252(
        INITIAL_TOKENS_MINTED - amount_to_transfer.try_into().expect('u256 into felt failed')
    );
    assert(contract_balance == expected_balance, 'transfer_out failed');

    // check that the balance of the receiver increases 
    let receiver_balance = erc20.balance_of(receiver_address);
    let expected_balance: u256 = amount_to_transfer.into();
    assert(receiver_balance == expected_balance, 'transfer_out failed');

    teardown(data_store, withdrawal_vault);
}

#[test]
#[should_panic(expected: ('u256_sub Overflow',))]
fn given_not_enough_token_when_transfer_out_then_fails() {
    let (_, receiver_address, _, data_store, withdrawal_vault, erc20) = setup();

    let amount_to_transfer: u256 = u256_from_felt252(INITIAL_TOKENS_MINTED + 1);
    withdrawal_vault.transfer_out(erc20.contract_address, receiver_address, amount_to_transfer);

    teardown(data_store, withdrawal_vault);
}

#[test]
#[should_panic(expected: ('unauthorized_access',))]
fn given_caller_has_no_controller_role_when_transfer_out_then_fails() {
    let (caller_address, receiver_address, _, data_store, withdrawal_vault, erc20) = setup();

    stop_prank(withdrawal_vault.contract_address);
    start_prank(withdrawal_vault.contract_address, receiver_address);
    withdrawal_vault.transfer_out(erc20.contract_address, caller_address, 100_u256);

    teardown(data_store, withdrawal_vault);
}

#[test]
#[should_panic(expected: ('self_transfer_not_supported',))]
fn given_receiver_is_contract_when_transfer_out_then_fails() {
    let (caller_address, receiver_address, _, data_store, withdrawal_vault, erc20) = setup();

    withdrawal_vault
        .transfer_out(erc20.contract_address, withdrawal_vault.contract_address, 100_u256);

    teardown(data_store, withdrawal_vault);
}

#[test]
fn given_normal_conditions_when_record_transfer_in_then_works() {
    let (_, _, _, data_store, withdrawal_vault, erc20) = setup();

    let initial_balance: u256 = u256_from_felt252(INITIAL_TOKENS_MINTED);
    let tokens_received: u256 = withdrawal_vault.record_transfer_in(erc20.contract_address);
    assert(tokens_received == initial_balance, 'should be initial balance');

    teardown(data_store, withdrawal_vault);
}

#[test]
fn given_more_balance_when_2nd_record_transfer_in_then_works() {
    let (_, _, _, data_store, withdrawal_vault, erc20) = setup();

    let initial_balance: u256 = u256_from_felt252(INITIAL_TOKENS_MINTED);
    let tokens_received: u256 = withdrawal_vault.record_transfer_in(erc20.contract_address);
    assert(tokens_received == initial_balance, 'should be initial balance');

    let tokens_transfered_in: u256 = 250;
    let mock_balance_with_more_tokens: u256 = (initial_balance + tokens_transfered_in).into();
    start_mock_call(erc20.contract_address, 'balance_of', mock_balance_with_more_tokens);

    let tokens_received: u256 = withdrawal_vault.record_transfer_in(erc20.contract_address);
    assert(tokens_received == tokens_transfered_in, 'incorrect received amount');

    teardown(data_store, withdrawal_vault);
}

#[test]
#[should_panic(expected: ('u256_sub Overflow',))]
fn given_less_balance_when_2nd_record_transfer_in_then_fails() {
    let (_, _, _, data_store, withdrawal_vault, erc20) = setup();

    let initial_balance: u256 = u256_from_felt252(INITIAL_TOKENS_MINTED);
    let tokens_received: u256 = withdrawal_vault.record_transfer_in(erc20.contract_address);
    assert(tokens_received == initial_balance, 'should be initial balance');

    let tokens_transfered_out: u256 = 250;
    let mock_balance_with_less_tokens: u256 = (initial_balance - tokens_transfered_out).into();
    start_mock_call(erc20.contract_address, 'balance_of', mock_balance_with_less_tokens);

    withdrawal_vault.record_transfer_in(erc20.contract_address);

    teardown(data_store, withdrawal_vault);
}

#[test]
#[should_panic(expected: ('unauthorized_access',))]
fn given_caller_is_not_controller_when_record_transfer_in_then_fails() {
    let (caller_address, _, role_store, data_store, withdrawal_vault, erc20) = setup();

    role_store.revoke_role(caller_address, role::CONTROLLER);
    withdrawal_vault.record_transfer_in(erc20.contract_address);

    teardown(data_store, withdrawal_vault);
}

#[test]
fn given_more_balance_when_sync_token_balance_then_works() {
    let (_, _, _, data_store, withdrawal_vault, erc20) = setup();

    let initial_balance: u256 = u256_from_felt252(INITIAL_TOKENS_MINTED);
    let tokens_received: u256 = withdrawal_vault.record_transfer_in(erc20.contract_address);
    assert(tokens_received == initial_balance, 'should be initial balance');

    let tokens_transfered_in: u256 = 250;
    let mock_balance_with_more_tokens: u256 = (initial_balance + tokens_transfered_in).into();
    start_mock_call(erc20.contract_address, 'balance_of', mock_balance_with_more_tokens);

    let next_balance: u256 = withdrawal_vault.sync_token_balance(erc20.contract_address);
    assert(next_balance.into() == mock_balance_with_more_tokens, 'incorrect next balance');

    teardown(data_store, withdrawal_vault);
}

#[test]
fn given_less_balance_when_sync_token_balance_then_works() {
    let (_, _, _, data_store, withdrawal_vault, erc20) = setup();

    let initial_balance: u256 = u256_from_felt252(INITIAL_TOKENS_MINTED);
    let tokens_received: u256 = withdrawal_vault.record_transfer_in(erc20.contract_address);
    assert(tokens_received == initial_balance, 'should be initial balance');

    let tokens_transfered_out: u256 = 250;
    let mock_balance_with_less_tokens: u256 = (initial_balance - tokens_transfered_out).into();
    start_mock_call(erc20.contract_address, 'balance_of', mock_balance_with_less_tokens);

    let next_balance: u256 = withdrawal_vault.sync_token_balance(erc20.contract_address);
    assert(next_balance.into() == mock_balance_with_less_tokens, 'incorrect next balance');

    teardown(data_store, withdrawal_vault);
}

// *********************************************************************************************
// *                                      SETUP                                                *
// *********************************************************************************************
/// Utility function to setup the test environment.
///
/// Complete statement to retrieve everything:
///     let (
///         caller_address, receiver_address,
///         role_store, data_store,
///         withdrawal_vault,
///         erc20
///     ) = setup();
///
/// # Returns
///
/// * `ContractAddress` - The address of the caller.
/// * `ContractAddress` - The address of the receiver.
/// * `IRoleStoreDispatcher` - The role store dispatcher.
/// * `IDataStoreDispatcher` - The data store dispatcher.
/// * `IWithdrawalVaultDispatcher` - The withdrawal vault dispatcher.
/// * `IERC20Dispatcher` - The ERC20 token dispatcher.
fn setup() -> (
    ContractAddress,
    ContractAddress,
    IRoleStoreDispatcher,
    IDataStoreDispatcher,
    IWithdrawalVaultDispatcher,
    IERC20Dispatcher
) {
    // get caller_address, role store and data_store from tests_lib::setup()
    let (caller_address, role_store, data_store) = tests_lib::setup();

    // get receiver_address
    let receiver_address: ContractAddress = 0x202.try_into().unwrap();

    // deploy withdrawal vault
    let withdrawal_vault_address = deploy_withdrawal_vault(
        data_store.contract_address, role_store.contract_address
    );
    let withdrawal_vault = IWithdrawalVaultDispatcher {
        contract_address: withdrawal_vault_address
    };

    // deploy erc20 token
    let erc20_contract_address = deploy_erc20_token(withdrawal_vault_address);
    let erc20 = IERC20Dispatcher { contract_address: erc20_contract_address };

    // start prank and give controller role to caller_address
    start_prank(withdrawal_vault.contract_address, caller_address);

    return (caller_address, receiver_address, role_store, data_store, withdrawal_vault, erc20);
}

/// Utility function to deploy a withdrawal vault.
///
/// # Arguments
///
/// * `data_store_address` - The address of the data store contract.
/// * `role_store_address` - The address of the role store contract.
///
/// # Returns
///
/// * `ContractAddress` - The address of the withdrawal vault.
fn deploy_withdrawal_vault(
    data_store_address: ContractAddress, role_store_address: ContractAddress
) -> ContractAddress {
    let withdrawal_vault_contract = declare('WithdrawalVault');
    let constructor_calldata = array![data_store_address.into(), role_store_address.into()];
    withdrawal_vault_contract.deploy(@constructor_calldata).unwrap()
}

/// Utility function to deploy an ERC20 token.
/// When deployed, 1000 tokens are minted to the withdrawal vault address.
///
/// # Arguments
///
/// * `withdrawal_vault_address` - The address of the withdrawal vault address.
///
/// # Returns
///
/// * `ContractAddress` - The address of the ERC20 token.
fn deploy_erc20_token(withdrawal_vault_address: ContractAddress) -> ContractAddress {
    let erc20_contract = declare('ERC20');
    let constructor_calldata = array![
        'satoru', 'STU', INITIAL_TOKENS_MINTED, 0, withdrawal_vault_address.into()
    ];
    erc20_contract.deploy(@constructor_calldata).unwrap()
}

// *********************************************************************************************
// *                                     TEARDOWN                                              *
// *********************************************************************************************
fn teardown(data_store: IDataStoreDispatcher, withdrawal_vault: IWithdrawalVaultDispatcher) {
    tests_lib::teardown(data_store.contract_address);
    stop_prank(withdrawal_vault.contract_address);
}
