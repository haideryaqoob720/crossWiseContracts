// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

enum ActionType {
    None,
    Transfer,
    Swap,
    AddLiquidity,
    RemoveLiquidity,
    Deposit,
    Withdraw,
    CompoundAccumulated,
    VestAccumulated,
    HarvestAccumulated,
    StakeAccumulated,
    MassHarvestRewards,
    MassStakeRewards,
    MassCompoundRewards,
    WithdrawVest,
    UpdatePool,
    EmergencyWithdraw,
    SwitchCollectOption,
    HarvestRepay
}

uint256 constant NumberSessionTypes = 19;
uint256 constant CrssPoolAllocPercent = 25;
uint256 constant CompensationPoolAllocPercent = 2;

struct ActionParams {
    ActionType actionType;
    uint256 session;
    uint256 lastSession;
    bool isUserAction;
}

struct FeeRates {
    uint32 accountant;
}
struct FeeStores {
    address accountant;
    address dev;
}

struct PairSnapshot {
    address pair;
    address token0;
    address token1;
    uint256 reserve0;
    uint256 reserve1;
    uint8 decimal0;
    uint8 decimal1;
}

enum ListStatus {
    None,
    Cleared,
    Enlisted,
    Delisted
}

struct Pair {
    address token0;
    address token1;
    ListStatus status;
}

uint256 constant FeeMagnifierPower = 5;
uint256 constant FeeMagnifier = uint256(10)**FeeMagnifierPower;
uint256 constant SqaureMagnifier = FeeMagnifier * FeeMagnifier;
uint256 constant LiquiditySafety = 1e2;

// address constant BUSD = 0xeD24FC36d5Ee211Ea25A80239Fb8C4Cfd80f12Ee; // BSC testnet
// address constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56; // BSC mainnet
address constant BUSD = 0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82; // Hardhat chain, with my test script.
