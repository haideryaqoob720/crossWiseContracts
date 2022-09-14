// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/ICrossFarmTypes.sol";
import "./interfaces/ICrossFarm.sol";

import "../session/SessionManager.sol";
import "../session/Node.sol";
import "../libraries/WireLibrary.sol";
import "../periphery/interfaces/IMaker.sol";
import "../periphery/interfaces/ITaker.sol";
import "./interfaces/ICrssToken.sol";
import "./interfaces/IXCrssToken.sol";
import "./interfaces/ICrssReferral.sol";
import "./BaseRelayRecipient.sol";
import "../libraries/math/SafeMath.sol";
import "../libraries/FarmLibrary.sol";

import "../libraries/utils/TransferHelper.sol";
import "../libraries/CrossLibrary.sol";

contract CrossFarm is Node, ICrossFarm, BaseRelayRecipient, SessionManager {
    // Do not inherit from Ownable and Context, as they conflicts with BaseRelayRecipient at _mseSender().
    // Instead, implement them here, except _msgSender(). Context plays a role for that.

    //--------------------- Context, except _msgSender -----------------------
    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }

    //--------------------- Ownerble -----------------------------------------

    address private _owner;

    function owner() public view virtual returns (address) {
        return _owner;
    }

    modifier onlyOwner() {
        require(owner() == _msgSender(), "caller is not the owner");
        _;
    }

    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        _transferOwnership(newOwner);
    }

    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    //=========================================================
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    //=========================================================

    uint256 constant vestMonths = 5;
    uint256 constant depositFeeLimit = 5000; // 5.0%

    address crss;
    FarmParams public farmParams;
    uint256 public startBlock;

    PoolInfo[] public poolInfo;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    mapping(address => uint256) public accumulated;

    uint256 public lastPatrolRound;
    uint256 public patrolCycle;

    FarmFeeParams feeParams;

    IMigratorChef public migrator;

    address public backendCaller;

    string private sForbidden;
    string private sZeroAddress;
    string private sInvalidPoolId;
    string private sExceedsBalance;
    string private sInvalidFee;
    string private sInconsistent;

    // modifier onlyOwner() {
    //     require(_msgSender() == owner(), "Caller must be owner");
    //     _;
    // }

    function getOwner() public view virtual override returns (address) {
        return owner();
    }

    modifier validPid(uint256 _pid) {
        require(_pid < poolInfo.length, sInvalidPoolId);
        _;
    }

    receive() external payable {}

    constructor(
        address _crss,
        uint256 _crssPerBlock,
        uint256 _startBlock
    ) Node(NodeType.Farm) {
        _transferOwnership(_msgSender());
        // This is the contrutor part of Ownable. Read the comments at the contract declaration.

        crss = _crss;
        farmParams.crssPerBlock = _crssPerBlock;
        farmParams.bonusMultiplier = 1;

        require(block.number < _startBlock, sForbidden);
        startBlock = _startBlock;

        trackFeeStores = true;
        trackFeeRates = true;
        trackPairStatus = true;

        patrolCycle = 3600;

        // temporary
        feeParams.crssReferral = address(0);
        feeParams.referralCommissionRate = 100; // 0.1%
        feeParams.nonVestBurnRate = 25000; // 25.0%
        feeParams.compoundFeeRate = 5000; // 5%
        feeParams.stakeholders = 0x23C6D84c09523032B08F9124A349760721aF64f6;

        sForbidden = "Forbidden";
        sZeroAddress = "Zero address";
        sInvalidPoolId = "Invalid pool id";
        sExceedsBalance = "Exceeds balance";
        sInvalidFee = "Invalid fee";
        sInconsistent = "Inconsistent";
    }

    function setCrssPerBlock(uint256 _crssPerBlock) public onlyOwner {
        require(_crssPerBlock <= 10**18, "Invalid Crss Per Block");
        massUpdatePools();
        farmParams.crssPerBlock = _crssPerBlock;
    }

    function setNode(
        NodeType nodeType,
        address node,
        address caller
    ) public virtual override wired {
        if (caller != address(this)) {
            // let caller be address(0) when an actor initiats this loop.
            WireLibrary.setNode(nodeType, node, nodes);
            if (nodeType == NodeType.Token) {
                require(crss == address(0) || crss == node, sInconsistent);
                sessionRegistrar = ISessionRegistrar(node);
                sessionFees = ISessionFees(node);
            }
            address trueCaller = caller == address(0) ? address(this) : caller;
            INode(nextNode).setNode(nodeType, node, trueCaller);
        } else {
            emit SetNode(nodeType, node);
        }
    }

    function begin(address caller) public virtual override wired {
        if (caller != address(this)) {
            // let caller be address(0) when an actor initiats this loop.
            farmParams.totalAllocPoint = add(15, crss, true, 0, 0, true);
            INode(nextNode).begin(caller == address(0) ? address(this) : caller);
        } else {
            emit Begin();
        }
    }

    function changePatrolCycle(uint256 newCycle) public virtual onlyOwner {
        patrolCycle = newCycle;
    }

    function _revertOnZeroAddress(address addr) internal view {
        require(addr != address(0), sZeroAddress);
    }

    //==================== Fee Rates and Accounts ====================

    function setFeeParams(
        address _stakeholders,
        address _crssReferral,
        uint256 _referralCommissionRate,
        uint256 _nonVestBurnRate,
        uint256 _compoundFeeRate
    ) external onlyOwner {
        feeParams.stakeholders = _stakeholders;
        feeParams.crssReferral = _crssReferral;
        feeParams.referralCommissionRate = _referralCommissionRate;
        feeParams.nonVestBurnRate = _nonVestBurnRate;
        feeParams.compoundFeeRate = _compoundFeeRate;

        emit SetFeeParamsReferral(_crssReferral, _referralCommissionRate);
        emit SetFeeParamsOthers(_stakeholders, _nonVestBurnRate, _compoundFeeRate);
    }

    function setBackendCaller(address _backendCaller) external onlyOwner {
        backendCaller = _backendCaller;
    }

    ///==================== Farming ====================

    function updateMultiplier(uint256 multiplierNumber) public override onlyOwner {
        farmParams.bonusMultiplier = multiplierNumber;
    }

    function poolLength() external view override returns (uint256) {
        return poolInfo.length;
    }

    /**
     * @dev Add a farming pool.
     */
    function add(
        uint256 _allocPoint,
        address _lpToken,
        bool _withUpdate,
        uint256 _depositFeeRate,
        uint256 _withdrawLock, // Shoule be in sec format
        bool autoCompound
    ) public override wired returns (uint256 totalAllocPoint) {
        require(_lpToken != address(0), sForbidden);
        IERC20 lpToken = IERC20(_lpToken);
        // for (uint256 i = 0; i < poolInfo.length; i++) {
        //     // takes little gas.
        //     require(poolInfo[i].lpToken != lpToken, "Used LP");
        // }
        require(pairs[_lpToken].status == ListStatus.Enlisted, sForbidden);
        require(_depositFeeRate <= depositFeeLimit, sInvalidFee);
        if (_withUpdate) massUpdatePools();
        totalAllocPoint = FarmLibrary.addPool(
            _allocPoint,
            _lpToken,
            _depositFeeRate,
            _withdrawLock,
            autoCompound,
            startBlock,
            poolInfo
        );
        farmParams.totalAllocPoint = totalAllocPoint;
    }

    /**
     * @dev Reset a farming pool, with new alloccation points and deposit fee rate.
     */
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        bool _withUpdate,
        uint256 _depositFeeRate,
        uint256 _withdrawLock, // Shoule be in sec format
        bool autoCompound
    ) public override onlyOwner returns (uint256 totalAllocPoint) {
        require(_pid != 0, sInvalidPoolId);
        require(_depositFeeRate <= depositFeeLimit, sInvalidFee);
        if (_withUpdate) massUpdatePools();
        totalAllocPoint = FarmLibrary.setPool(
            poolInfo,
            _pid,
            _allocPoint,
            _depositFeeRate,
            _withdrawLock,
            autoCompound
        );
        farmParams.totalAllocPoint = totalAllocPoint;
    }

    // // Migrate lp token to another lp contract. Can be called by anyone. We trust that migrator contract is good.
    // function migrate(uint256 _pid) public onlyOwner {
    //     PoolInfo storage pool = poolInfo[_pid];
    //     FarmLibrary.migrate(pool, migrator);
    // }

    function getMultiplier(uint256 _from, uint256 _to) public view override returns (uint256) {
        return (_to - _from) * farmParams.bonusMultiplier;
    }

    /**
     * @dev update all existing pools.
     * Average 30,000 gas is used to update a pool.
     * The 90 million gas, which is the current block gas limit of the BSC chain, can update 200 pools.
     */

    function massUpdatePools() public override {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            PoolInfo storage pool = poolInfo[pid];
            FarmLibrary.updatePool(pool, farmParams, nodes, feeStores);
        }
    }

    /**
     * @dev Update pool from outside.
     * Control its session.
     */
    function updatePool(uint256 _pid) public override validPid(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        FarmLibrary.updatePool(pool, farmParams, nodes, feeStores);
    }

    /**
     * @dev Change the referral ledger contract.
     */
    function changeReferrer(address user, address referrer) public override {
        require(_msgSender() == backendCaller, sForbidden);
        require(referrer != user, sForbidden);
        ICrssReferral(feeParams.crssReferral).recordReferral(user, referrer);
        emit ChangeReferer(user, referrer);
    }

    function getOutstandingCommission(address referrer) external view returns (uint256 amount) {
        return ICrssReferral(feeParams.crssReferral).getOutstandingCommission(referrer);
    }

    function withdrawOutstandingCommission(uint256 amount) external {
        FarmLibrary.withdrawOutstandingCommission(_msgSender(), amount, feeParams, nodes);
    }

    /**
     * @dev update all existing pools.
     * Average 400,000 gas is used to patrol a pool.
     * As the BSC chain's block gas limit is 90 million gas, we can expect 200 pools can be patrolled in a call.
     */

    function periodicPatrol() public virtual override returns (bool done) {
        require(_msgSender() == backendCaller, sForbidden);
        uint256 newLastPatrolRound = FarmLibrary.periodicPatrol(
            poolInfo,
            farmParams,
            feeParams,
            nodes,
            lastPatrolRound,
            patrolCycle,
            feeStores
        );
        if (newLastPatrolRound != 0) {
            lastPatrolRound = newLastPatrolRound;
            done = true;
        }
    }

    function getUserState(uint256 pid, address userAddress) external view validPid(pid) returns (UserState memory) {
        return FarmLibrary.getUserState(userAddress, pid, poolInfo, userInfo, nodes, farmParams, vestMonths);
    }

    function getVestList(uint256 pid, address userAddress) external view validPid(pid) returns (VestChunk[] memory) {
        return userInfo[pid][userAddress].vestList;
    }

    // function getSubPooledCrss(uint256 pid, address userAddress)
    //     external
    //     view
    //     validPid(pid)
    //     returns (SubPooledCrss memory)
    // {
    //     return FarmLibrary.getSubPooledCrss(poolInfo[pid], userInfo[pid][userAddress]);
    // }

    // ============================== Session (Transaction) Area ==============================
    /**
     * @dev Deposit LP tokens to gain reward emission.
     */
    function deposit(uint256 _pid, uint256 _amount) public override validPid(_pid) returns (uint256 deposited) {
        _openAction(ActionType.Deposit, true);

        address msgSender = _msgSender();
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msgSender];

        _checkEnlisted(address(pool.lpToken));

        // behavior.crssBusd = crssBusd;
        FarmLibrary.finishRewardCycle(pool, user, msgSender, feeParams, nodes, farmParams, feeStores);

        if (_amount > pool.lpToken.balanceOf(msgSender)) _amount = pool.lpToken.balanceOf(msgSender);
        if (_amount > 0) {
            _amount = FarmLibrary.pullFromUser(address(pool.lpToken), msgSender, _amount, nodes.token);
            _amount -= _payTransactonFee(address(pool.lpToken), address(this), _amount, false);
            _amount -= FarmLibrary.payDepositFeeLPFromFarm(pool, _amount, feeStores);
            deposited = _amount;
            FarmLibrary.startRewardCycle(pool, user, msgSender, nodes, feeParams, deposited, true, true); // false: addNotSubract
            emit Deposit(_msgSender(), _pid, deposited);
        }

        _closeAction();
    }

    /**
     * @dev Withdraw LP tokens deposited in the past.
     */
    function withdraw(uint256 _pid, uint256 _amount) public override validPid(_pid) returns (uint256 withdrawn) {
        _openAction(ActionType.Withdraw, true);

        address msgSender = _msgSender();
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msgSender];

        FarmLibrary.finishRewardCycle(pool, user, msgSender, feeParams, nodes, farmParams, feeStores);
        if (user.amount < _amount) _amount = user.amount;

        if (_amount > 0) {
            withdrawn = _amount;
            _amount -= _payTransactonFee(address(pool.lpToken), address(this), _amount, false);
            FarmLibrary.pushToUser(address(pool.lpToken), msgSender, _amount, nodes.token); // withdraw.
            FarmLibrary.startRewardCycle(pool, user, msgSender, nodes, feeParams, withdrawn, false, true); // false: addNotSubract
            emit Withdraw(msgSender, _pid, withdrawn);
        }

        _closeAction();
    }

    // /**
    // * @dev Withdraw a given amount of unlocked Crss amount form the user's vesting process.
    // */

    // function withdrawVest(uint256 _pid, uint256 _amount)
    //  public override validPid(_pid)  returns (uint256 withdrawn) {
    //     _openAction(ActionType.WithdrawVest, true);

    //     address msgSender = _msgSender();
    //     PoolInfo storage pool = poolInfo[_pid];
    //     UserInfo storage user = userInfo[_pid][msgSender];
    //     behavior.crssBusd = crssBusd;
    //     FarmLibrary.finishRewardCycle2(pool, user, bahavior, msgSender, feeParams, nodes, farmParams);
    //
    //     if (_amount > 0) {
    //         _amount -= FarmLibrary.withdrawVestPieces(user.vestList, vestMonths, _amount);
    //         withdrawn = _amount;
    //         _amount -= _payTransactonFee(nodes.token, nodes.xToken, _amount, false);
    //         ICrssToken(nodes.token).transferDirectSafe(nodes.xToken, msgSender, _amount);
    //         emit WithdrawVest(msgSender, _pid, withdrawn);
    //     }

    //     _closeAction();
    // }

    /**
     * @dev Withdraw a user's deposit in a given pool, without operning session, for emergency use.
     */

    // function vestAccumulated(uint256 _pid)
    //     public
    //     virtual
    //     override
    //     validPid(_pid)
    //     returns (uint256 vested)
    // {
    //     _openAction(ActionType.VestAccumulated, true);

    //     address msgSender = _msgSender();
    //     PoolInfo storage pool = poolInfo[_pid];
    //     UserInfo storage user = userInfo[_pid][msgSender];

    //     _checkEnlisted(address(pool.lpToken));

    //     behavior.crssBusd = crssBusd;
    //     FarmLibrary.finishRewardCycle2(pool, user, behavior, msgSender, feeParams, nodes, farmParams, feeStores);

    //     uint256 amount = user.accumulated;
    //     if (amount > 0) {
    //         amount -= _payTransactonFee(nodes.token, nodes.xToken, amount, false);
    //         user.vestList.push(VestChunk({principal: amount, withdrawn: 0, startTime: block.timestamp}));
    //         vested = amount;
    //         user.accumulated = 0;
    //         emit VestAccumulated(msgSender, _pid, vested);
    //     }

    //     _closeAction();
    // }

    // function compoundAccumulated(uint256 _pid)
    //  public override virtual validPid(_pid) returns (uint256 compounded) {
    //     _openAction(ActionType.CompoundAccumulated);

    //     address msgSender = _msgSender();
    //     PoolInfo storage pool = poolInfo[_pid];
    //     UserInfo storage user = userInfo[_pid][msgSender];
    //     behavior.crssBusd = crssBusd;
    //     FarmLibrary.finishRewardCycle2(pool, user, behavior, msgSender, feeParams, nodes, farmParams);

    //     uint256 amount = user.accumulated;

    //     uint256 newLpAmount;
    //     if (amount > 0) {
    //         amount -= _payTransactonFee(nodes.token, nodes.xToken, amount, false);
    //         amount -= FarmLibrary.payCompoundFee(nodes.token, feeParams, amount, nodes);
    //         compounded = amount;
    //         newLpAmount = FarmLibrary.changeCrssInXTokenToLpInFarm(address(pool.lpToken), nodes, amount, feeParams.stakeholders);
    //         FarmLibrary.startRewardCycle(pool, user, msgSender, newLpAmount, true);  // true: addNotSubract
    //         user.accumulated = 0;
    //         emit CompoundAccumulated(msgSender, _pid, compounded, newLpAmount);
    //     }
    //     _closeAction();
    // }

    function harvestAccumulated(uint256 _pid) public virtual override validPid(_pid) returns (uint256 harvested) {
        _openAction(ActionType.HarvestAccumulated, true);

        address msgSender = _msgSender();
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msgSender];

        FarmLibrary.finishRewardCycle(pool, user, msgSender, feeParams, nodes, farmParams, feeStores);

        uint256 amount = type(uint256).max;
        amount -= FarmLibrary.withdrawVestPieces(user.vestList, vestMonths, amount);
        amount += user.accumulated;

        if (amount > 0) {
            amount -= _payTransactonFee(nodes.token, nodes.xToken, amount, false);
            harvested = amount;
            ICrssToken(nodes.token).transferDirectSafe(nodes.xToken, msgSender, amount);
            user.accumulated = 0;
            emit HarvestAccumulated(msgSender, _pid, amount);
        }

        _closeAction();
    }

    function stakeAccumulated(uint256 _pid) public virtual override validPid(_pid) returns (uint256 staked) {
        _openAction(ActionType.StakeAccumulated, true);

        address msgSender = _msgSender();
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msgSender];

        _checkEnlisted(address(pool.lpToken));

        FarmLibrary.finishRewardCycle(pool, user, msgSender, feeParams, nodes, farmParams, feeStores);

        uint256 amount = type(uint256).max;
        amount -= FarmLibrary.withdrawVestPieces(user.vestList, vestMonths, amount);
        amount += user.accumulated;

        if (amount > 0) {
            amount -= _payTransactonFee(nodes.token, nodes.xToken, amount, false);
            pool = poolInfo[0];
            user = userInfo[0][msgSender];
            FarmLibrary.finishRewardCycle(pool, user, msgSender, feeParams, nodes, farmParams, feeStores);
            uint256 balance0 = IERC20(nodes.token).balanceOf(address(this));
            ICrssToken(nodes.token).transferDirectSafe(nodes.xToken, address(this), amount);
            amount = IERC20(nodes.token).balanceOf(address(this)) - balance0;
            amount -= FarmLibrary.payDepositFeeLPFromFarm(pool, amount, feeStores);
            staked = amount;
            FarmLibrary.startRewardCycle(pool, user, msgSender, nodes, feeParams, staked, true, true); // false: addNotSubract
            user.accumulated = 0;
            emit StakeAccumulated(msgSender, _pid, amount);
        }

        _closeAction();
    }

    function emergencyWithdraw(uint256 _pid) public override validPid(_pid) {
        _openAction(ActionType.EmergencyWithdraw, true);

        address msgSender = _msgSender();
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msgSender];

        FarmLibrary.finishRewardCycle(pool, user, msgSender, feeParams, nodes, farmParams, feeStores);
        uint256 amount = user.amount;

        if (amount > 0) {
            uint256 withdrawn = amount;
            CrossLibrary.lightTransferFrom(address(pool.lpToken), address(this), msgSender, amount, nodes.token);
            FarmLibrary.startRewardCycle(pool, user, msgSender, nodes, feeParams, withdrawn, false, true); // false: addNotSubract
            emit EmergencyWithdraw(msgSender, _pid, withdrawn);
        }

        _closeAction();
    }

    /**
     * @dev Change users' auto option.
     */
    function switchCollectOption(uint256 _pid, CollectOption newOption) public override validPid(_pid) {
        _openAction(ActionType.SwitchCollectOption, true);

        address msgSender = _msgSender();
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msgSender];

        if (
            FarmLibrary.switchCollectOption(pool, user, newOption, msgSender, feeParams, nodes, farmParams, feeStores)
        ) {
            emit SwitchCollectOption(msgSender, _pid, newOption);
        }

        _closeAction();
    }

    /**
     * @dev Take all accumulated Crss rewards, across the given list of pool, of the calling user to their wallet.
     */
    function massHarvestRewards() public virtual override returns (uint256 rewards) {
        _openAction(ActionType.MassHarvestRewards, true);

        address msgSender = _msgSender();
        uint256 amount = FarmLibrary.collectAccumulated(
            msgSender,
            poolInfo,
            userInfo,
            feeParams,
            nodes,
            farmParams,
            feeStores
        );

        if (amount > 0) {
            rewards = amount;
            amount -= _payTransactonFee(nodes.token, nodes.xToken, amount, false);
            ICrssToken(nodes.token).transferDirectSafe(nodes.xToken, msgSender, amount);
            emit MassHarvestRewards(msgSender, rewards);
        }

        _closeAction();
    }

    /**
     * @dev Stake all accumulated Crss rewards, accross the given list of pools, of the calling user to the first Crss staking pool.
     */
    function massStakeRewards() external virtual override returns (uint256 rewards) {
        _openAction(ActionType.MassStakeRewards, true);

        address msgSender = _msgSender();
        uint256 amount = FarmLibrary.collectAccumulated(
            msgSender,
            poolInfo,
            userInfo,
            feeParams,
            nodes,
            farmParams,
            feeStores
        );
        if (amount > 0) {
            amount -= _payTransactonFee(nodes.token, nodes.xToken, amount, false);
            PoolInfo storage pool = poolInfo[0];
            amount -= FarmLibrary.payDepositFeeCrssFromXCrss(pool, nodes.token, nodes.xToken, amount, feeStores);
            uint256 balance0 = IERC20(nodes.token).balanceOf(address(this));
            ICrssToken(nodes.token).transferDirectSafe(nodes.xToken, address(this), amount);
            amount = IERC20(nodes.token).balanceOf(address(this)) - balance0;

            rewards = amount;

            UserInfo storage user = userInfo[0][msgSender];
            FarmLibrary.finishRewardCycle(pool, user, msgSender, feeParams, nodes, farmParams, feeStores);
            FarmLibrary.startRewardCycle(pool, user, msgSender, nodes, feeParams, rewards, true, true); // false: addNotSubract
            emit MassStakeRewards(msgSender, rewards);
        }

        _closeAction();
    }

    // function massCompoundRewards() external virtual override {
    //     _openAction(ActionType.MassCompoundRewards, true);

    //     address msgSender = _msgSender();
    //     uint256 totalCompounded = FarmLibrary.massCompoundRewards(
    //         msgSender,
    //         poolInfo,
    //         userInfo,
    //         nodes,
    //         feeParams,
    //         farmParams,
    //         feeStores
    //     );
    //     emit MassCompoundRewards(msgSender, totalCompounded);

    //     _closeAction();
    // }

    function _payTransactonFee(
        address payerToken,
        address payerAddress,
        uint256 principal,
        bool fromAllowance
    ) internal virtual returns (uint256 feesPaid) {
        if (actionParams.isUserAction && principal > 0) {
            if (address(payerToken) == nodes.token) {
                feesPaid = _payFeeCrss(payerAddress, principal, feeRates[actionParams.actionType], fromAllowance);
            } else {
                feesPaid = CrossLibrary.transferFeesFrom(
                    payerToken,
                    address(this),
                    principal,
                    feeRates[actionParams.actionType],
                    feeStores,
                    nodes.token,
                    true
                ); // payerAddress: address(this).
            }
        }
    }

    //==============================   ==============================

    /**
     * @dev Set the trusted forwarder who works as a middle man between client and this contract.
     * The forwarder verifies client signature, append client's address to call data, and forward the client's call.
     * This contract, as a BaseRelayRecipient, calls _msgSender() to get the appended client address,
     * if msg.sender matches the trusted forwarder. If not, msg.sender itself is returned.
     * This way, the trusted forwader can pay gas fee for the client.
     * See https://eips.ethereum.org/EIPS/eip-2771 for more.
     */
    function setTrustedForwarder(address _trustedForwarder) external onlyOwner {
        require(_trustedForwarder != address(0), sForbidden);
        trustedForwarder = _trustedForwarder;
        emit SetTrustedForwarder(_trustedForwarder);
    }

    // Set the migrator contract. Can only be called by the owner.
    function setMigrator(IMigratorChef _migrator) public onlyOwner {
        migrator = _migrator;
    }
}
