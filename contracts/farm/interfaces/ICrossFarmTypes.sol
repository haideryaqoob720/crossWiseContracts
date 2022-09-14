// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

struct VestChunk {
    uint256 principal;
    uint256 withdrawn;
    uint256 startTime;
}

uint256 constant month = 30 days;

enum CollectOption {
    OffOff,
    OnOff,
    OnOn,
    OffOn
} // Compound_Off Vest_Off is the default.
enum RewardOption {
    FullProcess,
    IndividualOnly,
    NoProcess
}

struct DepositInfo {
    uint256 depositAt;
    uint256 amount;
}

struct UserInfo {
    uint256 amount;
    uint256 rewardDebt;
    uint256 debt1;
    uint256 debt2;
    uint256 accumulated;
    VestChunk[] vestList;
    DepositInfo[] depositList;
    CollectOption collectOption;
}

struct SubPool {
    uint256 bulk;
    uint256 accPerShare;
}
struct Struct_OnOff {
    uint256 sumAmount;
    SubPool Comp;
    SubPool PreComp;
}
struct Struct_OnOn {
    uint256 sumAmount;
    SubPool Comp;
    SubPool PreComp;
    SubPool Vest;
}
struct Struct_OffOn {
    uint256 sumAmount;
    SubPool Vest;
    SubPool Accum;
}
struct Struct_OffOff {
    uint256 sumAmount;
    SubPool Accum;
}
struct Struct_Accum {
    uint256 sumAmount;
    SubPool Pass;
}

struct PoolInfo {
    IERC20 lpToken;
    uint256 allocPoint;
    uint256 lastRewardBlock;
    uint256 accCrssPerShare;
    uint256 depositFeeRate;
    uint256 reward;
    uint256 withdrawLock;
    bool autoCompound;
    Struct_OnOff OnOff;
    Struct_OnOn OnOn;
    Struct_OffOn OffOn;
    Struct_OffOff OffOff;
}

struct FarmFeeParams {
    address crssReferral;
    address treasury;
    uint256 referralCommissionRate;
    uint256 maximumReferralCommisionRate;
    uint256 nonVestBurnRate;
    address stakeholders;
    uint256 compoundFeeRate;
}

struct UserRewardBehavior {
    // uint256 blockNo;
    uint256 pendingCrss;
    uint256 pendingPerBlock;
    // uint256 collectiveCrss;
    uint256 rewardPayroll;
    // uint256 thresholdBusdWei;
    // address crssBusd;
}

struct UserAssets {
    uint256 collectOption;
    uint256 deposit;
    // uint256 withdrawableDeposit;
    DepositInfo[] depositList;
    uint256 accRewards;
    // uint256 totalVest;
    uint256 totalMatureVest;
    // uint256 lpBalance;
    // uint256 crssBalance;
    // uint256 totalAccRewards;
}

struct UserState {
    UserRewardBehavior behavior;
    UserAssets assets;
}

struct SubPooledCrss {
    uint256 toVest;
    uint256 toAccumulate;
}

struct FarmParams {
    uint256 totalAllocPoint;
    uint256 crssPerBlock;
    uint256 bonusMultiplier;
}
