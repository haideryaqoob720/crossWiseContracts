// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

import "./interfaces/ICrssToken.sol";
import "../session/SessionRegistrar.sol";
import "../session/SessionManager.sol";
import "../session/SessionFees.sol";
import "../session/Node.sol";
import "../libraries/WireLibrary.sol";
import "../periphery/interfaces/IMaker.sol";
import "../periphery/interfaces/ITaker.sol";
import "../core/interfaces/ICrossFactory.sol";
import "../core/interfaces/ICrossPair.sol";
import "../farm/interfaces/ICrossFarm.sol";
import "../libraries/math/SafeMath.sol";

// CrssToken with Governance.
contract CrssToken is Node, Ownable, ICrssToken, SessionRegistrar, SessionFees, SessionManager {
    using SafeMath for uint256;

    //==================== ERC20 core data ====================
    string private constant _name = "Crosswise Token";
    string private constant _symbol = "CRSS";
    uint8 private constant _decimals = 18;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    //==================== Constants ====================
    string private constant sForbidden = "Forbidden";
    string private constant sZeroAddress = "Zero address";
    string private constant sExceedsBalance = "Exceeds balance";
    uint256 public constant override maxSupply = 50 * 1e6 * 10**_decimals;

    //==================== Transfer control attributes ====================
    struct TransferAmountSession {
        uint256 sent;
        uint256 received;
        uint256 session;
    }
    mapping(address => TransferAmountSession) accTransferAmountSession;
    uint256 public override maxTransferAmountRate; // rate based on FeeMagnifier.
    uint256 public maxTransferAmount;
    address[] transferUsers;

    //==================== Governance ====================
    mapping(address => address) internal _delegates;
    struct Checkpoint {
        uint32 fromBlock;
        uint256 votes;
    }
    mapping(address => mapping(uint32 => Checkpoint)) public checkpoints;
    mapping(address => uint32) public numCheckpoints;
    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");
    bytes32 public constant DELEGATION_TYPEHASH =
        keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");
    mapping(address => uint256) public nonces;
    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);
    event DelegateVotesChanged(address indexed delegate, uint256 previousBalance, uint256 newBalance);
    event SwapAndLiquify(uint256 crssPart, uint256 crssForEthPart, uint256 ethPart, uint256 liquidity);

    receive() external payable {}

    constructor() Ownable() Node(NodeType.Token) {
        sessionRegistrar = ISessionRegistrar(address(this));
        sessionFees = ISessionFees(address(this));

        maxTransferAmountRate = 5000; // 5%

        trackFeeStores = true;
        trackFeeRates = true;
        trackPairStatus = true;

        // Mint 1e6 Crss to the caller for testing - MUST BE REMOVED BEFORE DEPLOY
        _mint(_msgSender(), 1e6 * 10**_decimals);
    }

    //==================== Modifiers. Some of them required by super classes ====================
    modifier onlySessionManager() virtual override(SessionFees, SessionRegistrar) {
        address msgSender = _msgSender();
        require(
            msgSender == nodes.token ||
                msgSender == nodes.maker ||
                msgSender == nodes.taker ||
                msgSender == nodes.farm ||
                msgSender == nodes.repay,
            "Not a session manager"
        );
        _;
    }

    modifier ownerOnly() virtual override {
        require(_msgSender() == owner(), "Not owner");
        _;
    }

    function getOwner() public view override returns (address) {
        return owner();
    }

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

    //==================== Intrinsic + business internal logic ====================

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {}

    function _afterTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {}

    function _mint(address to, uint256 amount) internal virtual {
        require(to != address(0), sZeroAddress);

        _beforeTokenTransfer(address(0), to, amount);
        _totalSupply += amount;
        _balances[to] += amount;
        _afterTokenTransfer(address(0), to, amount);

        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal virtual {
        require(from != address(0), sZeroAddress);
        uint256 accountBalance = _balances[from];
        require(accountBalance >= amount, sExceedsBalance);

        _beforeTokenTransfer(from, address(0), amount);
        _balances[from] = accountBalance - amount;
        _totalSupply -= amount;
        _afterTokenTransfer(from, address(0), amount);

        emit Transfer(from, address(0), amount);
    }

    /**
     * @dev Implements the business logic of the tansfer and transferFrom funcitons.
     * Collect transfer fee if the calling transfer functions are a top session,
     * or, equivalently, an external actor invoked the transfer.
     * If the transfer is 100% of transfer amount if  external actor wants to transfer to a pool created by CrossFactory.
     */
    function _transferHub(
        address sender,
        address recipient,
        uint256 amount
    ) internal virtual {
        _openAction(ActionType.Transfer, true);

        _limitTransferPerSession(sender, recipient, amount);

        if (actionParams.isUserAction) {
            // transfer call coming from external actors.
            FeeRates memory rates;
            if (pairs[recipient].token0 != address(0)) {
                // An injection detected!
                rates = FeeRates(uint32(FeeMagnifier)); // 100% fee.
            } else {
                if (pairs[sender].token0 != address(0) || sender == address(this) || recipient == address(this)) {
                    rates = FeeRates(0);
                } else {
                    rates = feeRates[ActionType.Transfer];
                }
            }

            amount -= _payFeeCrss(sender, amount, rates, false); // Free of nested recurssion
        }

        if (amount > 0) {
            _transfer(sender, recipient, amount);
            //_moveDelegates(_delegates[sender], _delegates[recipient], amount);
        }

        _closeAction();
    }

    function transferDirectSafe(
        address sender,
        address recipient,
        uint256 amount
    ) external virtual override {
        address msgSender = _msgSender();
        require(
            msgSender == nodes.farm ||
                msgSender == nodes.taker ||
                msgSender == nodes.maker ||
                msgSender == nodes.repay ||
                pairs[msgSender].token0 != address(0), // coming from a pair
            sForbidden
        );

        if (amount > _balances[sender]) amount = _balances[sender];
        require(amount > 0, "Insufficient amount");
        _transfer(sender, recipient, amount);
        //_moveDelegates(_delegates[sender], _delegates[recipient], amount);
    }

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal virtual {
        require(sender != address(0) && recipient != address(0), sZeroAddress);
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

    function _increaseAllowance(
        address _owner,
        address _spender,
        uint256 addedValue
    ) internal virtual returns (bool) {
        require(_owner != address(0), sZeroAddress);
        _approve(_owner, _spender, _allowances[_owner][_spender] + addedValue);
        return true;
    }

    function _decreaseAllowance(
        address _owner,
        address _spender,
        uint256 subtractedValue
    ) public virtual returns (bool) {
        require(_owner != address(0), sZeroAddress);
        _approve(_owner, _spender, _allowances[_owner][_spender] - subtractedValue);
        return true;
    }

    //==================== Main ERC20 funcitons, working on intrinsic + business internal logic ====================
    function mint(address to, uint256 amount) public override {
        require(_totalSupply + amount <= maxSupply, "Exceed Max Supply");
        require(_msgSender() == nodes.farm || _msgSender() == nodes.repay, sForbidden);
        _mint(to, amount);
        //_moveDelegates(address(0), _delegates[to], amount);
    }

    function burn(address from, uint256 amount) public override {
        require(_msgSender() == nodes.farm || _msgSender() == nodes.repay, sForbidden);
        _burn(from, amount);
        //_moveDelegates(_delegates[from], _delegates[address(0)], amount);
    }

    function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
        _transferHub(_msgSender(), recipient, amount);
        return true;
    }

    function tolerableTransfer(
        address from,
        address to,
        uint256 value
    ) external virtual override returns (bool) {
        require(_msgSender() == nodes.farm || _msgSender() == nodes.repay, "Forbidden");
        if (value > _balances[from]) value = _balances[from];
        _transferHub(_msgSender(), to, value);
        return true;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public virtual override returns (bool) {
        if (sender != _msgSender()) {
            uint256 currentAllowance = _allowances[sender][_msgSender()];
            require(currentAllowance >= amount, "Transfer exceeds allowance");
            _allowances[sender][_msgSender()] -= amount;
        }
        _transferHub(sender, recipient, amount); // No guarentee it doesn't make a change to _allowances. Revert if it fails.

        return true;
    }

    function allowance(address _owner, address _spender) public view virtual override returns (uint256) {
        return _allowances[_owner][_spender];
    }

    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        return _increaseAllowance(_msgSender(), spender, addedValue);
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        return _decreaseAllowance(_msgSender(), spender, subtractedValue);
    }

    //==================== Business logic ====================

    function changeMaxTransferAmountRate(uint256 _maxTransferAmountRate) external virtual override onlyOwner {
        require(
            FeeMagnifier / 1000 <= _maxTransferAmountRate && // 0.1% totalSupply <= maxTransferRate
                _maxTransferAmountRate <= FeeMagnifier / 20, // maxTransferRate <= 5.0% totalSupply
            "maxTransferAmountRate out of range"
        );
        maxTransferAmountRate = _maxTransferAmountRate;
    }

    /**
     * @dev msg.sender collects fees from payer, only called by sesison managers - this, maker, taker, and farm.
     * fromAllowance: whether the fee should be subtracted from the allowance that the payer approved to the msg.caller.
     * develp fee is paid to develop account
     * buyback fee is paid to buyback account
     * liquidity fee is liqufied to the Crss/Bnb pool.
     * If liquidity fees are accumulated to a certain degree, they are liquified.
     */
    function payFeeCrssLogic(
        address payer,
        uint256 principal,
        FeeRates calldata rates,
        bool fromAllowance
    ) public virtual override onlySessionManager returns (uint256 feesPaid) {
        if (principal != 0) {
            if (rates.accountant != 0) {
                feesPaid += _payFeeImplementation(
                    payer,
                    principal,
                    rates.accountant,
                    feeStores.accountant,
                    fromAllowance
                );
            }
            // if (rates.buyback != 0) {
            //     feesPaid += _payFeeImplementation(payer, principal, rates.buyback, feeStores.buyback, fromAllowance);
            // }
            // if (rates.liquidity != 0) {
            //     feesPaid += _payFeeImplementation(
            //         payer,
            //         principal,
            //         rates.liquidity,
            //         feeStores.liquidity,
            //         fromAllowance
            //     );
            //     // uint256 crssOnCrssBnbPair = IMaker(nodes.maker).getReserveOnETHPair(address(this));
            //     // uint256 liquidityFeeAccumulated = _balances[feeStores.liquidity];
            //     // if ( liquidityFeeAccumulated * 500 >= crssOnCrssBnbPair ) {
            //     //     _liquifyLiquidityFees();
            //     //     // If there is ETH residue.
            //     //     uint256 remainETH = address(this).balance;
            //     //     if (remainETH >= 10 ** 17) {
            //     //         (bool sent, ) = feeStores.develop.call{value: remainETH}("");
            //     //         require(sent, "Failed to send Ether");
            //     //     }
            //     // }
            // }
            // if (rates.treasury != 0) {
            //     feesPaid += _payFeeImplementation(payer, principal, rates.treasury, feeStores.treasury, fromAllowance);
            // }
        }
    }

    function _payFeeImplementation(
        address payer,
        uint256 principal,
        uint256 rate,
        address payee,
        bool fromAllowance
    ) internal virtual returns (uint256 feePaid) {
        feePaid = (principal * rate) / FeeMagnifier;
        _transfer(payer, payee, feePaid);
        if (fromAllowance) _decreaseAllowance(payer, _msgSender(), feePaid);
        //_moveDelegates(_delegates[payer], _delegates[payee], feePaid);
    }

    /**
     * @dev Prevent excessive net transfer amount of a single account during a single session.
     * Refer the SessionRegistrar._seekInitializeSession(...) for the meaning of session.
     */
    function _limitTransferPerSession(
        address sender,
        address recipient,
        uint256 amount
    ) internal virtual {
        if ((sender == owner() || sender == address(this)) && pairs[recipient].token0 != address(0)) {
            // they are sending to an open pool.
            require(pairs[recipient].token0 == address(this) || pairs[recipient].token1 == address(this), sForbidden); // let it be a crss/--- pool.
        } else {
            if (actionParams.session != actionParams.lastSession) {
                // Refresh maxTransferAmount every session.
                maxTransferAmount = _totalSupply.mul(maxTransferAmountRate).div(FeeMagnifier);
                if (transferUsers.length > 2000) _freeUpTransferUsersSpace();
            }

            _initializeTransferUser(sender);
            accTransferAmountSession[sender].sent += amount;

            _initializeTransferUser(recipient);
            accTransferAmountSession[recipient].received += amount;

            require(
                accTransferAmountSession[sender].sent.abs(accTransferAmountSession[sender].received) <
                    maxTransferAmount &&
                    accTransferAmountSession[recipient].sent.abs(accTransferAmountSession[recipient].received) <
                    maxTransferAmount,
                "Exceed MaxTransferAmount"
            );
        }
    }

    function _initializeTransferUser(address user) internal virtual {
        if (accTransferAmountSession[user].session == 0) transferUsers.push(user); // A new user. Register them.
        if (accTransferAmountSession[user].session != actionParams.session) {
            // A new user, or an existing user involved in a previous session.
            accTransferAmountSession[user].sent = 0;
            accTransferAmountSession[user].received = 0;
            accTransferAmountSession[user].session = actionParams.session; // Tag with the current session id.
        }
    }

    function _freeUpTransferUsersSpace() internal virtual {
        uint256 length = transferUsers.length;
        for (uint256 i = 0; i < length; i++) {
            address user = transferUsers[i];
            accTransferAmountSession[user].sent = 0;
            accTransferAmountSession[user].received = 0;
            accTransferAmountSession[user].session = 0;
        }
        delete transferUsers;
        transferUsers = new address[](0);
    }

    // function _liquifyLiquidityFees() internal {
    //     // Assume: this->Pair is free of TransferControl.

    //     uint256 liquidityFeeAccumulated = _balances[feeStores.liquidity];
    //     _transfer(feeStores.liquidity, address(this), liquidityFeeAccumulated);

    //     uint256 crssPart = liquidityFeeAccumulated / 2;
    //     uint256 crssForEthPart = liquidityFeeAccumulated - crssPart;

    //     uint256 initialBalance = address(this).balance;
    //     _swapForETH(crssForEthPart); //
    //     uint256 ethPart = address(this).balance.sub(initialBalance);
    //     uint256 liquidity = _addLiquidity(crssPart, ethPart);

    //     emit SwapAndLiquify(crssPart, crssForEthPart, ethPart, liquidity);
    // }

    function _swapForETH(uint256 tokenAmount) internal {
        // generate the uniswap pair path of token -> WBNB
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = IMaker(nodes.taker).WETH();

        _approve(address(this), address(nodes.taker), tokenAmount);
        ITaker(nodes.taker).swapExactTokensForETH(
            // We know this will open a new nested session, which is not subject to fees.
            tokenAmount,
            0, // in trust of taker's price control.
            path,
            address(this),
            block.timestamp
        );
    }

    function _addLiquidity(uint256 tokenAmount, uint256 ethAmount) internal returns (uint256 liquidity) {
        _approve(address(this), address(nodes.maker), tokenAmount);

        (, , liquidity) = IMaker(nodes.maker).addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0,
            0,
            address(this),
            block.timestamp
        );
    }

    //==================== Governance power ====================

    function _delegate(address delegator, address delegatee) internal {
        address oldDelegate = _delegates[delegator];
        uint256 delegatorBalance = balanceOf(delegator); // balance of underlying CRSSs (not scaled);
        _delegates[delegator] = delegatee;

        emit DelegateChanged(delegator, oldDelegate, delegatee);

        //_moveDelegates(oldDelegate, delegatee, delegatorBalance);
    }

    function delegates(address delegator) external view returns (address) {
        return _delegates[delegator];
    }

    function delegate(address delegatee) external {
        return _delegate(_msgSender(), delegatee);
    }

    function delegateBySig(
        address delegatee,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        bytes32 domainSeparator = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(name())), getChainId(), address(this))
        );

        bytes32 structHash = keccak256(abi.encode(DELEGATION_TYPEHASH, delegatee, nonce, expiry));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        address signatory = ecrecover(digest, v, r, s);
        require(signatory != address(0), "Invalid signature");
        require(nonce == nonces[signatory]++, "Invalid nonce");
        require(block.timestamp <= expiry, "Signature expired");
        return _delegate(signatory, delegatee);
    }

    function getCurrentVotes(address account) external view returns (uint256) {
        uint32 nCheckpoints = numCheckpoints[account];
        return nCheckpoints > 0 ? checkpoints[account][nCheckpoints - 1].votes : 0;
    }

    function getPriorVotes(address account, uint256 blockNumber) external view returns (uint256) {
        require(blockNumber < block.number, "getPriorVotes: not determined yet");

        uint32 nCheckpoints = numCheckpoints[account];
        if (nCheckpoints == 0) {
            return 0;
        }

        // First check most recent balance
        if (checkpoints[account][nCheckpoints - 1].fromBlock <= blockNumber) {
            return checkpoints[account][nCheckpoints - 1].votes;
        }

        // Next check implicit zero balance
        if (checkpoints[account][0].fromBlock > blockNumber) {
            return 0;
        }

        uint32 lower = 0;
        uint32 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint32 center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            Checkpoint memory cp = checkpoints[account][center];
            if (cp.fromBlock == blockNumber) {
                return cp.votes;
            } else if (cp.fromBlock < blockNumber) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return checkpoints[account][lower].votes;
    }

    function safe32(uint256 n, string memory errorMessage) internal pure returns (uint32) {
        require(n < 2**32, errorMessage);
        return uint32(n);
    }

    function getChainId() internal view returns (uint256) {
        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        return chainId;
    }

    function _moveDelegates(
        address srcRep,
        address dstRep,
        uint256 amount
    ) internal {
        if (srcRep != dstRep && amount > 0) {
            if (srcRep != address(0)) {
                // decrease old representative
                uint32 srcRepNum = numCheckpoints[srcRep];
                uint256 srcRepOld = srcRepNum > 0 ? checkpoints[srcRep][srcRepNum - 1].votes : 0;
                uint256 srcRepNew = srcRepOld.sub(amount);
                _writeCheckpoint(srcRep, srcRepNum, srcRepOld, srcRepNew);
            }

            if (dstRep != address(0)) {
                // increase new representative
                uint32 dstRepNum = numCheckpoints[dstRep];
                uint256 dstRepOld = dstRepNum > 0 ? checkpoints[dstRep][dstRepNum - 1].votes : 0;
                uint256 dstRepNew = dstRepOld.add(amount);
                _writeCheckpoint(dstRep, dstRepNum, dstRepOld, dstRepNew);
            }
        }
    }

    function _writeCheckpoint(
        address delegatee,
        uint32 nCheckpoints,
        uint256 oldVotes,
        uint256 newVotes
    ) internal {
        uint32 blockNumber = safe32(block.number, "Block number exceeds 32 bits");

        if (nCheckpoints > 0 && checkpoints[delegatee][nCheckpoints - 1].fromBlock == blockNumber) {
            checkpoints[delegatee][nCheckpoints - 1].votes = newVotes;
        } else {
            checkpoints[delegatee][nCheckpoints] = Checkpoint(blockNumber, newVotes);
            numCheckpoints[delegatee] = nCheckpoints + 1;
        }

        emit DelegateVotesChanged(delegatee, oldVotes, newVotes);
    }
}
