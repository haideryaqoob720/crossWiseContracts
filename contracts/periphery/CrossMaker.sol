// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "../session/Node.sol";
import "../libraries/WireLibrary.sol";
import "./interfaces/IMaker.sol";
import "../session/SessionManager.sol";
import "./interfaces/IControlCenter.sol";
import "../libraries/utils/TransferHelper.sol";
import "../libraries/CrossLibrary.sol";
import "../libraries/math/SafeMath.sol";
import "../core/interfaces/ICrossFactory.sol";
import "./interfaces/IWETH.sol";

interface IBalanceLedger {
    function balanceOf(address account) external view returns (uint256);
}

contract CrossMaker is Node, IMaker, Ownable, SessionManager {
    using SafeMath for uint256;

    address public immutable override WETH;

    string private sForbidden = "CrossTaker: Forbidden";
    string private sInvalidPath = "CrossTaker: Invalid path";
    string private sInsufficientOutput = "CrossTaker: Insufficient output amount";
    string private sInsufficientA = "CrossTaker: Insufficient A amount";
    string private sInsufficientB = "CrossTaker: Insufficient B amount";
    string private sExcessiveInput = "CrossTaker: Excessive input amount";
    string private sExpired = "CrossTaker: Expired";

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, sExpired);
        _;
    }

    constructor(address _WETH) Ownable() Node(NodeType.Maker) {
        WETH = _WETH;

        trackFeeStores = true;
        trackFeeRates = true;
        trackPairStatus = true;
    }

    receive() external payable {
        assert(msg.sender == WETH); // only accept ETH via fallback from the WETH contract
    }

    function getOwner() public view override returns (address) {
        return owner();
    }

    function setNode(
        NodeType nodeType,
        address node,
        address caller
    ) public virtual override wired {
        if (caller != address(this)) {
            // let caller be address(0) when an actor initiats this loop.
            WireLibrary.setNode(nodeType, node, nodes);
            if (nodeType == NodeType.Token) {
                sessionRegistrar = ISessionRegistrar(node);
                sessionFees = ISessionFees(node);
            }
            address trueCaller = caller == address(0) ? address(this) : caller;
            INode(nextNode).setNode(nodeType, node, trueCaller);
        } else {
            emit SetNode(nodeType, node);
        }
    }

    function getReserveOnETHPair(address _token) external view virtual override returns (uint256 reserve) {
        (uint256 reserve0, uint256 reserve1) = CrossLibrary.getReserves(nodes.factory, _token, WETH);
        (address token0, ) = CrossLibrary.sortTokens(_token, WETH);
        reserve = token0 == _token ? reserve0 : reserve1;
    }

    // **** ADD LIQUIDITY ****
    function _addLiquidity(
        // Get amounts to transfer to the pair fee of fees.
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal virtual returns (uint256 amountA, uint256 amountB) {
        if (ICrossFactory(nodes.factory).getPair(tokenA, tokenB) == address(0)) {
            ICrossFactory(nodes.factory).createPair(tokenA, tokenB);
        }
        (uint256 reserveA, uint256 reserveB) = CrossLibrary.getReserves(nodes.factory, tokenA, tokenB);

        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint256 amountBOptimal = CrossLibrary.quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                require(amountBOptimal >= amountBMin, sInsufficientB);
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = CrossLibrary.quote(amountBDesired, reserveB, reserveA);
                assert(amountAOptimal <= amountADesired);
                require(amountAOptimal >= amountAMin, sInsufficientA);
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }

        require(amountA >= amountAMin, sInsufficientA);
        require(amountB >= amountBMin, sInsufficientB);
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        virtual
        override
        ensure(deadline)
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        )
    {
        _openAction(ActionType.AddLiquidity, true);

        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);

        address pair = pairFor[tokenA][tokenB];
        _checkEnlisted(pair);

        CrossLibrary.lightTransferFrom(tokenA, msg.sender, pair, amountA, nodes.token);
        CrossLibrary.lightTransferFrom(tokenB, msg.sender, pair, amountB, nodes.token);
        liquidity = ICrossPair(pair).mint(address(this));

        if (tokenA == nodes.token || tokenB == nodes.token) liquidity -= _payTransactionFeeLP(pair, liquidity);
        TransferHelper.safeTransfer(pair, to, liquidity);

        _closeAction();
    }

    function wired_addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        virtual
        override
        ensure(deadline)
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        )
    {
        require(_msgSender() == nodes.farm, sForbidden);

        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);

        address pair = pairFor[tokenA][tokenB];
        _checkEnlisted(pair);

        CrossLibrary.lightTransferFrom(tokenA, msg.sender, pair, amountA, nodes.token);
        CrossLibrary.lightTransferFrom(tokenB, msg.sender, pair, amountB, nodes.token);
        liquidity = ICrossPair(pair).mint(address(this));

        if (tokenA == nodes.token || tokenB == nodes.token) liquidity -= _payTransactionFeeLP(pair, liquidity);
        TransferHelper.safeTransfer(pair, to, liquidity);
    }

    function _payTransactionFeeLP(address lp, uint256 principal) internal virtual returns (uint256 feesPaid) {
        if (actionParams.isUserAction) {
            feesPaid = CrossLibrary.transferFeesFrom(
                lp,
                address(this),
                principal,
                feeRates[actionParams.actionType],
                feeStores,
                nodes.token,
                true
            );
        }
    }

    function addLiquidityETH(
        address _token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    )
        external
        payable
        virtual
        override
        ensure(deadline)
        returns (
            uint256 amountToken,
            uint256 amountETH,
            uint256 liquidity
        )
    {
        _openAction(ActionType.AddLiquidity, true);

        (amountToken, amountETH) = _addLiquidity(
            _token,
            WETH,
            amountTokenDesired,
            msg.value,
            amountTokenMin,
            amountETHMin
        );
        address pair = pairFor[_token][WETH];
        _checkEnlisted(pair);

        CrossLibrary.lightTransferFrom(_token, msg.sender, pair, amountToken, nodes.token);
        IWETH(WETH).deposit{value: amountETH}();
        assert(IWETH(WETH).transfer(pair, amountETH));
        liquidity = ICrossPair(pair).mint(address(this)); // all arrive.
        if (_token == nodes.token) liquidity -= _payTransactionFeeLP(pair, liquidity);
        TransferHelper.safeTransfer(pair, to, liquidity);
        // refund dust eth, if any
        if (msg.value > amountETH) TransferHelper.safeTransferETH(msg.sender, msg.value - amountETH);

        _closeAction();
    }

    // **** REMOVE LIQUIDITY ****
    function _removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to
    ) internal virtual returns (uint256 amountA, uint256 amountB) {
        address pair = pairFor[tokenA][tokenB];

        PairSnapshot memory pairSnapshot = PairSnapshot(pair, address(0), address(0), 0, 0, 0, 0);
        (pairSnapshot.reserve0, pairSnapshot.reserve1, ) = ICrossPair(pair).getReserves();
        IControlCenter(nodes.center).capturePairStateAtSessionDetect(actionParams.session, pairSnapshot); // Liquidity control

        if (ICrossPair(pair).balanceOf(msg.sender) < liquidity) {
            liquidity = ICrossPair(pair).balanceOf(msg.sender);
        }

        TransferHelper.safeTransferFrom(pair, msg.sender, address(this), liquidity);
        if (tokenA == nodes.token || tokenB == nodes.token) liquidity -= _payTransactionFeeLP(pair, liquidity);
        TransferHelper.safeTransfer(pair, pair, liquidity);
        (uint256 amount0, uint256 amount1) = ICrossPair(pair).burn(to);

        (pairSnapshot.reserve0, pairSnapshot.reserve1, ) = ICrossPair(pair).getReserves();
        if (msg.sender != owner()) IControlCenter(nodes.center).ruleOutInvalidLiquidity(pairSnapshot); // Liquidity control

        (pairSnapshot.token0, pairSnapshot.token1) = CrossLibrary.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == pairSnapshot.token0 ? (amount0, amount1) : (amount1, amount0);

        require(amountA >= amountAMin, sInsufficientA);
        require(amountB >= amountBMin, sInsufficientB);
    }

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) public virtual override ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        _openAction(ActionType.RemoveLiquidity, true);

        (amountA, amountB) = _removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to);

        _closeAction();
    }

    function wired_removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) public virtual override ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        require(_msgSender() == nodes.farm, sForbidden);

        (amountA, amountB) = _removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to);
    }

    function sim_removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity
    ) external view virtual override returns (uint256 amountA, uint256 amountB) {
        address pair = pairFor[tokenA][tokenB];

        if (ICrossPair(pair).balanceOf(msg.sender) < liquidity) {
            liquidity = ICrossPair(pair).balanceOf(msg.sender);
        }

        (uint256 amount0, uint256 amount1) = ICrossPair(pair).sim_burn(liquidity);

        (address token0, ) = CrossLibrary.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
    }

    function removeLiquidityETH(
        address _token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) public virtual override ensure(deadline) returns (uint256 amountToken, uint256 amountETH) {
        _openAction(ActionType.RemoveLiquidity, true);

        (amountToken, amountETH) = _removeLiquidity(
            _token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this)
        );
        CrossLibrary.lightTransferFrom(_token, address(this), to, amountToken, nodes.token);
        IWETH(WETH).withdraw(amountETH);
        TransferHelper.safeTransferETH(to, amountETH);

        _closeAction();
    }

    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external virtual override returns (uint256 amountA, uint256 amountB) {
        address pair = pairFor[tokenA][tokenB];
        uint256 value = approveMax ? type(uint256).max : liquidity;
        ICrossPair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        (amountA, amountB) = removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline);
    }

    function removeLiquidityETHWithPermit(
        address _token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external virtual override returns (uint256 amountToken, uint256 amountETH) {
        address pair = pairFor[_token][WETH];
        uint256 value = approveMax ? type(uint256).max : liquidity;
        ICrossPair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        (amountToken, amountETH) = removeLiquidityETH(_token, liquidity, amountTokenMin, amountETHMin, to, deadline);
    }

    // **** REMOVE LIQUIDITY (supporting fee-on-transfer tokens) ****

    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address _token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) public virtual override ensure(deadline) returns (uint256 amountETH) {
        _openAction(ActionType.RemoveLiquidity, true);

        uint256 balance0 = IERC20(_token).balanceOf(address(this));
        (, amountETH) = _removeLiquidity(_token, WETH, liquidity, amountTokenMin, amountETHMin, address(this));
        CrossLibrary.lightTransferFrom(
            _token,
            address(this),
            to,
            IERC20(_token).balanceOf(address(this)) - balance0,
            nodes.token
        );
        IWETH(WETH).withdraw(amountETH);
        TransferHelper.safeTransferETH(to, amountETH);

        _closeAction();
    }

    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address _token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external virtual override returns (uint256 amountETH) {
        address pair = pairFor[_token][WETH];
        uint256 value = approveMax ? type(uint256).max : liquidity;
        ICrossPair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        amountETH = removeLiquidityETHSupportingFeeOnTransferTokens(
            _token,
            liquidity,
            amountTokenMin,
            amountETHMin,
            to,
            deadline
        );
    }

    // **** LIBRARY FUNCTIONS ****
    function quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) public pure virtual override returns (uint256 amountB) {
        return CrossLibrary.quote(amountA, reserveA, reserveB);
    }

    function getPair(address tokenA, address tokenB) external view virtual override returns (address pair) {
        return ICrossFactory(nodes.factory).getPair(tokenA, tokenB);
    }
}
