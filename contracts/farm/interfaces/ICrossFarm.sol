// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

//import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./IMigratorChef.sol";
import "../xCrssToken.sol";

import "./ICrossFarmTypes.sol";
import "../../session/interfaces/IConstants.sol";
import "../../session/interfaces/INode.sol";

interface ICrossFarm {
    function updateMultiplier(uint256 multiplierNumber) external;

    function poolLength() external view returns (uint256);

    function add(
        uint256 _allocPoint,
        address _lpToken,
        bool _withUpdate,
        uint256 _depositFeeRate,
        uint256 _withdrawLock,
        bool autoCompound
    ) external returns (uint256 totalAllocPoint);

    function set(
        uint256 _pid,
        uint256 _allocPoint,
        bool _withUpdate,
        uint256 _depositFeeRate,
        uint256 _withdrawLock,
        bool autoCompound
    ) external returns (uint256 totalAllocPoint);

    event SetFeeParamsReferral(address crssReferral, uint256 referralCommissionRate);
    event SetFeeParamsOthers(address stakeholders, uint256 nonVestBurnRate, uint256 compoundFeeRate);

    event SetTrustedForwarder(address _trustedForwarder);
    event SwitchCollectOption(address indexed user, uint256 poolId, CollectOption option);
    event SetMigrator(address migrator);
    event ChangeReferer(address indexed user, address referrer);

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event WithdrawVest(address indexed user, uint256 indexed pid, uint256 amount);
    event VestAccumulated(address indexed user, uint256 indexed pid, uint256 crssAmount);
    event CompoundAccumulated(address indexed user, uint256 indexed pid, uint256 crssAmount, uint256 lpAmount);
    event HarvestAccumulated(address indexed user, uint256 indexed pid, uint256 crssAmount);
    event StakeAccumulated(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event MassHarvestRewards(address indexed user, uint256 crssAmount);
    event MassStakeRewards(address indexed user, uint256 crssAmount);
    // event MassCompoundRewards(address indexed user, uint256 crssAmount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function getMultiplier(uint256 _from, uint256 _to) external view returns (uint256);

    function massUpdatePools() external;

    function updatePool(uint256 _pid) external;

    function changeReferrer(address user, address referrer) external;

    function deposit(uint256 _pid, uint256 _amount) external returns (uint256 deposited);

    function withdraw(uint256 _pid, uint256 _amount) external returns (uint256 withdrawn);

    //function withdrawVest(uint256 _pid, uint256 _amount, UserRewardBehavior memory behavior) external returns (uint256 withdrawn);
    // function vestAccumulated(uint256 _pid, UserRewardBehavior memory behavior) external returns (uint256 vested);
    //function compoundAccumulated(uint256 _pid, UserRewardBehavior memory behavior) external returns (uint256 compounded);
    function harvestAccumulated(uint256 _pid) external returns (uint256 harvested);

    function stakeAccumulated(uint256 _pid) external returns (uint256 staked);

    function emergencyWithdraw(uint256 _pid) external;

    function switchCollectOption(uint256 _pid, CollectOption newOption) external;

    function massHarvestRewards() external returns (uint256 rewards);

    function massStakeRewards() external returns (uint256 rewards);

    // function massCompoundRewards() external;

    function periodicPatrol() external returns (bool done);
}
