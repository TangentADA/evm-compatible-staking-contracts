//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.3;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./ERC20Interface.sol";
import "./Calculator.sol";

/**
 * Lp token farm.
 *
 * 1st. Staking smart contract where users can connect via metamask and stake Tangent/ETH LP tokens.
 * 2nd. Rewards are paid in more $Tangent.
 * 3rd. Rewards can be collected anytime.
 *
 * Note: three initial LP tokens:
 *       Tangent/ETH LP from sakeswap
 *       Tangent/ETH LP from uniswap
 *       Tangent/ETH LP from balancer
 */
contract LpTokenFarm is Context, Ownable, ReentrancyGuard, Pausable {
    using Address for address;
    using SafeMath for uint256;
    using Calculator for uint256;

    /**
     * Emitted when a user store farming rewards(Tangent token).
     * @param sender User address.
     * @param amount Current store amount.
     * @param storeTimestamp The time when store farming rewards.
     */
    event ContractFunded(
        address indexed sender,
        uint256 amount,
        uint256 storeTimestamp
    );

    /**
     * Emitted when a user stakes lp tokens.
     * @param sender User address.
     * @param id User's unique stake ID.
     * @param balance Current user balance.
     * @param stakeTimestamp The time when stake tokens.
     */
    event Staked(
        address indexed sender,
        uint256 indexed id,
        uint256 balance,
        uint256 stakeTimestamp
    );

    /**
     * @dev Emitted when a new APY value is set.
     * @param value A new APY value.
     * @param sender The owner address at the moment of APY changing.
     */
    event ApySet(uint256 value, address sender);

    /**
     * @dev Emitted when a user requests unstake(lp token).
     * @param sender User address.
     * @param id User's unique stake ID.
     */
    event UnstakeRequested(address indexed sender, uint256 indexed id);

    /**
     * @dev Emitted when a user unstakes tokens(lp token).
     * @param sender User address.
     * @param id User's unique stake ID.
     * @param amount The amount of unstake tokens(lp token).
     * @param balance Current user balance.
     * @param TangentInterest The amount of interest(Tangent token).
     * @param timePassed TimePassed seconds.
     */
    event Unstake(
        address indexed sender,
        uint256 indexed id,
        uint256 amount,
        uint256 balance,
        uint256 TangentInterest,
        uint256 timePassed
    );

    /**
     * @dev Emitted when a user withdraw interest only.
     * @param sender User address.
     * @param id User's unique stake ID.
     * @param balance Current user balance of this stake(lp token).
     * @param timePassed TimePassed seconds.
     * @param interest The amount of interest(Tangent token).
     * @param claimTimestamp claim timestamp.
     */
    event Claimed(
        address indexed sender,
        uint256 indexed id,
        uint256 balance,
        uint256 interest,
        uint256 timePassed,
        uint256 claimTimestamp
    );

    // rewards Tangent token
    ERC20Interface public TangentToken;
    // lp token
    ERC20Interface public lpToken;

    // lp token about
    // The stake balances of users(store address->(stakeId->amount))
    mapping(address => mapping(uint256 => uint256)) public balances;
    // The dates of users' stakes(store address->(stakeId->timestamp))
    mapping(address => mapping(uint256 => uint256)) public stakeDates;
    // The dates of users' unstake requests(address->(stakeId->timestamp))
    mapping(address => mapping(uint256 => uint256)) public unstakeRequestsDates;
    // The last stake id(store address->last stake id)
    mapping(address => uint256) public lastStakeIds;
    // The total staked amount
    uint256 public totalStaked;

    // Tangent token about
    // The farming rewards of users(address => total amount)
    mapping(address => uint256) public funding;
    // the total farming rewards for users
    uint256 public totalFunding;

    // default annual percentage yield is 33% (in percentage), only contract owner can modify it
    uint256 public APY = 33; // stand for 33%

    constructor(address _TangentTokenAddress, address _lpTokenAddress) {
        require(
            _TangentTokenAddress.isContract() && _lpTokenAddress.isContract(),
            "must be contract address"
        );
        TangentToken = ERC20Interface(_TangentTokenAddress);
        lpToken = ERC20Interface(_lpTokenAddress);
    }

    /**
     * Store farming rewards to LpTokensFarm contract, in order to pay the user interest later.
     *
     * Note: input token is Tangent.
     * @param _amount should be more than 0.
     */
    function fundingContract(uint256 _amount) external nonReentrant {
        require(_amount > 0, "_amount should be more than 0");
        funding[msg.sender] += _amount;
        // increase total funding
        totalFunding += _amount;
        require(
            TangentToken.transferFrom(msg.sender, address(this), _amount),
            "transferFrom failed"
        );
        // send event
        emit ContractFunded(msg.sender, _amount, _now());
    }

    /**
     * Only owner can set APY.
     *
     * Note: If you want to set apy 12%, just pass 12.
     *
     * @param _APY annual percentage yield.
     */
    function setAPY(uint256 _APY) public onlyOwner {
        APY = _APY;
        emit ApySet(APY, msg.sender);
    }

    /**
     * Get Tangent token balance by address.
     * @param addr The address of the account that needs to check the balance
     * @return Return balance of Tangent token
     */
    function getTangentTokenBalance(address addr) public view returns (uint256) {
        return TangentToken.balanceOf(addr);
    }

    /**
     * Get lp token balance by address.
     * @param addr The address of the account that needs to check the balance
     * @return Return balance of lp token.
     */
    function getLpTokenBalance(address addr) public view returns (uint256) {
        return lpToken.balanceOf(addr);
    }

    /**
     * This method is used to stake lp tokens to a new stake.
     * It generates a new stake ID and calls another internal "stake" method. See its description.
     * @param _amount The amount to stake.
     */
    function stake(uint256 _amount) public whenNotPaused {
        stake(++lastStakeIds[msg.sender], _amount);
    }

    /**
     * This method is used to stake lp tokens.
     * It calls the internal "_stake" method and transfers tokens from sender to contract.
     * Sender must approve tokens first.
     *
     * Instead this, user can use the simple "transfer" method of STAKE token contract to make a stake.
     * Sender's approval is not needed in this case.
     *
     * Note: each call updates the stake date so be careful if you want to make a long staking.
     *
     * @param _stakeId User's unique stake ID.
     * @param _amount The amount to stake.
     */
    function stake(uint256 _stakeId, uint256 _amount) internal {
        require(
            _stakeId > 0 && _stakeId <= lastStakeIds[msg.sender],
            "wrong stake id"
        );
        _stake(msg.sender, _stakeId, _amount);
        require(
            lpToken.transferFrom(msg.sender, address(this), _amount),
            "lpToken transfer failed"
        );
    }

    /**
     * @dev Increases the user balance, and updates the stake date.
     * @param _sender The address of the sender.
     * @param _id User's unique stake ID.
     * @param _amount The amount to stake.
     */
    function _stake(
        address _sender,
        uint256 _id,
        uint256 _amount
    ) internal {
        require(_amount > 0, "stake amount should be more than 0");
        balances[_sender][_id] = _amount;
        totalStaked = totalStaked.add(_amount);
        uint256 stakeTimestamp = _now();
        stakeDates[_sender][_id] = stakeTimestamp;
        emit Staked(_sender, _id, _amount, stakeTimestamp);
    }

    /**
     * This method is used to request a unstake, with certain amount(it also can be used to unstake all).
     * It sets the date of the request.
     *
     * Note: each call updates the date of the request so don't call this method twice.
     *
     * @param _stakeId User's unique stake ID.
     * @param _amount The amount to unstake,
     */
    function unstakeCertainAmount(uint256 _stakeId, uint256 _amount)
        external
        whenNotPaused
        nonReentrant
    {
        require(
            _stakeId > 0 && _stakeId <= lastStakeIds[msg.sender],
            "wrong stake id"
        );
        require(_amount > 0, "amount should be more than 0");
        unstakeRequestsDates[msg.sender][_stakeId] = _now();
        emit UnstakeRequested(msg.sender, _stakeId);
        // make unstake
        makeRequestedUnstake(_stakeId, _amount);
    }

    /**
     * This method is used to request a unstake, and unstake all the amount of stake.
     * It sets the date of the request.
     *
     * Note: each call updates the date of the request so don't call this method twice during the lock.
     *
     * @param _stakeId User's unique stake ID.
     */
    function unstake(uint256 _stakeId) external whenNotPaused nonReentrant {
        require(
            _stakeId > 0 && _stakeId <= lastStakeIds[msg.sender],
            "unstake all with wrong stake id"
        );
        unstakeRequestsDates[msg.sender][_stakeId] = _now();
        emit UnstakeRequested(msg.sender, _stakeId);
        // make unstake
        makeRequestedUnstake(_stakeId, 0);
    }

    /**
     * This method is used to make a requested unstake.
     * It calls the internal "_unstake" method and resets the date of the request.
     *
     * @param _stakeId User's unique stake ID.
     * @param _amount The amount to unstake (0 - to unstake all).
     */
    function makeRequestedUnstake(uint256 _stakeId, uint256 _amount) internal {
        uint256 requestDate = unstakeRequestsDates[msg.sender][_stakeId];
        require(requestDate > 0, "unstake wasn't requested");
        unstakeRequestsDates[msg.sender][_stakeId] = 0;
        _unstake(msg.sender, _stakeId, _amount);
    }

    /**
     * Calls internal "calculateRewardsAndTimePassed" method and then transfers tokens to the sender.
     * @param _sender The address of the sender.
     * @param _id User's unique stake ID.
     * @param _amount The amount to unstake (0 - to unstake all).
     */
    function _unstake(
        address _sender,
        uint256 _id,
        uint256 _amount
    ) internal {
        require(
            _id > 0 && _id <= lastStakeIds[_sender],
            "_unstake wrong stake id"
        );
        require(
            balances[_sender][_id] > 0 && balances[_sender][_id] >= _amount,
            "_unstake insufficient funds"
        );
        // calculate interest by lp token amount
        (
            uint256 totalWithInterest,
            uint256 timePassed
        ) = calculateRewardsAndTimePassed(_sender, _id, _amount);
        require(
            totalWithInterest > 0 && timePassed > 0,
            "_unstake totalWithInterest<=0 or timePassed<=0"
        );
        uint256 amount = _amount == 0 ? balances[_sender][_id] : _amount;
        balances[_sender][_id] = balances[_sender][_id].sub(amount);
        totalStaked = totalStaked.sub(amount);
        if (balances[_sender][_id] == 0) {
            stakeDates[_sender][_id] = 0;
        }
        // interest to be paid, rewards is Tangent token
        uint256 interest = totalWithInterest.sub(amount);
        uint256 TangentInterestAmount = 0;
        if (totalFunding >= interest) {
            // total funding is enough to pay interest
            TangentInterestAmount = interest;
            // reduce total funding
            totalFunding = totalFunding.sub(interest);
        }
        // total funding is not enough to pay interest, the contract's Tangent has been completely drained. make sure users can unstake their lp tokens.
        // 1. rewards are paid in more Tangent
        if (TangentInterestAmount > 0) {
            require(
                TangentToken.transfer(_sender, TangentInterestAmount),
                "_unstake: Tangent transfer failed"
            );
        }
        // 2. unstake lp token of user
        require(
            lpToken.transfer(_sender, amount),
            "_unstake: lp transfer failed"
        );
        emit Unstake(
            _sender,
            _id,
            amount,
            balances[_sender][_id],
            TangentInterestAmount,
            timePassed
        );
    }

    /**
     * Withdraws the interest only of certain stake, and updates the stake date.
     *
     * @param _id User's unique stake ID.
     */
    function claim(uint256 _id) external whenNotPaused nonReentrant {
        require(
            _id > 0 && _id <= lastStakeIds[msg.sender],
            "claim wrong stake id"
        );
        uint256 balance = balances[msg.sender][_id];
        require(balance > 0, "claim balance must more than 0");
        // calculate interest
        (
            uint256 totalWithInterest,
            uint256 timePassed
        ) = calculateRewardsAndTimePassed(msg.sender, _id, 0);
        require(
            totalWithInterest > 0 && timePassed > 0,
            "claim totalWithInterest<=0 or timePassed<=0"
        );
        uint256 interest = totalWithInterest.sub(balance);
        require(interest > 0, "claim interest must more than 0");
        require(
            totalFunding >= interest,
            "total funding not enough to pay interest"
        );
        // reduce total funding
        totalFunding = totalFunding.sub(interest);
        uint256 claimTimestamp = _now();
        // update stake date, and withdraw interest
        stakeDates[msg.sender][_id] = claimTimestamp;
        require(
            TangentToken.transfer(msg.sender, interest),
            "claim transfer failed"
        );
        // send claim event
        emit Claimed(
            msg.sender,
            _id,
            balance,
            interest,
            timePassed,
            claimTimestamp
        );
    }

    /**
     * calculate interest and time passed
     * @param _user User's address.
     * @param _id User's unique stake ID.
     * @param _amount Amount based on which interest is calculated. When 0, current stake balance is used.
     * @return Return total with interest and time passed
     */
    function calculateRewardsAndTimePassed(
        address _user,
        uint256 _id,
        uint256 _amount
    ) public view returns (uint256, uint256) {
        uint256 currentBalance = balances[_user][_id];
        uint256 amount = _amount == 0 ? currentBalance : _amount;
        uint256 stakeDate = stakeDates[_user][_id];
        // seconds
        uint256 timePassed = _now().sub(stakeDate);
        if (timePassed < 1 seconds) {
            // if timePassed less than one second, rewards will be 0
            return (amount, timePassed);
        }
        uint256 totalWithInterest = Calculator.calculator(amount, timePassed, APY);
        return (totalWithInterest, timePassed);
    }

    /**
     * Get total lp token balance of user.
     *
     * Note: Iter balances mapping to get total balance of address.
     *
     * @param _address User's address or Contract's address
     * @return Returns current _address's total balance
     */
    function getTotalLpTokenBalance(address _address)
        public
        view
        returns (uint256)
    {
        require(_address != address(0), "getTotalLpTokenBalance zero address");
        uint256 lastStakeId = lastStakeIds[_address];
        if (lastStakeId <= 0) {
            return 0;
        }
        uint256 totalBalance;
        mapping(uint256 => uint256) storage stakeBalanceMapping = balances[
            _address
        ];
        for (uint256 i = 1; i <= lastStakeId; i++) {
            totalBalance += stakeBalanceMapping[i];
        }
        return totalBalance;
    }

    /**
     * @return Returns current timestamp.
     */
    function _now() internal view returns (uint256) {
        // Note that the timestamp can have a 900-second error:
        // https://github.com/ethereum/wiki/blob/c02254611f218f43cbb07517ca8e5d00fd6d6d75/Block-Protocol-2.0.md
        return block.timestamp; // solium-disable-line security/no-block-members
    }

    /**
     * Pauses all token stake, unstake.
     *
     * See {Pausable-_pause}.
     *
     * Requirements: the caller must be the owner.
     */
    function pause() public onlyOwner {
        _pause();
    }

    /**
     * Unpauses all token stake, unstake.
     *
     * See {Pausable-_unpause}.
     *
     * Requirements: the caller must be the owner.
     */
    function unpause() public onlyOwner {
        _unpause();
    }
}