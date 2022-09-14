
// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../session/interfaces/IConstants.sol";
interface IControlCenter {
    function capturePairStateAtSessionDetect(uint256 session, PairSnapshot memory pairSnapshot) external;
    function captureInitialPairState(ActionParams memory actionParams, address input, address output) external
    returns (PairSnapshot memory pairSnapshot, bool isNichePair);
    function ruleOutInvalidLiquidity(PairSnapshot memory ps) external view;
    function ruleOutDeviatedPrice(bool isNichePair, PairSnapshot memory pairSnapshot) external;
}
