// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
interface IRCrssToken is IERC20 {

    struct Loss {
        address victim;
        uint256 amount;
    }

    function victims (uint256) external returns (address);
    function victimsLen () external returns (uint256);
}