// SPDX-License-Identifier: MIT
pragma solidity 0.7.0;

import "./IERC20.sol";
import "./IMintableToken.sol";
import "./IDividends.sol";
import "./SafeMath.sol";

/**
 * @title Token
 * @author Rogers Terkaa Tarkighir
 *
 * @notice A mintable ERC-20 token backed 1:1 by ETH, with proportional
 *         dividend distribution to token holders.
 *
 * @dev Architecture overview:
 *
 *  MINTING
 *  -------
 *  Users send ETH to mint() and receive an equal number of tokens.
 *  The contract holds the ETH as collateral for future burns.
 *
 *  BURNING
 *  -------
 *  Users call burn(dest) to destroy their entire token balance and
 *  receive the equivalent ETH back at the destination address.
 *
 *  HOLDER TRACKING
 *  ---------------
 *  A dynamic array (_holders) keeps the canonical list of addresses
 *  that currently hold tokens. Index 0 is a placeholder (address(0))
 *  so that real holders occupy indices 1..N — matching the 1-based
 *  external API (getTokenHolder(index)).
 *
 *  A companion mapping (_holderIndex) stores each holder's position
 *  in the array for O(1) lookup and O(1) removal via swap-and-pop,
 *  keeping gas costs low regardless of cohort size.
 *
 *  DIVIDENDS
 *  ---------
 *  Anyone may call recordDividend() with an ETH payment. The contract
 *  immediately loops through _holders and credits each holder's share
 *  proportional to balanceOf[holder] / totalSupply.
 *
 *  Credited dividends are stored in _withdrawableDividend and persist
 *  even if the holder later transfers or burns their tokens. The holder
 *  collects accrued dividends by calling withdrawDividend(dest).
 */
