pragma solidity 0.7.0;

import "./IERC20.sol";
import "./IMintableToken.sol";
import "./IDividends.sol";
import "./SafeMath.sol";

contract Token is IERC20, IMintableToken, IDividends {
  // ------------------------------------------ //
  // ----- BEGIN: DO NOT EDIT THIS SECTION ---- //
  // ------------------------------------------ //
  using SafeMath for uint256;
  uint256 public totalSupply;
  uint256 public decimals = 18;
  string public name = "Test token";
  string public symbol = "TEST";
  mapping (address => uint256) public balanceOf;
  // ------------------------------------------ //
  // ----- END: DO NOT EDIT THIS SECTION ------ //
  // ------------------------------------------ //

  // ERC20 allowances
  mapping (address => mapping (address => uint256)) private _allowances;

  // Holder tracking — 1-indexed array
  // Index 0 holds address(0) as placeholder
  address[] private _holders;
  mapping (address => uint256) private _holderIndex;

  // Dividends owed per address
  mapping (address => uint256) private _withdrawableDividend;

  constructor() {
    // Push placeholder so real holders start at index 1
    _holders.push(address(0));
  }

  // ------------------------------------------ //
  // Holder management
  // ------------------------------------------ //

  function _addHolder(address holder) private {
    if (_holderIndex[holder] == 0) {
      _holders.push(holder);
      _holderIndex[holder] = _holders.length - 1;
    }
  }

  function _removeHolder(address holder) private {
    uint256 index = _holderIndex[holder];
    if (index == 0) return;

    uint256 lastIndex = _holders.length - 1;
    if (index != lastIndex) {
      address lastHolder = _holders[lastIndex];
      _holders[index] = lastHolder;
      _holderIndex[lastHolder] = index;
    }
    _holders.pop();
    _holderIndex[holder] = 0;
  }

  // ------------------------------------------ //
  // IERC20
  // ------------------------------------------ //

  function allowance(address owner, address spender)
    external view override returns (uint256)
  {
    return _allowances[owner][spender];
  }

  function transfer(address to, uint256 value)
    external override returns (bool)
  {
    _transfer(msg.sender, to, value);
    return true;
  }

  function approve(address spender, uint256 value)
    external override returns (bool)
  {
    _allowances[msg.sender][spender] = value;
    return true;
  }

  function transferFrom(address from, address to, uint256 value)
    external override returns (bool)
  {
    require(_allowances[from][msg.sender] >= value, "Insufficient allowance");
    _allowances[from][msg.sender] =
      _allowances[from][msg.sender].sub(value);
    _transfer(from, to, value);
    return true;
  }

  function _transfer(address from, address to, uint256 value) private {
    require(balanceOf[from] >= value, "Insufficient balance");

    balanceOf[from] = balanceOf[from].sub(value);
    balanceOf[to]   = balanceOf[to].add(value);

    // Remove sender if balance hit zero
    if (balanceOf[from] == 0) {
      _removeHolder(from);
    }

    // Add recipient only if a real amount was moved
    if (value > 0) {
      _addHolder(to);
    }
  }

  // ------------------------------------------ //
  // IMintableToken
  // ------------------------------------------ //

  function mint() external payable override {
    require(msg.value > 0, "Must send ETH to mint");
    balanceOf[msg.sender] = balanceOf[msg.sender].add(msg.value);
    totalSupply = totalSupply.add(msg.value);
    _addHolder(msg.sender);
  }

  function burn(address payable dest) external override {
    uint256 amount = balanceOf[msg.sender];
    require(amount > 0, "No tokens to burn");

    balanceOf[msg.sender] = 0;
    totalSupply = totalSupply.sub(amount);
    _removeHolder(msg.sender);

    dest.transfer(amount);
  }

  // ------------------------------------------ //
  // IDividends
  // ------------------------------------------ //

  function getNumTokenHolders() external view override returns (uint256) {
    return _holders.length - 1;
  }

  function getTokenHolder(uint256 index)
    external view override returns (address)
  {
    require(index >= 1 && index < _holders.length, "Invalid index");
    return _holders[index];
  }

  function recordDividend() external payable override {
    require(msg.value > 0, "Dividend must be non-zero");
    require(totalSupply > 0, "No token holders");

    uint256 dividend = msg.value;
    uint256 numHolders = _holders.length - 1;

    for (uint256 i = 1; i <= numHolders; i++) {
      address holder = _holders[i];
      uint256 share = dividend.mul(balanceOf[holder]).div(totalSupply);
      _withdrawableDividend[holder] =
        _withdrawableDividend[holder].add(share);
    }
  }

  function getWithdrawableDividend(address payee)
    external view override returns (uint256)
  {
    return _withdrawableDividend[payee];
  }

  function withdrawDividend(address payable dest) external override {
    uint256 amount = _withdrawableDividend[msg.sender];
    require(amount > 0, "No dividend to withdraw");

    _withdrawableDividend[msg.sender] = 0;
    dest.transfer(amount);
  }
}