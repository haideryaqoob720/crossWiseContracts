// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./IPancakeRouter02.sol";

interface ICrossRouter is IPancakeRouter02 {
    function getReserveOnETHPair(address token) external view returns (uint256 reserve);
}