contract Token is IERC20, IMintableToken, IDividends {

  // --------------------------------------------------------- //
  // ----- BEGIN: DO NOT EDIT THIS SECTION ------------------ //
  // --------------------------------------------------------- //
  using SafeMath for uint256;

  uint256 public totalSupply;
  uint256 public decimals = 18;
  string  public name     = "Test token";
  string  public symbol   = "TEST";

  /// @dev Core ERC-20 balance ledger.
  mapping (address => uint256) public balanceOf;
  // --------------------------------------------------------- //
  // ----- END: DO NOT EDIT THIS SECTION -------------------- //
  // --------------------------------------------------------- //


  // --------------------------------------------------------- //
  // Storage
  // --------------------------------------------------------- //

  /// @dev ERC-20 spend allowances: owner => spender => amount.
  mapping (address => mapping (address => uint256)) private _allowances;

  /**
   * @dev 1-indexed holder array.
   *
   *  Slot 0 is permanently occupied by address(0) so that the
   *  zero-value of _holderIndex (meaning "not present") never
   *  collides with a real slot.
   *
   *  Real holders live at indices 1 .. (_holders.length - 1).
   */
  address[] private _holders;

  /**
   * @dev Maps each holder address to its position inside _holders.
   *
   *  A value of 0 means the address is NOT currently a holder.
   *  This invariant lets _addHolder / _removeHolder run in O(1).
   */
  mapping (address => uint256) private _holderIndex;

  /**
   * @dev Accumulated dividend credit per address.
   *
   *  Credits are added by recordDividend() and cleared by
   *  withdrawDividend(). They survive token transfers and burns,
   *  so a holder never loses dividends they earned.
   */
  mapping (address => uint256) private _withdrawableDividend;


  // --------------------------------------------------------- //
  // Constructor
  // --------------------------------------------------------- //

  constructor() {
    /**
     * Push a sentinel address(0) into slot 0.
     * This makes _holderIndex[realAddress] == 0 a reliable
     * "not present" signal throughout the contract.
     */
    _holders.push(address(0));
  }


  // --------------------------------------------------------- //
  // Internal: holder list management
  // --------------------------------------------------------- //

  /**
   * @dev Add `holder` to the holders array if not already present.
   *
   *  Checking _holderIndex == 0 is an O(1) membership test.
   *  We append to the end and record the new index.
   */
  function _addHolder(address holder) private {
    if (_holderIndex[holder] == 0) {
      _holders.push(holder);
      _holderIndex[holder] = _holders.length - 1;
    }
  }

  /**
   * @dev Remove `holder` from the holders array using swap-and-pop.
   *
   *  Swap-and-pop keeps the array compact (no gaps) without an
   *  O(n) shift. Steps:
   *    1. Find the holder's index.
   *    2. If it is not the last slot, overwrite it with the last
   *       element and update that element's index mapping.
   *    3. Pop the (now-duplicate) last element.
   *    4. Reset the removed holder's index to 0 ("not present").
   *
   *  Gas cost is O(1) regardless of array length.
   */
  function _removeHolder(address holder) private {
    uint256 index = _holderIndex[holder];
    if (index == 0) return; // not a holder — nothing to do

    uint256 lastIndex = _holders.length - 1;

    if (index != lastIndex) {
      // Overwrite the vacated slot with the last holder
      address lastHolder = _holders[lastIndex];
      _holders[index]          = lastHolder;
      _holderIndex[lastHolder] = index;
    }

    _holders.pop();
    _holderIndex[holder] = 0; // mark as "not present"
  }


  // --------------------------------------------------------- //
  // Internal: token transfer logic
  // --------------------------------------------------------- //

  /**
   * @dev Move `value` tokens from `from` to `to`.
   *
   *  After updating balances we reconcile the holder list:
   *   - If the sender's balance drops to zero they leave the list.
   *   - If the recipient is new (and a non-zero amount arrived)
   *     they join the list.
   *
   *  A transfer of 0 tokens is accepted by ERC-20 but does NOT
   *  add the recipient to the holder list (no economic interest).
   */
  function _transfer(address from, address to, uint256 value) private {
    require(balanceOf[from] >= value, "Insufficient balance");

    balanceOf[from] = balanceOf[from].sub(value);
    balanceOf[to]   = balanceOf[to].add(value);

    // Remove sender when their balance reaches zero
    if (balanceOf[from] == 0) {
      _removeHolder(from);
    }

    // Only register the recipient as a holder for real transfers
    if (value > 0) {
      _addHolder(to);
    }
  }


  // --------------------------------------------------------- //
  // IERC20 implementation
  // --------------------------------------------------------- //

  /**
   * @notice Returns the remaining number of tokens that `spender`
   *         is allowed to spend on behalf of `owner`.
   */
  function allowance(address owner, address spender)
    external view override returns (uint256)
  {
    return _allowances[owner][spender];
  }

  /**
   * @notice Transfer `value` tokens to `to` from the caller's balance.
   * @dev Delegates to the internal _transfer which maintains the
   *      holder list automatically.
   */
  function transfer(address to, uint256 value)
    external override returns (bool)
  {
    _transfer(msg.sender, to, value);
    return true;
  }

  /**
   * @notice Approve `spender` to transfer up to `value` tokens on
   *         the caller's behalf.
   * @dev Overwrites any existing allowance (standard ERC-20 behaviour).
   *      Callers should set allowance to 0 before raising it to avoid
   *      the known double-spend race condition.
   */
  function approve(address spender, uint256 value)
    external override returns (bool)
  {
    _allowances[msg.sender][spender] = value;
    return true;
  }

  /**
   * @notice Transfer `value` tokens from `from` to `to` using the
   *         caller's pre-approved allowance.
   * @dev Reverts if the caller's allowance is insufficient.
   *      Reduces the allowance by exactly `value` on success.
   */
  function transferFrom(address from, address to, uint256 value)
    external override returns (bool)
  {
    require(
      _allowances[from][msg.sender] >= value,
      "Insufficient allowance"
    );
    _allowances[from][msg.sender] =
      _allowances[from][msg.sender].sub(value);
    _transfer(from, to, value);
    return true;
  }


  // --------------------------------------------------------- //
  // IMintableToken implementation
  // --------------------------------------------------------- //

  /**
   * @notice Mint tokens equal to the ETH sent.
   *
   * @dev Exchange rate is always 1 wei : 1 token unit, so the
   *      contract's ETH balance always equals totalSupply.
   *      The caller must send at least 1 wei; a zero-value call
   *      is rejected to prevent phantom holder entries.
   */
  function mint() external payable override {
    require(msg.value > 0, "Must send ETH to mint");

    balanceOf[msg.sender] = balanceOf[msg.sender].add(msg.value);
    totalSupply           = totalSupply.add(msg.value);

    // Register the minter as a holder (idempotent if already listed)
    _addHolder(msg.sender);
  }

  /**
   * @notice Burn the caller's entire token balance and withdraw the
   *         equivalent ETH to `dest`.
   *
   * @dev Full-balance burn only (no partial burn) keeps accounting
   *      simple and guarantees the 1:1 ETH backing invariant.
   *      The holder is removed from the list so future dividends
   *      are not allocated to a zero-balance address.
   *
   * @param dest  Address that receives the ETH proceeds.
   */
  function burn(address payable dest) external override {
    uint256 amount = balanceOf[msg.sender];
    require(amount > 0, "No tokens to burn");

    balanceOf[msg.sender] = 0;
    totalSupply           = totalSupply.sub(amount);

    // Remove from holder list before transferring ETH (re-entrancy hygiene)
    _removeHolder(msg.sender);

    dest.transfer(amount);
  }


  // --------------------------------------------------------- //
  // IDividends implementation
  // --------------------------------------------------------- //

  /**
   * @notice Returns the number of addresses currently holding tokens.
   * @dev Subtracts 1 to exclude the sentinel at index 0.
   */
  function getNumTokenHolders() external view override returns (uint256) {
    return _holders.length - 1;
  }

  /**
   * @notice Returns the holder address at position `index` (1-based).
   *
   * @dev The 1-based API matches the test harness which iterates
   *      from 1 to getNumTokenHolders() inclusive.
   *
   * @param index  1-based position in the holder array.
   */
  function getTokenHolder(uint256 index)
    external view override returns (address)
  {
    require(
      index >= 1 && index < _holders.length,
      "Index out of range"
    );
    return _holders[index];
  }

  /**
   * @notice Record an ETH dividend and immediately credit each
   *         current holder proportional to their share of totalSupply.
   *
   * @dev Division is integer (truncating). Any wei lost to rounding
   *      remains in the contract as a negligible dust balance.
   *
   *      Dividend credits persist in _withdrawableDividend even if
   *      the holder later transfers or burns their tokens, ensuring
   *      they can always collect earnings from the period they held.
   *
   *      Anyone (including non-holders) may fund a dividend round.
   *      A zero-value call is rejected to prevent no-op state changes.
   */
  function recordDividend() external payable override {
    require(msg.value  > 0, "Dividend must be non-zero");
    require(totalSupply > 0, "No token holders");

    uint256 dividend   = msg.value;
    uint256 numHolders = _holders.length - 1; // exclude sentinel

    for (uint256 i = 1; i <= numHolders; i++) {
      address holder = _holders[i];

      // Proportional share: holderBalance / totalSupply * dividend
      uint256 share = dividend
        .mul(balanceOf[holder])
        .div(totalSupply);

      _withdrawableDividend[holder] =
        _withdrawableDividend[holder].add(share);
    }
  }

  /**
   * @notice View the accumulated dividend credit for `payee`.
   * @param payee  Address to query.
   * @return       Wei owed to `payee` from past dividend rounds.
   */
  function getWithdrawableDividend(address payee)
    external view override returns (uint256)
  {
    return _withdrawableDividend[payee];
  }

  /**
   * @notice Withdraw the caller's entire accrued dividend to `dest`.
   *
   * @dev Follows the Checks-Effects-Interactions pattern:
   *       1. Check  — verify there is something to withdraw.
   *       2. Effect — zero out the credit before the external call.
   *       3. Interact — transfer ETH (prevents re-entrancy drain).
   *
   * @param dest  Address that receives the ETH dividend.
   */
  function withdrawDividend(address payable dest) external override {
    uint256 amount = _withdrawableDividend[msg.sender];
    require(amount > 0, "No dividend to withdraw");

    // Zero before transfer — re-entrancy guard
    _withdrawableDividend[msg.sender] = 0;

    dest.transfer(amount);
  }
}