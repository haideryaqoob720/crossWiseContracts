// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./IPancakePair.sol";
import "../../session/interfaces/IConstants.sol";

interface ICrossPair is IPancakePair {
    function initialize(address, address) external;
    function setNodes(address token, address maker, address taker, address farm) external;
    function status() external view returns (ListStatus);
    function changeStatus(ListStatus _status) external;
    function sim_burn(uint256 liquidity) external view returns (uint256 amount0, uint256 amount1);
}
