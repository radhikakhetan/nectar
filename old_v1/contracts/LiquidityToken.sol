pragma solidity ^0.4.11;

import './zeppelin/token/StandardToken.sol';
import './zeppelin/ownership/Ownable.sol';
import './Whitelist.sol';
import './RewardScheme.sol';

/// @title Liquidity token contract - Main logic for the Nectar token fee contributions, issuance and redemptions.
contract LiquidityToken is Whitelist, StandardToken, RewardScheme {

  /*
  *  Token meta data
  */
  string public name = "Nectar";
  string public symbol = "NEC";
  uint public decimals = 18;

  uint256 public periodLength;
  uint256 public initialSupply;
  uint256 public startTime;            // Time of window 1 opening

  mapping (uint => bool)                       public  windowInitialised;
  mapping (uint => uint)                       public  windowTotalFees;
  mapping (uint => uint)                       public  cumulativeFeesAtStartOfWindow;
  mapping (uint => uint)                       public  totalSupplyAtStartOfWindow;
  mapping (uint => mapping (address => uint))  public  feeContributions;
  mapping (uint => mapping (address => bool))  public  tokensClaimed;

  event LogContributions (uint window, address user, uint amount, bool maker);
  event LogCreate (uint window, uint tokensGenerated);
  event LogClaim (uint window, address user, uint amount);
  event LogCollect (address owner, uint amount);
  event UpgradedRewardMechanism (address newAddress);

  /// @dev Contract constructor function sets initial balance and starts the first window.
  /// @param _periodLength Time between each new window.
  /// @param _initialBalance The number of Nectar tokens initially created and allocated to Ethfinex.
  function LiquidityToken (uint256 _periodLength, uint256 _initialBalance) {
    startTime = time();
    periodLength = _periodLength;
    initialSupply = _initialBalance;
    totalSupplyAtStartOfWindow[1] = _initialBalance;
    totalSupply = initialSupply;
    authoriseMaker(msg.sender);
    balances[msg.sender] = _initialBalance;
    windowInitialised[1] = true;
  }

  function time() constant returns (uint) {
      return block.timestamp;
  }

  /// Time based function to give the current operating token generation cycle
  // function currentWindow() constant returns (uint) {
  //     return windowFor(time());
  // }

//////// Testing ///////////////////////

  uint testWindow = 1;

  function currentWindow() constant returns (uint) {
      return testWindow;
  }

  function incrementTestWindow() {
    testWindow++;
  }

///////////////////////////////////////

  function windowFor(uint timestamp) constant returns (uint) {
      return timestamp < startTime
          ? 0
          : timestamp.sub(startTime).div(periodLength * 1 minutes) + 1;
  }

  /// @dev contribute - Contribute fees as either a taker or on behalf of makers from an authorised source
  /// @param delegateMaker - Specify who fees are being contributed on behalf of
  /// @param maker - Specify if fees are contributed on behalf of maker or taker
  function contribute(address delegateMaker, bool maker) payable {
    uint window = currentWindow();
    require(msg.value >= 0.01 ether); // May be too high, but equally there will be gas fee

    // If contract is authorised to contribute on behalf of makers, and is doing so, they can earn tokens
    if (isAuthorisedMaker[msg.sender] && maker == true && isOnList[delegateMaker]) {
      feeContributions[window][delegateMaker] += msg.value;
      windowTotalFees[window] += msg.value;
      LogContributions(window, delegateMaker, msg.value, true);
    }
    else {
      windowTotalFees[window] += msg.value;
      LogContributions(window, 0, msg.value, false);
    }
  }

  /// @dev batchContribute - Contribute fees on behalf of multiple makers from an authorised source
  /// @param delegateMakers - Specify who fees are being contributed on behalf of
  /// @param values - How much each maker has contributed
  function batchContribute(address[] delegateMakers, uint256[] values) payable authorised {
    uint window = currentWindow();
    uint remainingBalance = msg.value;
    for (uint i = 0; i < delegateMakers.length; i++) {
      require(remainingBalance >= values[i]);
      remainingBalance -= values[i];
      feeContributions[window][delegateMakers[i]] += values[i];
      LogContributions(window, delegateMakers[i], values[i], true);
    }
    windowTotalFees[window] += msg.value;
    LogContributions(window, 0, remainingBalance, false);
  }

  /// Default fallback function for contributions assumes acting as a taker
  /// From other contracts call contribute directly
  function () payable {
    contribute(msg.sender, false);
  }

  /// @dev claim - Claim tokens from specified window
  /// @param window - Select which cycle to claim tokens for
  function claim(uint window) returns (bool) {
      require(currentWindow() > window);

      // First time claim is called for the window, mint all new tokens and place into a holding basket
      if (!windowInitialised[window+1]){
        mintNewTokens(window);
      }

      if (tokensClaimed[window][msg.sender] || feeContributions[window][msg.sender] == 0) {
          return false;
      }

      uint256 feesPaidAllTime = cumulativeFeesAtStartOfWindow[window];
      uint256 feesPaidThisUser = feeContributions[window][msg.sender];
      uint256 previousSupply = totalSupplyAtStartOfWindow[window];

      uint256 rate = getCurrentRewardRate(previousSupply, initialSupply, feesPaidAllTime, windowTotalFees[window]);
      uint256 reward = rate.mul(feesPaidThisUser).div(10000);

      tokensClaimed[window][msg.sender] = true;
      balances[msg.sender] = balances[msg.sender].add(reward);
      balances[0x0] = balances[0x0].sub(reward);

      LogClaim(window, msg.sender, reward);
      return true;
  }

  /// @dev claimAll - Claim all tokens earned in windows so far - N.B. could get stuck as currentWindow becomes large
  function claimAll() {
      for (uint i = 0; i < currentWindow(); i++) {
          claim(i);
      }
  }

  /// @dev mintNewTokens - Issue all tokens generated by fees in the specified window and initialise the next window
  /// @param window - Select cycle for which to mint tokens for
  function mintNewTokens(uint window) {
      require(currentWindow() > window);
      require(!windowInitialised[window+1]);

      if(!windowInitialised[window]){
        mintNewTokens(window-1);
      }

      windowInitialised[window+1] = true;
      cumulativeFeesAtStartOfWindow[window+1] = cumulativeFeesAtStartOfWindow[window] + windowTotalFees[window];

      uint256 previousSupply = totalSupplyAtStartOfWindow[window];
      uint256 rate = getCurrentRewardRate(previousSupply, initialSupply, cumulativeFeesAtStartOfWindow[window], windowTotalFees[window]);
      uint256 newTokens = rate.mul(windowTotalFees[window]).div(10000);
      totalSupply = totalSupply + newTokens;
      totalSupplyAtStartOfWindow[window+1] = totalSupply;
      balances[0x0] = balances[0x0].add(newTokens);

      LogCreate(window, newTokens);
  }

  /// @dev burnAndRetrieve - Burn tokens and retrieve the user's reward from the funds held by the contract
  /// @param numberToBurn - Number of user's tokens to destroy in return for rewards
  function burnAndRetrieve (uint256 numberToBurn) {
    require(balances[msg.sender] >= numberToBurn);

    // mintNewTokens must happen for previous windows before anyone can burn and retrieve, to update totalSupply and cumulative fees
    if(!windowInitialised[currentWindow()]){
      mintNewTokens(currentWindow()-1);
    }

    uint256 withdrawnFees = (numberToBurn.mul(cumulativeFeesAtStartOfWindow[currentWindow()]).div(totalSupply));
    totalSupply -= numberToBurn;
    balances[msg.sender] -= numberToBurn;
    cumulativeFeesAtStartOfWindow[currentWindow()] -= withdrawnFees;
    msg.sender.transfer(withdrawnFees);

    LogCollect(msg.sender, withdrawnFees);
  }

  /// Basic ERC20 Function Forwarding - only allow transfer from and to whitelisted addresses
  function transfer(address _to, uint256 _value) isWhitelisted {
    if (isOnList[_to]) {
      return super.transfer(_to, _value);
    } else {
      return;
    }
  }

  /// Basic ERC20 Function Forwarding - only allow transferFrom from and to whitelisted addresses
  function transferFrom(address _from, address _to, uint256 _value) isWhitelisted {
    if (isOnList[_to]) {
      return super.transferFrom(_from, _to, _value);
    } else {
      return;
    }
  }

  address public rewardRateUpgradedAddress;
  bool public upgraded;

  // Deprecate current reward mechanism in favour of a new one
  function upgradeReward(address _upgradedAddress) onlyOwner {
    upgraded = true;
    rewardRateUpgradedAddress = _upgradedAddress;
    UpgradedRewardMechanism(_upgradedAddress);
  }

  /// @dev getCurrentRewardRate - Reward scheme equations are upgradeable so that issuance and minting may change in the future if required
  /// @param _previousSupply - Supply at the start of the window
  /// @param _initialSupply - Supply at contract deployment
  /// @param _totalFees - Total fees held in the contract at the start of the window
  function getCurrentRewardRate(uint256 _previousSupply, uint256 _initialSupply, uint256 _totalFees, uint256 _windowFees) constant returns (uint256){
    if (upgraded) {
      return RewardScheme(rewardRateUpgradedAddress).rewardRate(_previousSupply, _initialSupply, _totalFees, _windowFees);
    } else {
      return rewardRate(_previousSupply, _initialSupply, _totalFees, _windowFees);
    }
  }

  // Claim unclaimed for Ethfinex after 6 months

  // Token holders able to vote to move the funds elsewhere, i.e. if an upgrade is happening or token is changing

}