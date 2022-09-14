// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./interfaces/IConstants.sol";
import "./interfaces/ISessionRegistrar.sol";
import "./interfaces/ISessionManager.sol";

abstract contract SessionManager is ISessionManager {

    ActionParams actionParams;
    ISessionRegistrar sessionRegistrar;
    ISessionFees sessionFees;

    function _openAction(ActionType actionType, bool blockReentry) internal {
        actionParams = sessionRegistrar.registerAction(actionType, blockReentry);
    }
    function _closeAction() internal {
        sessionRegistrar.unregisterAction();
    }

    function _payFeeCrss(address account, uint256 principal, FeeRates memory rates, bool fromAllowance ) internal virtual returns (uint256 feesPaid) {
        feesPaid = sessionFees.payFeeCrssLogic(account, principal, rates, fromAllowance);
    }
}