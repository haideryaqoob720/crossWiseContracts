// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.0;

interface ICrssReferral {
    /**
     * @dev Record referral.
     */
    function recordReferral(address user, address referrer) external;

    /**
     * @dev Record referral commission.
     */
    function recordReferralCommission(address referrer, uint256 commission) external;

    /**
     * @dev Get the referrer address that referred the user.
     */
    function getReferrer(address user) external view returns (address);

    function getOutstandingCommission(address _referrer) external view returns (uint256 amount);

    function debitOutstandingCommission(address _referrer, uint256 _debit) external;
}
