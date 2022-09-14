// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../session/interfaces/IConstants.sol";
import "../core/interfaces/ICrossPair.sol";
import "../core/interfaces/ICrossFactory.sol";
import "./utils/TransferHelper.sol";
import "./math/SafeMath.sol";
import "./CrossLibrary.sol";
import "../periphery/interfaces/IWETH.sol";

library RouterLibrary {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    function test() external {}

    function swapStep(
        uint256[] memory amounts,
        address[] memory path,
        address to,
        PairSnapshot memory pairSnapshot,
        address factory,
        uint256 step
    ) external {
        (address input, address output) = (path[step], path[step + 1]);
        ICrossPair pair = ICrossPair(pairSnapshot.pair);

        uint256 amountOut = amounts[step + 1];
        (uint256 amount0Out, uint256 amount1Out) = input == pairSnapshot.token0
            ? (uint256(0), amountOut)
            : (amountOut, uint256(0));
        address _to = step < path.length - 2 ? CrossLibrary.pairFor(factory, output, path[step + 2]) : to;
        pair.swap(amount0Out, amount1Out, _to, new bytes(0));
    }

    function swapStepSupportingFee(
        address[] memory path,
        address to,
        PairSnapshot memory pairSnapshot,
        address factory,
        uint256 step
    ) external {
        ICrossPair pair = ICrossPair(pairSnapshot.pair);
        (address input, address output) = (path[step], path[step + 1]);

        uint256 amountOutput;
        {
            uint256 amountInput;
            (uint256 reserveInput, uint256 reserveOutput) = input == pairSnapshot.token0
                ? (pairSnapshot.reserve0, pairSnapshot.reserve1)
                : (pairSnapshot.reserve1, pairSnapshot.reserve0);
            amountInput = IERC20(input).balanceOf(address(pair)).sub(reserveInput);
            amountOutput = CrossLibrary.getAmountOut(amountInput, reserveInput, reserveOutput);
        }

        (uint256 amount0Out, uint256 amount1Out) = input == pairSnapshot.token0
            ? (uint256(0), amountOutput)
            : (amountOutput, uint256(0));
        address _to = step < path.length - 2 ? CrossLibrary.pairFor(factory, output, path[step + 2]) : to;
        pair.swap(amount0Out, amount1Out, _to, new bytes(0));
    }
}
