// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

import "../session/Node.sol";
//import "../periphery/interfaces/ICrossRouter.sol";
import "./CrossPair.sol";
import "./interfaces/ICrossFactory.sol";

contract CrossFactory is Node, ICrossFactory, Ownable {
    bytes32 public constant INIT_CODE_PAIR_HASH = keccak256(abi.encodePacked(type(CrossPair).creationCode));

    address public override feeTo;      
    address[] public override allPairs;
    mapping (address => bool) tokenListed;

    constructor() Ownable() Node(NodeType.Factory) {
        trackPairStatus = true;
    }

    function getPair(address tokenA, address tokenB) external view override virtual returns (address pair) {
        return pairFor[tokenA][tokenB];
    }

    function getOwner() public view override returns (address) {
        return owner();
    }

    function setNode(NodeType nodeType, address node, address caller) public override {
        if (caller != address(this)) {  // let caller be address(0) when an actor initiats this loop
            WireLibrary.setNode(nodeType, node, nodes);
            if (nodeType == NodeType.Token || nodeType == NodeType.Maker || nodeType == NodeType.Taker || nodeType == NodeType.Farm ) {
                for (uint256 i = 0; i < allPairs.length; i++) {
                    ICrossPair(allPairs[i]).setNodes(nodes.token, nodes.maker, nodes.taker, nodes.farm);
                }
            }
            address trueCaller = caller == address(0) ? address(this) : caller;
            INode(nextNode).setNode(nodeType, node, trueCaller);
        } else {
            emit SetNode(nodeType, node);
        }
    }

    function changeTokenStatus(address token, ListStatus status) public override virtual onlyOwner {
        if (status == ListStatus.Enlisted) {
            _listToken(token, true);
        } else if (status == ListStatus.Delisted) {
            _listToken(token, false);
        } else if (status == ListStatus.Cleared) {
            _listToken(token,false);
            _removePairs(token);
        }
        emit ChangeTokenStatus(token, status);
    }

    function _listToken(address token, bool enlist) internal {
        tokenListed[token] = enlist;
        ListStatus targetStatue = enlist? ListStatus.Enlisted : ListStatus.Delisted;
        this.changePairStatus(token, token, token, targetStatue, address(0)); // Propagate to all nodes, the "token"-staking pool's status.

        for (uint256 k; k < allPairs.length; k++) {
            if (_isRelated(allPairs[k], token)) {
                ICrossPair(allPairs[k]).changeStatus(targetStatue);
                this.changePairStatus( allPairs[k], ICrossPair(allPairs[k]).token0(), 
                    ICrossPair(allPairs[k]).token1(), targetStatue, address(0)
                );
            }
        }
    }

    function _removePairs(address token) internal {
        uint256 step = 1;
        for (uint256 k; k < allPairs.length; k += step) {
            if (_isRelated(allPairs[k], token)) {
                this.changePairStatus( allPairs[k], address(0), address(0), ListStatus.None, address(0) ); // free storage.

                if (k < allPairs.length - 1) {
                    allPairs[k] = allPairs[allPairs.length-1];
                }
                allPairs.pop(); step = 0;

            } else {
                step = 1;
            }
        }
    }

    function _isRelated(address pair, address token) internal view returns (bool) {
        return ICrossPair(pair).token0() == token || ICrossPair(pair).token1() == token;
    }

    function allPairsLength() external view override returns (uint256) {
        return allPairs.length;
    }


    function createPair(address tokenA, address tokenB) external override returns (address pair) {
        require(tokenListed[tokenA] && tokenListed[tokenB], "Invalid token");
        require(nodes.maker != address(0), "No CrossMaker");
        require(nodes.taker != address(0), "No CrossTaker");
        require(nodes.farm != address(0), "No CrossFarm");
        require(tokenA != tokenB, "Identical tokens");
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "Zero address token");
        require(pairFor[token0][token1] == address(0), "Existing pair"); // single check is sufficient
        bytes memory bytecode = type(CrossPair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        ICrossPair(pair).initialize(token0, token1);
        ICrossPair(pair).setNodes(nodes.token, nodes.maker, nodes.taker, nodes.farm);
        
        INode(this).changePairStatus(pair, token0, token1, ListStatus.Enlisted, address(0));
        allPairs.push(pair);

        emit PairCreated(token0, token1, pair);
    }

    function setFeeTo(address _feeTo) external override {
        require(_msgSender() == owner(), "Caller != owner");
        feeTo = _feeTo;
    }
}
