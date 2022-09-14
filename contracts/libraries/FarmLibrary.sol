// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../session/interfaces/ISessionManager.sol";
import "../session/interfaces/ISessionFees.sol";
import "../periphery/interfaces/IMaker.sol";
import "../periphery/interfaces/ITaker.sol";
import "../farm/interfaces/ICrssToken.sol";
import "../farm/interfaces/IXCrssToken.sol";
import "../core/interfaces/IPancakePair.sol";
import "../farm/interfaces/ICrssReferral.sol";
import "../farm/interfaces/IMigratorChef.sol";
import "../farm/interfaces/ICrossFarmTypes.sol";
import "../farm/interfaces/ICrossFarm.sol";
import "../libraries/utils/TransferHelper.sol";
import "../libraries/CrossLibrary.sol";
import "./math/SafeMath.sol";

library FarmLibrary {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    function changeCrssInXTokenToLpInFarm(
        address targetLpToken,
        Nodes storage nodes,
        uint256 amountCrssInXToken,
        address dustBin
    ) public returns (uint256 newLpAmountInFarm) {
        if (targetLpToken != address(0) && amountCrssInXToken > 0) {
            uint256 balance0 = ICrssToken(nodes.token).balanceOf(address(this));
            ICrssToken(nodes.token).transferDirectSafe(nodes.xToken, address(this), amountCrssInXToken);
            uint256 amountCrssInFarm = ICrssToken(nodes.token).balanceOf(address(this)) - balance0;

            if (targetLpToken == nodes.token) {
                newLpAmountInFarm = amountCrssInFarm; // Staked Crss tokens reside in token.balanceOf[address(this)].
            } else {
                uint256 amount0 = amountCrssInFarm / 2;
                uint256 amount1 = amountCrssInFarm - amount0;

                (address token0, address token1, ) = INode(nodes.maker).pairs(targetLpToken);

                {
                    bool token0Swapable = nodes.token == token0 ||
                        INode(nodes.maker).pairFor(nodes.token, token0) != address(0) ||
                        INode(nodes.maker).pairFor(IMaker(nodes.maker).WETH(), token0) != address(0);
                    bool token1Swapable = nodes.token == token1 ||
                        INode(nodes.maker).pairFor(nodes.token, token1) != address(0) ||
                        INode(nodes.maker).pairFor(IMaker(nodes.maker).WETH(), token1) != address(0);

                    require(token0Swapable && token1Swapable, "Swap path not found");
                }
                amount0 = _swapExactCrssForNonCrss(ITaker(nodes.taker), nodes, nodes.token, token0, amount0); // From farm to farm
                amount1 = _swapExactCrssForNonCrss(ITaker(nodes.taker), nodes, nodes.token, token1, amount1); // From farm to farm

                require(amount0 > 0 && amount1 > 0, "Swap failed");

                balance0 = IERC20(targetLpToken).balanceOf(address(this));
                IERC20(token0).safeIncreaseAllowance(nodes.maker, amount0);
                IERC20(token1).safeIncreaseAllowance(nodes.maker, amount1);

                (uint256 _amount0, uint256 _amount1, ) = IMaker(nodes.maker).wired_addLiquidity(
                    token0,
                    token1,
                    amount0,
                    amount1,
                    0,
                    0,
                    address(this), // lp tokens sent to farm.
                    block.timestamp
                );
                newLpAmountInFarm = IERC20(targetLpToken).balanceOf(address(this)) - balance0;

                // Dust is neglected for gas saving:

                // if (amount0 > _amount0) { // remove dust
                //     pushToUser(token0, dustBin, amount0 - _amount0, nodes.token);
                // }
                // if (amount1 > _amount1) { // remove dust
                //     pushToUser(token1, dustBin, amount1 - _amount1, nodes.token);
                // }
            }
        }
    }

    function _swapExactCrssForNonCrss(
        ITaker taker,
        Nodes storage nodes,
        address token,
        address tokenTo,
        uint256 amount
    ) internal returns (uint256 resultingAmount) {
        if (tokenTo == token) {
            resultingAmount = amount;
        } else {
            uint256 balance0 = IERC20(tokenTo).balanceOf(address(this));

            ICrssToken(token).approve(address(taker), amount);
            address[] memory path;

            if (INode(nodes.maker).pairFor(nodes.token, tokenTo) != address(0)) {
                path = new address[](2);
                path[0] = token;
                path[1] = tokenTo;
            } else {
                path = new address[](3);
                path[0] = token;
                path[1] = IMaker(nodes.maker).WETH();
                path[2] = tokenTo;
            }

            taker.wired_swapExactTokensForTokens(
                amount,
                0, // in trust of taker's price control.
                path,
                address(this)
            );
            resultingAmount = IERC20(tokenTo).balanceOf(address(this)) - balance0;
        }
    }

    function _swapExactNonCrssForCrss(
        ITaker taker,
        address token,
        address tokenFr,
        uint256 amount
    ) internal returns (uint256 resultingAmount) {
        if (tokenFr == token) {
            resultingAmount = amount;
        } else {
            uint256 balance0 = IERC20(token).balanceOf(address(this));

            ICrssToken(tokenFr).approve(address(taker), amount);
            address[] memory path = new address[](2);
            path[0] = tokenFr;
            path[1] = token;
            taker.wired_swapExactTokensForTokens(
                amount,
                0, // in trust of taker's price control.
                path,
                address(this)
            );
            resultingAmount = IERC20(token).balanceOf(address(this)) - balance0;
        }
    }

    function _sim_swapExactNonCrssForCrss(
        ITaker taker,
        address token,
        address tokenFr,
        uint256 amount,
        Nodes storage nodes
    ) internal view returns (uint256 resultingAmount) {
        if (tokenFr == token) {
            resultingAmount = amount;
        } else {
            address[] memory path;
            if (INode(nodes.maker).pairFor(token, tokenFr) != address(0)) {
                path = new address[](2);
                path[0] = tokenFr;
                path[1] = token;
            } else {
                path = new address[](3);
                path[0] = tokenFr;
                path[1] = IMaker(nodes.maker).WETH();
                path[2] = token;
            }

            uint256[] memory amounts = taker.sim_swapExactTokensForTokens(amount, path);
            resultingAmount = amounts[1];
        }
    }

    // function getTotalVestPrincipals(VestChunk[] storage vestList) public view returns (uint256 amount) {
    //     for (uint256 i = 0; i < vestList.length; i++) {
    //         amount += vestList[i].principal;
    //     }
    // }

    // function getTotalMatureVestPieces(VestChunk[] storage vestList, uint256 vestMonths)
    //     public
    //     view
    //     returns (uint256 amount)
    // {
    //     for (uint256 i = 0; i < vestList.length; i++) {
    //         // Time simulation for test: 600 * 24 * 30. A hardhat block pushes 2 seconds of timestamp. 3 blocks will be equivalent to a month.
    //         uint256 elapsed = (block.timestamp - vestList[i].startTime); // * 600 * 24 * 30;
    //         uint256 monthsElapsed = elapsed / month >= vestMonths ? vestMonths : elapsed / month;
    //         uint256 unlockAmount = (vestList[i].principal * monthsElapsed) / vestMonths - vestList[i].withdrawn;
    //         amount += unlockAmount;
    //     }
    // }

    function withdrawVestPieces(
        VestChunk[] storage vestList,
        uint256 vestMonths,
        uint256 amount
    ) internal returns (uint256 _amountToFill) {
        _amountToFill = amount;

        uint256 i;
        while (_amountToFill > 0 && i < vestList.length) {
            // Time simulation for test: 600 * 24 * 30. A hardhat block pushes 2 seconds of timestamp. 3 blocks will be equivalent to a month.
            uint256 elapsed = (block.timestamp - vestList[i].startTime); // * 600 * 24 * 30;
            uint256 monthsElapsed = elapsed / month >= vestMonths ? vestMonths : elapsed / month;
            uint256 unlockAmount = (vestList[i].principal * monthsElapsed) / vestMonths - vestList[i].withdrawn;
            if (unlockAmount > _amountToFill) {
                vestList[i].withdrawn += _amountToFill; // so, vestList[i].withdrawn < vestList[i].principal * monthsElapsed / vestMonths.
                _amountToFill = 0;
            } else {
                _amountToFill -= unlockAmount;
                vestList[i].withdrawn += unlockAmount; // so, vestList[i].withdrawn == vestList[i].principal * monthsElapsed / vestMonths.
            }
            if (vestList[i].withdrawn == vestList[i].principal) {
                // if and only if monthsElapsed == vestMonths.
                for (uint256 j = i; j < vestList.length - 1; j++) vestList[j] = vestList[j + 1];
                vestList.pop();
            } else {
                i++;
            }
        }
    }

    function takePendingCollectively(
        PoolInfo storage pool,
        FarmFeeParams storage feeParams,
        Nodes storage nodes,
        bool periodic
    ) public {
        uint256 subPoolPending;
        uint256 totalRewards;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));

        uint256 feePaid;
        uint256 halfToCompound;
        uint256 newLpAmountInFarm;
        uint256 halfToVest;
        uint256 halfToSend;

        // pendingCrss == (getRewardPayroll(pool, user) * pool.accCrssPerShare) / 1e12 - user.rewardDebt
        // is implicitly taken to appropriate subPools here, for all users.

        if (lpSupply > 0) {
            //-------------------- OnOff SubPool Group Takes -------------------- Compound On, Vest Off
            uint256 sumAmount = pool.OnOff.sumAmount;
            subPoolPending = ((sumAmount + pool.OnOff.Comp.bulk) * pool.reward) / lpSupply;

            if (subPoolPending > 0) {
                totalRewards += subPoolPending;
                feePaid = (subPoolPending * feeParams.nonVestBurnRate) / FeeMagnifier;
                ICrssToken(nodes.token).transferDirectSafe(nodes.xToken, feeParams.stakeholders, feePaid);
                subPoolPending -= feePaid;
                subPoolPending -= payCompoundFee(nodes.token, feeParams, subPoolPending, nodes);
            }

            if (periodic) {
                // It takes the amount that belong to the users who left this branch after the latest patrol.
                // subPoolPending += _emptySubPool(pool.OnOff.PreComp);
                if (subPoolPending > 0) {
                    newLpAmountInFarm = changeCrssInXTokenToLpInFarm(
                        address(pool.lpToken),
                        nodes,
                        subPoolPending,
                        feeParams.stakeholders
                    );
                    _addToSubPool(pool.OnOff.Comp, sumAmount, newLpAmountInFarm); // updates bulk & accPerShare.
                }
            } else {
                // This amount is not guranteed to be returned to the users who's deposits participate in sumAmount, if they leave this branch.
                if (subPoolPending > 0) _addToSubPool(pool.OnOff.PreComp, sumAmount, subPoolPending); // updates bulk & accPerShare.
            }

            //-------------------- OnOn SubPool Group Takes -------------------- Compound On, Vest On
            sumAmount = pool.OnOn.sumAmount;
            subPoolPending = ((sumAmount + pool.OnOn.Comp.bulk) * pool.reward) / lpSupply;

            if (subPoolPending > 0) {
                totalRewards += subPoolPending;
                halfToCompound = subPoolPending / 2;
                halfToVest = subPoolPending - halfToCompound;
                halfToCompound -= payCompoundFee(nodes.token, feeParams, halfToCompound, nodes);
            } // else: halfToCompound = 0, halfToVest = 0; implicitly.

            if (periodic) {
                // It takes the amount that belong to the users who left this branch after the latest patrol.
                // halfToCompound += _emptySubPool(pool.OnOn.PreComp);
                if (halfToCompound > 0) {
                    newLpAmountInFarm = changeCrssInXTokenToLpInFarm(
                        address(pool.lpToken),
                        nodes,
                        halfToCompound,
                        feeParams.stakeholders
                    );
                    _addToSubPool(pool.OnOn.Comp, sumAmount, newLpAmountInFarm); // updates bulk & accPerShare.
                }
            } else {
                // This amount is not guranteed to be returned to the users who's deposits participate in sumAmount, if they leave this branch.
                if (halfToCompound > 0) _addToSubPool(pool.OnOn.PreComp, sumAmount, halfToCompound); // updates bulk & accPerShare.
            }
            if (halfToVest > 0) _addToSubPool(pool.OnOn.Vest, sumAmount, halfToVest); // updates bulk & accPerShare.

            //-------------------- OffOn SubPool Group Takes -------------------- Compound Off, Vest On

            subPoolPending = ((pool.OffOn.sumAmount) * pool.reward) / lpSupply;

            if (subPoolPending > 0) {
                totalRewards += subPoolPending;
                halfToVest = subPoolPending / 2;
                halfToSend = subPoolPending - halfToVest;
                _addToSubPool(pool.OffOn.Vest, pool.OffOn.sumAmount, halfToVest); // updates bulk & accPerShare.
                _addToSubPool(pool.OffOn.Accum, pool.OffOn.sumAmount, halfToSend); // updates bulk & accPerShare.
            }
            //-------------------- OffOff SubPool Group Takes -------------------- Compound Off, Vest Off

            subPoolPending = ((pool.OffOff.sumAmount) * pool.reward) / lpSupply;

            if (subPoolPending > 0) {
                totalRewards += subPoolPending;
                feePaid = (subPoolPending * feeParams.nonVestBurnRate) / FeeMagnifier;
                ICrssToken(nodes.token).transferDirectSafe(nodes.xToken, feeParams.stakeholders, feePaid);
                subPoolPending -= feePaid;
                _addToSubPool(pool.OffOff.Accum, pool.OffOff.sumAmount, subPoolPending); // updates bulk & accPerShare.
            }
        }
    }

    function _addToSubPool(
        SubPool storage subPool,
        uint256 totalShare,
        uint256 newAmount
    ) internal {
        subPool.bulk += newAmount;
        if (totalShare > 0) {
            // Note: that inteter devision is not greater than real division. So it's safe.
            // Note: if it's less than real division, then a seed of dust is formed here.
            subPool.accPerShare += ((newAmount * 1e12) / totalShare);
        }
    }

    function payCompoundFee(
        address payerToken,
        FarmFeeParams storage feeParams,
        uint256 amount,
        Nodes storage nodes
    ) public returns (uint256 feesPaid) {
        feesPaid = (amount * feeParams.compoundFeeRate) / FeeMagnifier;
        if (feesPaid > 0) {
            if (payerToken == nodes.token) {
                ICrssToken(nodes.token).transferDirectSafe(nodes.xToken, feeParams.stakeholders, feesPaid);
            } else {
                TransferHelper.safeTransfer(payerToken, feeParams.stakeholders, feesPaid);
            }
        }
    }

    function payReferralComission(
        PoolInfo storage pool,
        UserInfo storage user,
        address msgSender,
        FarmFeeParams storage feeParams,
        Nodes storage nodes
    ) public {
        //-------------------- Pay referral fee outside of user's pending reward --------------------
        // This is the only place user.rewardDebt works explicitly.
        uint256 userPending = (getRewardPayroll(pool, user) * pool.accCrssPerShare) / 1e12 - user.rewardDebt;
        if (userPending > 0) {
            if (feeParams.crssReferral != address(0)) {
                uint256 commission = userPending.mul(feeParams.referralCommissionRate).div(FeeMagnifier);
                if (commission > 0) {
                    address referrer = ICrssReferral(feeParams.crssReferral).getReferrer(msgSender);
                    if (referrer != address(0)) {
                        ICrssToken(nodes.token).mint(nodes.xToken, commission);
                        ICrssReferral(feeParams.crssReferral).recordReferralCommission(referrer, commission);
                    }
                }
            }
            //user.rewardDebt = (getRewardPayroll(pool, user) * pool.accCrssPerShare) / 1e12;
        }
    }

    /**
     * @dev Take the current rewards related to user's deposit, so that the user can change their deposit further.
     */

    function takeIndividualReward(PoolInfo storage pool, UserInfo storage user) public {
        //-------------------- Calling User Takes -------------------------------------------------------------------------
        if (user.collectOption == CollectOption.OnOff && user.amount > 0) {
            // dust may be formed here, due to accPerShare less than its real value.
            uint256 userCompound = (user.amount * pool.OnOff.Comp.accPerShare) / 1e12 - user.debt1;
            if (userCompound > 0) {
                if (pool.OnOff.Comp.bulk < userCompound) userCompound = pool.OnOff.Comp.bulk;
                pool.OnOff.Comp.bulk -= userCompound;
                user.amount += userCompound; //---------- Compound substantially
                // Let users can withdraw auto reward lp at anytime, so not list this to users
                // if (pool.withdrawLock > 0) {
                //     user.depositList.push(DepositInfo({depositAt: block.timestamp, amount: userCompound}));
                // }
                pool.OnOff.sumAmount += userCompound;
                // if it's guranteed user.debt1 is not used again, we can remove the following line to save gas.
                user.debt1 = (user.amount * pool.OnOff.Comp.accPerShare) / 1e12;
            }
        } else if (user.collectOption == CollectOption.OnOn && user.amount > 0) {
            uint256 userAmount = user.amount;
            // dust may be formed here, due to accPerShare less than its real value.
            uint256 userCompound = (user.amount * pool.OnOn.Comp.accPerShare) / 1e12 - user.debt1;
            if (userCompound > 0) {
                if (pool.OnOn.Comp.bulk < userCompound) userCompound = pool.OnOn.Comp.bulk;
                pool.OnOn.Comp.bulk -= userCompound;
                user.amount += userCompound; //---------- Compound substantially
                // if (pool.withdrawLock > 0) {
                //     user.depositList.push(DepositInfo({depositAt: block.timestamp, amount: userCompound}));
                // }
                pool.OnOn.sumAmount += userCompound;
                // if it's guranteed user.debt1 is not used again, we can remove the following line to save gas.
                user.debt1 = (user.amount * pool.OnOn.Comp.accPerShare) / 1e12;
            }

            // dust may be formed here, due to accPerShare less than its real value.
            uint256 userVest = (userAmount * pool.OnOn.Vest.accPerShare) / 1e12 - user.debt2;
            if (userVest > 0) {
                if (pool.OnOn.Vest.bulk < userVest) userVest = pool.OnOn.Vest.bulk;
                pool.OnOn.Vest.bulk -= userVest;
                user.vestList.push(VestChunk({principal: userVest, withdrawn: 0, startTime: block.timestamp})); //---------- Put in vesting.
                // if it's guranteed user.debt2 is not used again, we can remove the following line to save gas.
                user.debt2 = (user.amount * pool.OnOn.Vest.accPerShare) / 1e12;
            }
        } else if (user.collectOption == CollectOption.OffOn && user.amount > 0) {
            // dust may be formed here, due to accPerShare less than its real value.
            uint256 userVest = (user.amount * pool.OffOn.Vest.accPerShare) / 1e12 - user.debt1; //
            if (userVest > 0) {
                if (pool.OffOn.Vest.bulk < userVest) userVest = pool.OffOn.Vest.bulk;
                pool.OffOn.Vest.bulk -= userVest;
                user.vestList.push(VestChunk({principal: userVest, withdrawn: 0, startTime: block.timestamp})); //---------- Put in vesting.
                // if it's guranteed user.debt1 is not used again, we can remove the following line to save gas.
                user.debt1 = (user.amount * pool.OffOn.Vest.accPerShare) / 1e12;
            }

            // dust may be formed here, due to accPerShare less than its real value.
            uint256 userAccum = (user.amount * pool.OffOn.Accum.accPerShare) / 1e12 - user.debt2;
            if (userAccum > 0) {
                if (pool.OffOn.Accum.bulk < userAccum) userAccum = pool.OffOn.Accum.bulk;
                pool.OffOn.Accum.bulk -= userAccum;
                user.accumulated += userAccum; //---------- Accumulate.
                // if it's guranteed user.debt2 is not used again, we can remove the following line to save gas.
                user.debt2 = (user.amount * pool.OffOn.Accum.accPerShare) / 1e12;
            }
        } else if (user.collectOption == CollectOption.OffOff && user.amount > 0) {
            // dust may be formed here, due to accPerShare less than its real value.
            uint256 userAccum = (user.amount * pool.OffOff.Accum.accPerShare) / 1e12 - user.debt1;
            if (userAccum > 0) {
                if (pool.OffOff.Accum.bulk < userAccum) userAccum = pool.OffOff.Accum.bulk;
                pool.OffOff.Accum.bulk -= userAccum;
                user.accumulated += userAccum; //---------- Accumulate.
                // if it's guranteed user.debt1 is not used again, we can remove the following line to save gas.
                user.debt1 = (user.amount * pool.OffOff.Accum.accPerShare) / 1e12;
            }
        }

        // if it's guranteed user.rewardDebt is not used again, we can remove the following line to save gas.
        user.rewardDebt = (getRewardPayroll(pool, user) * pool.accCrssPerShare) / 1e12;
    }

    /**
     * @dev Begine a new rewarding interval with a new user.amount.
     * @dev Change the user.amount value, change branches' sum of user.amounts, and reset all debt so that pendings are zero now.
     * Note: This is not the place to upgrade accPerShare, because this call is not a reward gain.
     * Reward gain, instead, takes place in _updatePool, for pools, and _takeIndividualRewards, for branches and subpools.
     */
    function startRewardCycle(
        PoolInfo storage pool,
        UserInfo storage user,
        address msgSender,
        Nodes storage nodes,
        FarmFeeParams storage feeParams,
        uint256 amount,
        bool addNotSubtract,
        bool moveLock
    ) public {
        // Open it for 0 amount, as it re-bases user debts.

        payReferralComission(pool, user, msgSender, feeParams, nodes); // Pay commission before user.debtReward will change.
        // If pool has unlock period, add deposit list to user info
        if (pool.withdrawLock > 0 && moveLock) {
            if (addNotSubtract) {
                user.depositList.push(DepositInfo({depositAt: block.timestamp, amount: amount}));
            } else {
                bool withdrawable = withdrawLockedLP(pool, user, amount);
                require(withdrawable, "Lock Time Unreached");
            }
        }
        user.amount = addNotSubtract ? (user.amount + amount) : (user.amount - amount);
        if (user.collectOption == CollectOption.OnOff) {
            pool.OnOff.sumAmount = addNotSubtract ? pool.OnOff.sumAmount + amount : pool.OnOff.sumAmount - amount;
            // if (pool.OnOff.sumAmount == 0) {
            //     pushToUser(address(pool.lpToken), msgSender, _emptySubPool(pool.OnOff.Comp), nodes.token);
            //     ICrssToken(nodes.token).transferDirectSafe(nodes.xToken, msgSender, _emptySubPool(pool.OnOff.PreComp));
            // }
            user.debt1 = (user.amount * pool.OnOff.Comp.accPerShare) / 1e12;
        } else if (user.collectOption == CollectOption.OnOn) {
            pool.OnOn.sumAmount = addNotSubtract ? pool.OnOn.sumAmount + amount : pool.OnOn.sumAmount - amount;
            // if (pool.OnOn.sumAmount == 0) {
            //     pushToUser(address(pool.lpToken), msgSender, _emptySubPool(pool.OnOn.Comp), nodes.token);
            //     ICrssToken(nodes.token).transferDirectSafe(nodes.xToken, msgSender, _emptySubPool(pool.OnOn.PreComp));
            //     user.vestList.push(VestChunk({principal: _emptySubPool(pool.OnOn.Vest), withdrawn: 0, startTime: block.timestamp})); //---------- Put in vesting.
            //     // ICrssToken(nodes.token).transferDirectSafe(nodes.xToken, msgSender, _emptySubPool(pool.OnOn.Vest));
            // }
            user.debt1 = (user.amount * pool.OnOn.Comp.accPerShare) / 1e12;
            user.debt2 = (user.amount * pool.OnOn.Vest.accPerShare) / 1e12;
        } else if (user.collectOption == CollectOption.OffOn) {
            pool.OffOn.sumAmount = addNotSubtract ? pool.OffOn.sumAmount + amount : pool.OffOn.sumAmount - amount;
            // if (pool.OffOn.sumAmount == 0) {
            //     user.vestList.push(VestChunk({principal: _emptySubPool(pool.OffOn.Vest), withdrawn: 0, startTime: block.timestamp})); //---------- Put in vesting.
            //     // ICrssToken(nodes.token).transferDirectSafe(nodes.xToken, msgSender, _emptySubPool(pool.OffOn.Vest));
            //     user.accumulated += _emptySubPool(pool.OffOn.Accum);
            //     // ICrssToken(nodes.token).transferDirectSafe(nodes.xToken, msgSender, _emptySubPool(pool.OffOn.Accum));
            // }
            user.debt1 = (user.amount * pool.OffOn.Vest.accPerShare) / 1e12;
            user.debt2 = (user.amount * pool.OffOn.Accum.accPerShare) / 1e12;
        } else if (user.collectOption == CollectOption.OffOff) {
            pool.OffOff.sumAmount = addNotSubtract ? pool.OffOff.sumAmount + amount : pool.OffOff.sumAmount - amount;
            // if (pool.OffOff.sumAmount == 0) {
            //     user.accumulated += _emptySubPool(pool.OffOff.Accum);
            //     // ICrssToken(nodes.token).transferDirectSafe(nodes.xToken, msgSender, _emptySubPool(pool.OffOff.Accum));
            // }
            user.debt1 = (user.amount * pool.OffOff.Accum.accPerShare) / 1e12;
        }

        // No matter if acc has been updated or not since the last visit to this line.
        // [updatePool(), ..., takePendingCollectively()] called after the previous call of this function
        // has collectively taken (getRewardPayroll(pool, user) * pool.accCrssPerShare) / 1e12 - user.rewardDebt.

        user.rewardDebt = (getRewardPayroll(pool, user) * pool.accCrssPerShare) / 1e12;
    }

    function calculateRewardLP(PoolInfo memory pool, UserInfo memory user) internal pure returns (uint256) {
        DepositInfo[] memory depositList = user.depositList;
        uint256 lockPeriod = pool.withdrawLock;
        if (lockPeriod == 0) {
            return getRewardPayroll(pool, user) - user.amount;
        } else {
            uint256 totalDeposit;
            for (uint256 i = 0; i < depositList.length; i++) {
                totalDeposit += depositList[i].amount;
            }
            return getRewardPayroll(pool, user) - totalDeposit;
        }
    }

    function withdrawLockedLP(
        PoolInfo storage pool,
        UserInfo storage user,
        uint256 amount
    ) internal returns (bool) {
        DepositInfo[] storage depositList = user.depositList;
        uint256 lockPeriod = pool.withdrawLock;

        uint256 rewardLP = calculateRewardLP(pool, user);

        uint256 i;
        uint256 amountWithdraw = amount - rewardLP;
        console.log("RewardLP: ", amount, rewardLP, amountWithdraw);
        while (amountWithdraw > 0 && i < depositList.length) {
            // Time simulation for test: 600 * 24 * 30. A hardhat block pushes 2 seconds of timestamp. 3 blocks will be equivalent to a month.
            uint256 elapsed = (block.timestamp - depositList[i].depositAt); // * 600 * 24 * 30;
            if (elapsed > lockPeriod) {
                if (amountWithdraw >= depositList[i].amount) {
                    amountWithdraw -= depositList[i].amount;
                    for (uint256 j = i; j < depositList.length - 1; j++) depositList[j] = depositList[j + 1];
                    depositList.pop();
                } else {
                    depositList[i].amount -= amountWithdraw;
                    amountWithdraw = 0;
                }
            } else {
                i++;
            }
        }
        if (amountWithdraw == 0) return true;
        else return false;
    }

    /**
     * @dev Take the current rewards related to user's deposit, so that the user can change their deposit further.
     */

    function getRewardPayroll(PoolInfo memory pool, UserInfo memory user) internal pure returns (uint256 userLp) {
        userLp = user.amount;

        if (user.collectOption == CollectOption.OnOff && user.amount > 0) {
            userLp += ((user.amount * pool.OnOff.Comp.accPerShare) / 1e12 - user.debt1); //---------- Compound
        } else if (user.collectOption == CollectOption.OnOn && user.amount > 0) {
            userLp += ((user.amount * pool.OnOn.Comp.accPerShare) / 1e12 - user.debt1); //---------- Compound
        }
    }

    function withdrawOutstandingCommission(
        address referrer,
        uint256 amount,
        FarmFeeParams storage feeParams,
        Nodes storage nodes
    ) external {
        uint256 available = ICrssReferral(feeParams.crssReferral).getOutstandingCommission(referrer);
        if (available < amount) amount = available;
        if (amount > 0) {
            ICrssToken(nodes.token).transferDirectSafe(nodes.xToken, referrer, amount);
            ICrssReferral(feeParams.crssReferral).debitOutstandingCommission(referrer, amount);
        }
    }

    // function migratePool(PoolInfo storage pool, IMigratorChef migrator) external returns (IERC20 newLpToken) {
    //     IERC20 lpToken = pool.lpToken;
    //     uint256 bal = lpToken.balanceOf(address(this));
    //     lpToken.safeApprove(address(migrator), bal);
    //     newLpToken = migrator.migrate(lpToken);
    //     require(bal == newLpToken.balanceOf(address(this)), "migration inconsistent");
    // }

    function switchCollectOption(
        PoolInfo storage pool,
        UserInfo storage user,
        CollectOption newOption,
        address msgSender,
        FarmFeeParams storage feeParams,
        Nodes storage nodes,
        FarmParams storage farmParams,
        FeeStores storage feeStores
    ) external returns (bool switched) {
        CollectOption orgOption = user.collectOption;

        if (orgOption != newOption) {
            finishRewardCycle(pool, user, msgSender, feeParams, nodes, farmParams, feeStores);

            uint256 userAmount = user.amount;
            startRewardCycle(pool, user, msgSender, nodes, feeParams, userAmount, false, false); // false: addNotSubract

            user.collectOption = newOption;

            startRewardCycle(pool, user, msgSender, nodes, feeParams, userAmount, true, false); // true: addNotSubract

            switched = true;
        }
    }

    function collectAccumulated(
        address msgSender,
        PoolInfo[] storage poolInfo,
        mapping(uint256 => mapping(address => UserInfo)) storage userInfo,
        FarmFeeParams storage feeParams,
        Nodes storage nodes,
        FarmParams storage farmParams,
        FeeStores storage feeStores
    ) external returns (uint256 rewards) {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; pid++) {
            PoolInfo storage pool = poolInfo[pid];
            UserInfo storage user = userInfo[pid][msgSender];

            if (
                (user.collectOption == CollectOption.OffOn || user.collectOption == CollectOption.OffOff) &&
                user.amount > 0
            ) {
                finishRewardCycle(pool, user, msgSender, feeParams, nodes, farmParams, feeStores);
            }
            rewards += user.accumulated;
            user.accumulated = 0;
        }
    }

    function calcTotalAlloc(PoolInfo[] storage poolInfo) internal view returns (uint256 totalAllocPoint) {
        uint256 length = poolInfo.length;
        uint256 points;
        for (uint256 pid = 0; pid < length; ++pid) {
            points = points + poolInfo[pid].allocPoint;
        }
        totalAllocPoint = points;
    }

    function setPool(
        PoolInfo[] storage poolInfo,
        uint256 pid,
        uint256 _allocPoint,
        uint256 _depositFeeRate,
        uint256 _withdrawLock,
        bool _autoCompound
    ) external returns (uint256 totalAllocPoint) {
        PoolInfo storage pool = poolInfo[pid];
        pool.allocPoint = _allocPoint;
        pool.depositFeeRate = _depositFeeRate;
        pool.withdrawLock = _withdrawLock;
        pool.autoCompound = _autoCompound;

        totalAllocPoint = calcTotalAlloc(poolInfo);
        require(_allocPoint < 100, "Invalid allocPoint");
    }

    function addPool(
        uint256 _allocPoint,
        address _lpToken,
        uint256 _depositFeeRate,
        uint256 _withdrawLock,
        bool _autoCompound,
        uint256 startBlock,
        PoolInfo[] storage poolInfo
    ) external returns (uint256 totalAllocPoint) {
        poolInfo.push(
            buildStandardPool(_lpToken, _allocPoint, startBlock, _depositFeeRate, _withdrawLock, _autoCompound)
        );

        totalAllocPoint = calcTotalAlloc(poolInfo);
        require(_allocPoint < 100, "Invalid allocPoint");
    }

    function getMultiplier(
        uint256 _from,
        uint256 _to,
        uint256 bonusMultiplier
    ) public pure returns (uint256) {
        return (_to - _from) * bonusMultiplier;
    }

    /**
     * @dev Mint rewards, and increase the pool's accCrssPerShare, accordingly.
     * accCrssPerShare: the amount of rewards that a user would have gaind NOW
     * if they had maintained 1e12 LP tokens as user.amount since the very beginning.
     */

    function updatePool(
        PoolInfo storage pool,
        FarmParams storage farmParams,
        Nodes storage nodes,
        FeeStores storage feeStores
    ) public {
        if (pool.lastRewardBlock < block.number) {
            // lpSupply includes comp.bulk amount.
            uint256 lpSupply = pool.lpToken.balanceOf(address(this));
            if (0 < pool.allocPoint && 0 < lpSupply) {
                uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number, farmParams.bonusMultiplier);
                uint256 crssReward = (multiplier * farmParams.crssPerBlock * pool.allocPoint) /
                    farmParams.totalAllocPoint;
                // Mint 8% to dev wallet
                uint256 teamEmission = (crssReward * 8) / 100;
                crssReward -= teamEmission;
                ICrssToken(nodes.token).mint(feeStores.dev, teamEmission);
                ICrssToken(nodes.token).mint(nodes.xToken, crssReward);
                pool.reward = crssReward; // used as a checksum
                pool.accCrssPerShare += ((crssReward * 1e12) / lpSupply);
            } else {
                pool.reward = 0;
            }
            pool.lastRewardBlock = block.number;
        } else {
            pool.reward = 0;
        }
    }

    function pendingCrss(
        PoolInfo storage pool,
        UserInfo storage user,
        FarmParams storage farmParams
    ) public view returns (uint256) {
        uint256 accCrssPerShare = pool.accCrssPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));

        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number, farmParams.bonusMultiplier);
            uint256 crssReward = (multiplier * farmParams.crssPerBlock * pool.allocPoint) / farmParams.totalAllocPoint;
            accCrssPerShare += ((crssReward * 1e12) / lpSupply);
        }
        return (getRewardPayroll(pool, user) * accCrssPerShare) / 1e12 - user.rewardDebt;
    }

    function finishRewardCycle(
        PoolInfo storage pool,
        UserInfo storage user,
        address msgSender,
        FarmFeeParams storage feeParams,
        Nodes storage nodes,
        FarmParams storage farmParams,
        FeeStores storage feeStores
    ) public {
        updatePool(pool, farmParams, nodes, feeStores);
        if (pool.reward > 0) {
            payReferralComission(pool, user, msgSender, feeParams, nodes);
            //userShare = getRewardPayroll(pool, user);
            takePendingCollectively(pool, feeParams, nodes, false); // subPools' bulk and accPerShare.. periodic: false
            pool.reward = 0;
        }

        takeIndividualReward(pool, user);
    }

    function getUserState(
        address msgSender,
        uint256 pid,
        PoolInfo[] storage poolInfo,
        mapping(uint256 => mapping(address => UserInfo)) storage userInfo,
        Nodes storage nodes,
        FarmParams storage farmParams,
        uint256 vestMonths
    ) external view returns (UserState memory userState) {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][msgSender];

        userState.behavior.pendingCrss = pendingCrss(pool, user, farmParams);
        userState.behavior.rewardPayroll = getRewardPayroll(pool, user);

        userState.assets.collectOption = uint256(user.collectOption);
        userState.assets.deposit = user.amount;
        userState.assets.depositList = user.depositList;
        userState.assets.accRewards = user.accumulated;
        // userState.assets.totalMatureVest = getTotalMatureVestPieces(user.vestList, vestMonths);
    }

    function payDepositFeeLPFromFarm(
        PoolInfo storage pool,
        uint256 amount,
        FeeStores storage feeStores
    ) external returns (uint256 feePaid) {
        if (pool.depositFeeRate > 0) {
            feePaid = (amount * pool.depositFeeRate) / FeeMagnifier;
            pool.lpToken.safeTransfer(feeStores.accountant, feePaid);
        }
    }

    function payDepositFeeCrssFromXCrss(
        PoolInfo storage pool,
        address crssToken,
        address xToken,
        uint256 amount,
        FeeStores storage feeStores
    ) external returns (uint256 feePaid) {
        if (pool.depositFeeRate > 0) {
            feePaid = (amount * pool.depositFeeRate) / FeeMagnifier;
            ICrssToken(crssToken).transferDirectSafe(xToken, feeStores.accountant, feePaid);
        }
    }

    function periodicPatrol(
        PoolInfo[] storage poolInfo,
        FarmParams storage farmParams,
        FarmFeeParams storage feeParams,
        Nodes storage nodes,
        uint256 lastPatrolRound,
        uint256 patrolCycle,
        FeeStores storage feeStores
    ) external returns (uint256 newLastPatrolRound) {
        uint256 currRound = block.timestamp / patrolCycle;
        if (lastPatrolRound < currRound) {
            // do periodicPatrol
            for (uint256 pid; pid < poolInfo.length; pid++) {
                PoolInfo storage pool = poolInfo[pid];
                if (!pool.autoCompound) continue;
                updatePool(pool, farmParams, nodes, feeStores);
                if (pool.reward > 0) {
                    takePendingCollectively(pool, feeParams, nodes, true); // periodic: true
                    pool.reward = 0;
                }
            }
            newLastPatrolRound = currRound;
        }
    }

    function pullFromUser(
        address tokenToPull,
        address userAddr,
        uint256 amount,
        address crssToken
    ) external returns (uint256 arrived) {
        uint256 oldBalance = IERC20(tokenToPull).balanceOf(address(this));
        if (tokenToPull == crssToken) {
            ICrssToken(tokenToPull).transferDirectSafe(userAddr, address(this), amount);
        } else {
            TransferHelper.safeTransferFrom(tokenToPull, userAddr, address(this), amount);
        }
        uint256 newBalance = IERC20(tokenToPull).balanceOf(address(this));
        arrived = newBalance - oldBalance;
    }

    function pushToUser(
        address tokenToPush,
        address userAddr,
        uint256 amount,
        address crssToken
    ) public returns (uint256 arrived) {
        if (tokenToPush == crssToken) {
            ICrssToken(crssToken).transferDirectSafe(address(this), userAddr, amount);
        } else {
            TransferHelper.safeTransfer(tokenToPush, userAddr, amount);
        }
    }

    function buildStandardPool(
        address lp,
        uint256 allocPoint,
        uint256 startBlock,
        uint256 depositFeeRate,
        uint256 withdrawLock,
        bool autoCompound
    ) public view returns (PoolInfo memory pool) {
        pool = PoolInfo({
            lpToken: IERC20(lp),
            allocPoint: allocPoint,
            lastRewardBlock: (block.number > startBlock ? block.number : startBlock),
            accCrssPerShare: 0,
            depositFeeRate: depositFeeRate,
            withdrawLock: withdrawLock,
            autoCompound: autoCompound,
            reward: 0,
            OnOff: Struct_OnOff(0, SubPool(0, 0), SubPool(0, 0)),
            OnOn: Struct_OnOn(0, SubPool(0, 0), SubPool(0, 0), SubPool(0, 0)),
            OffOn: Struct_OffOn(0, SubPool(0, 0), SubPool(0, 0)),
            OffOff: Struct_OffOff(0, SubPool(0, 0))
        });
    }
}
