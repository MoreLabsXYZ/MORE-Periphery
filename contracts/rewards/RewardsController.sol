// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {VersionedInitializable} from '@aave/core-v3/contracts/protocol/libraries/aave-upgradeability/VersionedInitializable.sol';
import {SafeCast} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/SafeCast.sol';
import {IScaledBalanceToken} from '@aave/core-v3/contracts/interfaces/IScaledBalanceToken.sol';
import {RewardsDistributor} from './RewardsDistributor.sol';
import {IRewardsController} from './interfaces/IRewardsController.sol';
import {ITransferStrategyBase} from './interfaces/ITransferStrategyBase.sol';
import {RewardsDataTypes} from './libraries/RewardsDataTypes.sol';
import {IEACAggregatorProxy} from '../misc/interfaces/IEACAggregatorProxy.sol';

/**
 * @title RewardsController
 * @notice Abstract contract template to build Distributors contracts for ERC20 rewards to protocol participants
 * @author Aave
 **/
contract RewardsController is RewardsDistributor, VersionedInitializable, IRewardsController {
  using SafeCast for uint256;

  uint256 public constant REVISION = 1;

  // This mapping allows whitelisted addresses to claim on behalf of others
  // useful for contracts that hold tokens to be rewarded but don't have any native logic to claim Liquidity Mining rewards
  mapping(address => address) internal _authorizedClaimers;

  // reward => transfer strategy implementation contract
  // The TransferStrategy contract abstracts the logic regarding
  // the source of the reward and how to transfer it to the user.
  mapping(address => ITransferStrategyBase) internal _transferStrategy;

  // This mapping contains the price oracle per reward.
  // A price oracle is enforced for integrators to be able to show incentives at
  // the current Aave UI without the need to setup an external price registry
  // At the moment of reward configuration, the Incentives Controller performs
  // a check to see if the provided reward oracle contains `latestAnswer`.
  mapping(address => IEACAggregatorProxy) internal _rewardOracle;

  // This mapping stores whether a specific user is excluded from receiving rewards for a particular asset.
  mapping(address => mapping(address => bool)) internal _excludedFromRewards;
  // This mapping contains the list of excluded addresses per asset.
  mapping(address => address[]) internal _excludedAddresses;
  // This mapping contains the index of the excluded address in the `_excludedAddresses` array.
  mapping(address => mapping(address => uint256)) internal _excludedAddressIndex;

  modifier onlyAuthorizedClaimers(address claimer, address user) {
    require(_authorizedClaimers[user] == claimer, 'CLAIMER_UNAUTHORIZED');
    _;
  }

  constructor(address emissionManager) RewardsDistributor(emissionManager) {}

  /**
   * @dev Initialize for RewardsController
   * @dev It expects an address as argument since its initialized via PoolAddressesProvider._updateImpl()
   **/
  function initialize(address) external initializer {}

  /// @inheritdoc IRewardsController
  function getClaimer(address user) external view override returns (address) {
    return _authorizedClaimers[user];
  }

  /**
   * @dev Returns the revision of the implementation contract
   * @return uint256, current revision version
   */
  function getRevision() internal pure override returns (uint256) {
    return REVISION;
  }

  /// @inheritdoc IRewardsController
  function getRewardOracle(address reward) external view override returns (address) {
    return address(_rewardOracle[reward]);
  }

  /// @inheritdoc IRewardsController
  function getTransferStrategy(address reward) external view override returns (address) {
    return address(_transferStrategy[reward]);
  }

  /// @inheritdoc IRewardsController
  function isExcludedFromRewards(address user, address asset) external view returns (bool) {
    return _excludedFromRewards[user][asset];
  }

  /// @inheritdoc IRewardsController
  function getExcludedAddresses(address asset) external view returns (address[] memory) {
    return _excludedAddresses[asset];
  }

  /// @inheritdoc IRewardsController
  function configureAssets(
    RewardsDataTypes.RewardsConfigInput[] memory config
  ) external override onlyEmissionManager {
    for (uint256 i = 0; i < config.length; i++) {
      // config[i].totalSupply = IScaledBalanceToken(config[i].asset).scaledTotalSupply();
      config[i].totalSupply = _getAdjustedTotalSupply(config[i].asset);
      // Install TransferStrategy logic at IncentivesController
      _installTransferStrategy(config[i].reward, config[i].transferStrategy);

      // Set reward oracle, enforces input oracle to have latestPrice function
      _setRewardOracle(config[i].reward, config[i].rewardOracle);
    }
    _configureAssets(config);
  }

  /// @inheritdoc IRewardsController
  function setTransferStrategy(
    address reward,
    ITransferStrategyBase transferStrategy
  ) external onlyEmissionManager {
    _installTransferStrategy(reward, transferStrategy);
  }

  /// @inheritdoc IRewardsController
  function setRewardOracle(
    address reward,
    IEACAggregatorProxy rewardOracle
  ) external onlyEmissionManager {
    _setRewardOracle(reward, rewardOracle);
  }

  /// @inheritdoc IRewardsController
  function setExcludedFromRewards(
    address user,
    address asset,
    bool excluded
  ) external onlyEmissionManager {
    if (excluded && !_excludedFromRewards[user][asset]) {
      // If excluding and not already in the list, add the address.
      _excludedAddressIndex[user][asset] = _excludedAddresses[asset].length;
      _excludedAddresses[asset].push(user);
    } else if (!excluded && _excludedFromRewards[user][asset]) {
      // If including and already in the list, remove the address from the list.
      uint256 index = _excludedAddressIndex[user][asset];
      uint256 lastIndex = _excludedAddresses[asset].length - 1;
      address lastUser = _excludedAddresses[asset][lastIndex];
      _excludedAddresses[asset][index] = lastUser;
      _excludedAddressIndex[lastUser][asset] = index;
      _excludedAddresses[asset].pop();
      delete _excludedAddressIndex[user][asset];
    }
    _excludedFromRewards[user][asset] = excluded;

    emit ExclusionUpdated(user, asset, excluded);
  }

  /// @inheritdoc IRewardsController
  function handleAction(address user, uint256 totalSupply, uint256 userBalance) external override {
    // Skip updating rewards for excluded users.
    if (_excludedFromRewards[user][msg.sender]) {
      return;
    }
    _updateData(msg.sender, user, userBalance, totalSupply);
  }

  /// @inheritdoc IRewardsController
  function claimRewards(
    address[] calldata assets,
    uint256 amount,
    address to,
    address reward
  ) external override returns (uint256) {
    require(to != address(0), 'INVALID_TO_ADDRESS');
    return _claimRewards(assets, amount, msg.sender, msg.sender, to, reward);
  }

  /// @inheritdoc IRewardsController
  function claimRewardsOnBehalf(
    address[] calldata assets,
    uint256 amount,
    address user,
    address to,
    address reward
  ) external override onlyAuthorizedClaimers(msg.sender, user) returns (uint256) {
    require(user != address(0), 'INVALID_USER_ADDRESS');
    require(to != address(0), 'INVALID_TO_ADDRESS');
    return _claimRewards(assets, amount, msg.sender, user, to, reward);
  }

  /// @inheritdoc IRewardsController
  function claimRewardsToSelf(
    address[] calldata assets,
    uint256 amount,
    address reward
  ) external override returns (uint256) {
    return _claimRewards(assets, amount, msg.sender, msg.sender, msg.sender, reward);
  }

  /// @inheritdoc IRewardsController
  function claimAllRewards(
    address[] calldata assets,
    address to
  ) external override returns (address[] memory rewardsList, uint256[] memory claimedAmounts) {
    require(to != address(0), 'INVALID_TO_ADDRESS');
    return _claimAllRewards(assets, msg.sender, msg.sender, to);
  }

  /// @inheritdoc IRewardsController
  function claimAllRewardsOnBehalf(
    address[] calldata assets,
    address user,
    address to
  )
    external
    override
    onlyAuthorizedClaimers(msg.sender, user)
    returns (address[] memory rewardsList, uint256[] memory claimedAmounts)
  {
    require(user != address(0), 'INVALID_USER_ADDRESS');
    require(to != address(0), 'INVALID_TO_ADDRESS');
    return _claimAllRewards(assets, msg.sender, user, to);
  }

  /// @inheritdoc IRewardsController
  function claimAllRewardsToSelf(
    address[] calldata assets
  ) external override returns (address[] memory rewardsList, uint256[] memory claimedAmounts) {
    return _claimAllRewards(assets, msg.sender, msg.sender, msg.sender);
  }

  /// @inheritdoc IRewardsController
  function setClaimer(address user, address caller) external override onlyEmissionManager {
    _authorizedClaimers[user] = caller;
    emit ClaimerSet(user, caller);
  }

  /**
   * @dev Get user balances and total supply of all the assets specified by the assets parameter
   * @param assets List of assets to retrieve user balance and total supply
   * @param user Address of the user
   * @return userAssetBalances contains a list of structs with user balance and total supply of the given assets
   */
  function _getUserAssetBalances(
    address[] calldata assets,
    address user
  ) internal view override returns (RewardsDataTypes.UserAssetBalance[] memory userAssetBalances) {
    userAssetBalances = new RewardsDataTypes.UserAssetBalance[](assets.length);
    for (uint256 i = 0; i < assets.length; i++) {
      address asset = assets[i];
      userAssetBalances[i].asset = asset;
      /* (userAssetBalances[i].userBalance, userAssetBalances[i].totalSupply) = IScaledBalanceToken(assets[i])
          .getScaledUserBalanceAndSupply(user); */
      if (_excludedFromRewards[user][asset]) {
        // Excluded users: set userBalance to 0 so that no new rewards accrue.
        userAssetBalances[i].userBalance = 0;
      } else {
        userAssetBalances[i].userBalance = IScaledBalanceToken(asset).scaledBalanceOf(user);
      }
      userAssetBalances[i].totalSupply = _getAdjustedTotalSupply(asset);
    }
    return userAssetBalances;
  }

  /**
   * @dev Claims one type of reward for a user on behalf, on all the assets of the pool, accumulating the pending rewards.
   * @param assets List of assets to check eligible distributions before claiming rewards
   * @param amount Amount of rewards to claim
   * @param claimer Address of the claimer who claims rewards on behalf of user
   * @param user Address to check and claim rewards
   * @param to Address that will be receiving the rewards
   * @param reward Address of the reward token
   * @return Rewards claimed
   **/
  function _claimRewards(
    address[] calldata assets,
    uint256 amount,
    address claimer,
    address user,
    address to,
    address reward
  ) internal returns (uint256) {
    if (amount == 0) {
      return 0;
    }
    uint256 totalRewards;

    _updateDataMultiple(user, _getUserAssetBalances(assets, user));
    for (uint256 i = 0; i < assets.length; i++) {
      address asset = assets[i];
      totalRewards += _assets[asset].rewards[reward].usersData[user].accrued;

      if (totalRewards <= amount) {
        _assets[asset].rewards[reward].usersData[user].accrued = 0;
      } else {
        uint256 difference = totalRewards - amount;
        totalRewards -= difference;
        _assets[asset].rewards[reward].usersData[user].accrued = difference.toUint128();
        break;
      }
    }

    if (totalRewards == 0) {
      return 0;
    }

    _transferRewards(to, reward, totalRewards);
    emit RewardsClaimed(user, reward, to, claimer, totalRewards);

    return totalRewards;
  }

  /**
   * @dev Claims one type of reward for a user on behalf, on all the assets of the pool, accumulating the pending rewards.
   * @param assets List of assets to check eligible distributions before claiming rewards
   * @param claimer Address of the claimer on behalf of user
   * @param user Address to check and claim rewards
   * @param to Address that will be receiving the rewards
   * @return
   *   rewardsList List of reward addresses
   *   claimedAmount List of claimed amounts, follows "rewardsList" items order
   **/
  function _claimAllRewards(
    address[] calldata assets,
    address claimer,
    address user,
    address to
  ) internal returns (address[] memory rewardsList, uint256[] memory claimedAmounts) {
    uint256 rewardsListLength = _rewardsList.length;
    rewardsList = new address[](rewardsListLength);
    claimedAmounts = new uint256[](rewardsListLength);

    _updateDataMultiple(user, _getUserAssetBalances(assets, user));

    for (uint256 i = 0; i < assets.length; i++) {
      address asset = assets[i];
      for (uint256 j = 0; j < rewardsListLength; j++) {
        if (rewardsList[j] == address(0)) {
          rewardsList[j] = _rewardsList[j];
        }
        uint256 rewardAmount = _assets[asset].rewards[rewardsList[j]].usersData[user].accrued;
        if (rewardAmount != 0) {
          claimedAmounts[j] += rewardAmount;
          _assets[asset].rewards[rewardsList[j]].usersData[user].accrued = 0;
        }
      }
    }
    for (uint256 i = 0; i < rewardsListLength; i++) {
      _transferRewards(to, rewardsList[i], claimedAmounts[i]);
      emit RewardsClaimed(user, rewardsList[i], to, claimer, claimedAmounts[i]);
    }
    return (rewardsList, claimedAmounts);
  }

  /**
   * @dev Function to transfer rewards to the desired account using delegatecall and
   * @param to Account address to send the rewards
   * @param reward Address of the reward token
   * @param amount Amount of rewards to transfer
   */
  function _transferRewards(address to, address reward, uint256 amount) internal {
    ITransferStrategyBase transferStrategy = _transferStrategy[reward];

    bool success = transferStrategy.performTransfer(to, reward, amount);

    require(success == true, 'TRANSFER_ERROR');
  }

  /**
   * @dev Returns true if `account` is a contract.
   * @param account The address of the account
   * @return bool, true if contract, false otherwise
   */
  function _isContract(address account) internal view returns (bool) {
    // This method relies on extcodesize, which returns 0 for contracts in
    // construction, since the code is only stored at the end of the
    // constructor execution.

    uint256 size;
    // solhint-disable-next-line no-inline-assembly
    assembly {
      size := extcodesize(account)
    }
    return size > 0;
  }

  /**
   * @dev Internal function to call the optional install hook at the TransferStrategy
   * @param reward The address of the reward token
   * @param transferStrategy The address of the reward TransferStrategy
   */
  function _installTransferStrategy(
    address reward,
    ITransferStrategyBase transferStrategy
  ) internal {
    require(address(transferStrategy) != address(0), 'STRATEGY_CAN_NOT_BE_ZERO');
    require(_isContract(address(transferStrategy)) == true, 'STRATEGY_MUST_BE_CONTRACT');

    _transferStrategy[reward] = transferStrategy;

    emit TransferStrategyInstalled(reward, address(transferStrategy));
  }

  /**
   * @dev Update the Price Oracle of a reward token. The Price Oracle must follow Chainlink IEACAggregatorProxy interface.
   * @notice The Price Oracle of a reward is used for displaying correct data about the incentives at the UI frontend.
   * @param reward The address of the reward token
   * @param rewardOracle The address of the price oracle
   */

  function _setRewardOracle(address reward, IEACAggregatorProxy rewardOracle) internal {
    require(rewardOracle.latestAnswer() > 0, 'ORACLE_MUST_RETURN_PRICE');
    _rewardOracle[reward] = rewardOracle;
    emit RewardOracleUpdated(reward, address(rewardOracle));
  }

  /**
   * @dev Returns the adjusted total supply for an asset by subtracting
   * the balances of all excluded addresses.
   * @param asset The address of the asset.
   */
  function _getAdjustedTotalSupply(address asset) internal view override returns (uint256 adjustedTotalSupply) {
    uint256 totalSupply = IScaledBalanceToken(asset).scaledTotalSupply();
    uint256 excludedSupply = 0;
    uint256 len = _excludedAddresses[asset].length;
    for (uint256 i = 0; i < len; i++) {
      // Only include an address if it's still excluded.
      address excludedAddress = _excludedAddresses[asset][i];
      if (_excludedFromRewards[excludedAddress][asset]) {
        excludedSupply += IScaledBalanceToken(asset).scaledBalanceOf(excludedAddress);
      }
    }
    // Guard against underflow (in case all supply is excluded)
    if (totalSupply > excludedSupply) {
      adjustedTotalSupply = totalSupply - excludedSupply;
    } else {
      adjustedTotalSupply = 0;
    }
  }
}
