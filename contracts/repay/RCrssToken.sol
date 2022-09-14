// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IRCrssToken.sol";

contract RCrssToken is IRCrssToken, Ownable {
    //==================== ERC20 core data ====================
    string private constant _name = "RCRSS Token";
    string private constant _symbol = "RCRSS";
    uint8 private constant _decimals = 18;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    //==================== Basic ERC20 functions ====================
    function name() public view virtual returns (string memory) {
        return _name;
    }

    function symbol() public view virtual returns (string memory) {
        return _symbol;
    }

    function decimals() public view virtual returns (uint8) {
        return _decimals;
    }

    function totalSupply() public view virtual override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view virtual override returns (uint256) {
        return _balances[account];
    }

    function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public virtual override returns (bool) {
        if (sender != _msgSender()) {
            uint256 currentAllowance = _allowances[sender][_msgSender()];
            require(currentAllowance >= amount, "Transfer amount exceeds allowance");
            _approve(sender, _msgSender(), currentAllowance - amount);
        }
        _transfer(sender, recipient, amount); // No guarentee it doesn't make a change to _allowances. Revert if it fails.

        return true;
    }

    function allowance(address _owner, address _spender) public view virtual override returns (uint256) {
        return _allowances[_owner][_spender];
    }

    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal virtual {
        require(sender != address(0), sZeroAddress);
        require(recipient != address(0), sZeroAddress);

        uint256 senderBalance = _balances[sender];
        require(senderBalance >= amount, sExceedsBalance);

        //_beforeTokenTransfer(sender, recipient, amount);
        _balances[sender] = senderBalance - amount;
        _balances[recipient] += amount;
        //_afterTokenTransfer(sender, recipient, amount);

        emit Transfer(sender, recipient, amount);
    }

    function _approve(
        address _owner,
        address _spender,
        uint256 _amount
    ) internal virtual {
        require(_owner != address(0), sZeroAddress);
        require(_spender != address(0), sZeroAddress);
        _allowances[_owner][_spender] = _amount;
        emit Approval(_owner, _spender, _amount);
    }

    //----------------------------------- Compensation ---------------------------------

    address[] public override victims;
    string private constant sZeroAddress = "RCRSS: Zero address";
    string private constant sExceedsBalance = "RCRSS: Exceeds balance";

    function victimsLen() external view override returns (uint256) {
        return victims.length;
    }

    function _mintRepayToken(address account, uint256 amount) internal {
        //require(victim != address(0) && lossAmount != 0 && _balances[victim] == 0, "Invalid loss");
        _balances[account] += amount;
        _totalSupply += amount;
        // victims.push(victim);
    }

    constructor() Ownable() {}

    function loadSplit(Loss[] calldata losses) public onlyOwner {
        for (uint256 i = 0; i < losses.length; i++) {
            _mintRepayToken(losses[i].victim, losses[i].amount);
        }
    }
}
