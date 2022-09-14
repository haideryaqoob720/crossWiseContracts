// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/ICrssReferral.sol";

contract CrssReferral is ICrssReferral, Ownable {
    mapping(address => address) public referrers; // user address => referrer address
    mapping(address => uint256) public countReferrals; // referrer address => referrals count
    mapping(address => uint256) public totalReferralCommissions; // referrer address => total referral commissions
    mapping(address => uint256) public outstandingCommissions;

    event ReferralRecorded(address indexed user, address indexed referrer);
    event ReferralCommissionRecorded(address indexed referrer, uint256 commission);
    event OperatorUpdated(address indexed operator, bool indexed status);

    address public payer;
    constructor() Ownable() {
    }

    function setPayer(address _payer) external onlyOwner {
        payer = _payer;
    }

    function recordReferral(address _user, address _referrer) public override {
        require( _msgSender() == payer, "Only payer can record referrers");
        referrers[_user] = _referrer;
        countReferrals[_referrer] += 1;
        emit ReferralRecorded(_user, _referrer);
    }

    function recordReferralCommission(address _referrer, uint256 _commission) public override {
        require( _msgSender() == payer, "Only payer can record commission");
        totalReferralCommissions[_referrer] += _commission;
        outstandingCommissions[_referrer] += _commission;
        emit ReferralCommissionRecorded(_referrer, _commission);
    }

    function getOutstandingCommission(address _referrer) external view override returns (uint256 amount) {
        amount = outstandingCommissions[_referrer];
    }

    function debitOutstandingCommission(address _referrer, uint256 _debit) external override {
        require( _msgSender() == payer, "Only payer can debit outstanding commission");
        outstandingCommissions[_referrer] -= _debit;
    }

    // Get the referrer address that referred the user
    function getReferrer(address _user) public view override returns (address) {
        return referrers[_user];
    }
}
