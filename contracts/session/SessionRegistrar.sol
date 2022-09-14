// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./interfaces/IConstants.sol";
import "./interfaces/ISessionRegistrar.sol";

abstract contract SessionRegistrar is ISessionRegistrar {

    uint256 public session;
    uint256 public lastSession;
    mapping(ActionType => uint256) public sessionsLastSeenBySType;

    ActionType[20] private actionStack;
    uint256 stackPointer;

    bool public paused;

    modifier onlySessionManager virtual;
    modifier ownerOnly virtual;

    function pause() external ownerOnly {
        paused = true;
    }
    function resume() external ownerOnly {
        paused = false;
    }

    function registerAction(ActionType actionType,  bool blockReentry) external override virtual onlySessionManager returns (ActionParams memory actionParams) {
        require(! paused, "System paused");
        require(actionType != ActionType.None, "Invalid ActionType Type");

        if (blockReentry) {
            for (uint256 i; i <= stackPointer; i++) {
                require(actionStack[i] != actionType, "Reentry found");
            }
        }

        // reading stackPointer costs 5,000 gas, while updating costs 20,000 gas.
        if ( ! (stackPointer == 0 && actionStack[0] == ActionType.None) ) stackPointer ++;
        require(stackPointer < actionStack.length, "Action stack overflow");

        actionStack[stackPointer] = actionType;

        actionParams.actionType = actionType;
        actionParams.isUserAction = stackPointer == 0;
        
        uint256 _session = uint256(keccak256(abi.encode(block.number, tx.origin)));
        if (session != _session) {
            lastSession = session;
            session = _session;
        }

        actionParams.session = session;
        actionParams.lastSession = lastSession;
    }

    function unregisterAction() external override onlySessionManager {
        // reading stackPointer costs 5,000 gas, while updating costs 20,000 gas.
        // save gas: require(stackPointer < actionStack.length, "Session stack overflow");
        // save gas: ActionType actionType = actionStack[stackPointer];
        // save gas: assert(actionType != ActionType.None);
        actionStack[stackPointer] = ActionType.None;

        if (stackPointer > 0) stackPointer --;      
    }
}