// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../session/Node.sol";
import "../session/SessionManager.sol";
import "../session/SessionFees.sol";
import "../libraries/math/SafeMath.sol";

import "../farm/CrssToken.sol";
import "./RCrssToken.sol";
import "./RSyrupBar.sol";
import "hardhat/console.sol";

contract Repay is Node, RCrssToken, SessionManager {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct VestChunk {
        uint256 principal;
        uint256 withdrawn;
        uint256 startTime;
    }

    // Info of each user.
    struct UserInfoRepay {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        VestChunk[] vestList;
    }
    // Info of each pool.
    struct PoolInfoRepay {
        IERC20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. CAKEs to distribute per block.
        uint256 lastRewardBlock; // Last block number that CAKEs distribution occurs.
        uint256 accCakePerShare; // Accumulated CAKEs per share, times 1e12. See below.
    }

    CrssToken public crss;
    RSyrupBar public rSyrup;
    uint256 public cakePerBlock;
    uint256 public BONUS_MULTIPLIER = 1;
    IMigratorChef public migrator;

    uint256 public totalMinted = 0;

    PoolInfoRepay[] public poolInfo;
    mapping(uint256 => mapping(address => UserInfoRepay)) public userInfo;
    uint256 public totalAllocPoint = 0;
    uint256 public startBlock;

    bool public paused;
    bool private hasRun;

    uint256 public instantFeeRate;
    uint256 public feeMagnifier = 100000;
    uint256 constant vestMonths = 5;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event SetInstantFeeRate(uint256 prevRate, uint256 newRate);

    string private sZeroAddress = "Zero Address";

    constructor(
        address payable _crss,
        address _rSyrup,
        uint256 _cakePerBlock,
        uint256 _startBlock
    ) RCrssToken() Node(NodeType.Repay) {
        require(_crss != address(0), sZeroAddress);
        crss = CrssToken(_crss);
        require(_rSyrup != address(0), sZeroAddress);
        rSyrup = RSyrupBar(_rSyrup);
        cakePerBlock = _cakePerBlock;
        startBlock = _startBlock;
        instantFeeRate = 25000;

        trackFeeStores = true;
        trackFeeRates = true;

        // staking pool
        poolInfo.push(
            PoolInfoRepay({
                lpToken: IERC20(address(this)),
                allocPoint: 1000,
                lastRewardBlock: startBlock,
                accCakePerShare: 0
            })
        );

        totalAllocPoint = 1000;

        paused = true;
    }

    function setInstantFeeRate(uint256 _instantFeeRate) public onlyOwner {
        require(_instantFeeRate < 50000, "Invalid Instant Fee Rate");
        uint256 prevRate = instantFeeRate;
        instantFeeRate = _instantFeeRate;
        emit SetInstantFeeRate(prevRate, instantFeeRate);
    }

    function updatgeCrssPerBlock(uint256 _crssPerBlock) external onlyOwner {
        cakePerBlock = _crssPerBlock;
    }

    function updateMultiplier(uint256 multiplierNumber) public onlyOwner {
        BONUS_MULTIPLIER = multiplierNumber;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Set the migrator contract. Can only be called by the owner.
    function setMigrator(IMigratorChef _migrator) public onlyOwner {
        migrator = _migrator;
    }

    // Migrate lp token to another lp contract. Can be called by anyone. We trust that migrator contract is good.
    function migrate(uint256 _pid) public {
        require(address(migrator) != address(0), "migrate: no migrator");
        PoolInfoRepay storage pool = poolInfo[_pid];
        IERC20 lpToken = pool.lpToken;
        uint256 bal = lpToken.balanceOf(address(this));
        lpToken.safeApprove(address(migrator), bal);
        IERC20 newLpToken = migrator.migrate(lpToken);
        require(bal == newLpToken.balanceOf(address(this)), "migrate: bad");
        pool.lpToken = newLpToken;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // View function to see pending CAKEs on frontend.
    function pendingCake(uint256 _pid, address _user) public view returns (uint256) {
        PoolInfoRepay storage pool = poolInfo[_pid];
        UserInfoRepay storage user = userInfo[_pid][_user];
        uint256 accCakePerShare = pool.accCakePerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));

        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 cakeReward = multiplier.mul(cakePerBlock);
            // careReward is reward after the lastest pool.update.

            accCakePerShare = accCakePerShare.add(cakeReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accCakePerShare).div(1e12).sub(user.rewardDebt); // Right!!!
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfoRepay storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        console.log("Block: ", startBlock, pool.lastRewardBlock, block.number);
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 cakeReward = multiplier.mul(cakePerBlock);

        if (cakeReward + totalMinted <= lpSupply) {
            // This is a moment when inflation occurs. ========================================
            crss.mint(address(this), cakeReward); // The whole cakeReward will be stored in rSyrup. So, users have their CAKE chare in rSyrup account.
        } else {
            cakeReward = lpSupply - totalMinted;
            crss.mint(address(this), cakeReward); // The whole cakeReward will be stored in rSyrup. So, users have their CAKE chare in rSyrup account.
            paused = true;
        }

        totalMinted += cakeReward;
        console.log("Total mint: ", totalMinted, cakeReward);

        pool.accCakePerShare = pool.accCakePerShare.add(cakeReward.mul(1e12).div(lpSupply)); // 1e12
        // So, cakepershare has the background that lpSupply contributed to cakeReward.

        pool.lastRewardBlock = block.number;
    }

    // Safe crss transfer function, just in case if rounding error causes pool to not have enough CAKEs.
    function _safeCrssTransfer(address _to, uint256 _amount) internal {
        uint256 crssBal = crss.balanceOf(address(this));
        if (_amount <= 0) return;
        if (_amount > crssBal) {
            crss.transferDirectSafe(address(this), _to, crssBal);
        } else {
            crss.transferDirectSafe(address(this), _to, _amount);
        }
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
                sessionRegistrar = ISessionRegistrar(node);
                sessionFees = ISessionFees(node);
            }
            address trueCaller = caller == address(0) ? address(this) : caller;
            INode(nextNode).setNode(nodeType, node, trueCaller);
        } else {
            emit SetNode(nodeType, node);
        }
    }

    function getOwner() public virtual override returns (address) {
        return owner();
    }

    function pause() external onlyOwner {
        paused = true;
    }

    function resume() external onlyOwner {
        paused = false;
        hasRun = true;
    }

    function loadLossDataSplit(Loss[] calldata losses) external onlyOwner {
        require(hasRun == false, "Forbidden");

        // loadSplit(losses);
        for (uint256 i = 0; i < losses.length; i++) {
            _mintRepayToken(address(this), losses[i].amount);
            UserInfoRepay storage user = userInfo[0][losses[i].victim];
            user.amount = losses[i].amount;
        }
    }

    function getUserState(address userAddress)
        public
        view
        returns (
            uint256 _deposit,
            uint256 pendingCrss,
            uint256 withdrawable
        )
    {
        uint256 pid = 0;

        UserInfoRepay storage user = userInfo[pid][userAddress];
        _deposit = user.amount;
        pendingCrss = pendingCake(0, userAddress);
        withdrawable = totalWithdrawable(user);
    }

    function getVestList(address userAddress) external view returns (VestChunk[] memory) {
        return userInfo[0][userAddress].vestList;
    }

    function harvestRepay(bool vest) public {
        uint256 gasOld = gasleft();
        _openAction(ActionType.HarvestRepay, true);

        address userAddress = msg.sender;

        if (!paused) updatePool(0);

        PoolInfoRepay storage pool = poolInfo[0];
        UserInfoRepay storage user = userInfo[0][userAddress];
        uint256 userPending = (user.amount * pool.accCakePerShare) / 1e12 - user.rewardDebt;
        if (userPending > 0) {
            if (vest) {
                user.vestList.push(VestChunk({principal: userPending, withdrawn: 0, startTime: block.timestamp}));
            } else {
                uint256 instantFee = (userPending * instantFeeRate) / feeMagnifier;
                userPending = userPending - instantFee;
                _safeCrssTransfer(userAddress, userPending);
                _safeCrssTransfer(feeStores.accountant, instantFee);
            }
        }

        withdrawVest();
        // (userPending - amount) is saved.
        user.rewardDebt = (user.amount * pool.accCakePerShare) / 1e12;

        _closeAction();
        uint256 gasnew = gasleft();
        console.log("Gas Used: ", gasOld - gasnew);
    }

    function totalWithdrawable(UserInfoRepay storage user) internal view returns (uint256) {
        VestChunk[] storage vestList = user.vestList;

        uint256 withdrawable = 0;
        for (uint256 i = 0; i < vestList.length; i++) {
            uint256 elapsed = (block.timestamp - vestList[i].startTime); // * 600 * 24 * 30;
            uint256 monthsElapsed = elapsed / month >= vestMonths ? vestMonths : elapsed / month;
            uint256 unlockAmount = (vestList[i].principal * monthsElapsed) / vestMonths - vestList[i].withdrawn;
            withdrawable += unlockAmount;
        }
        return withdrawable;
    }

    function withdrawVest() internal returns (uint256) {
        VestChunk[] storage vestList = userInfo[0][msg.sender].vestList;

        uint256 i;
        uint256 withdrawable = 0;

        while (i < vestList.length) {
            // Time simulation for test: 600 * 24 * 30. A hardhat block pushes 2 seconds of timestamp. 3 blocks will be equivalent to a month.
            uint256 elapsed = (block.timestamp - vestList[i].startTime); // * 600 * 24 * 30;
            uint256 monthsElapsed = elapsed / month >= vestMonths ? vestMonths : elapsed / month;
            uint256 unlockAmount = (vestList[i].principal * monthsElapsed) / vestMonths - vestList[i].withdrawn;
            if (unlockAmount > 0) {
                vestList[i].withdrawn += unlockAmount; // so, vestList[i].withdrawn < vestList[i].principal * monthsElapsed / vestMonths.
                withdrawable += unlockAmount;
            }
            if (vestList[i].withdrawn == vestList[i].principal) {
                // if and only if monthsElapsed == vestMonths.
                for (uint256 j = i; j < vestList.length - 1; j++) vestList[j] = vestList[j + 1];
                vestList.pop();
            } else {
                i++;
            }
        }

        _safeCrssTransfer(msg.sender, withdrawable);
        return withdrawable;
    }
}
