pragma solidity ^0.4.24;


import { ERC20 } from "openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";
import { SafeMath } from "openzeppelin-solidity/contracts/math/SafeMath.sol";

import { ECVerify } from "../lib/ECVerify.sol";
import { BytesLib } from "../lib/BytesLib.sol";
import { PriorityQueue } from "../lib/PriorityQueue.sol";

import { Lockable } from "../mixin/Lockable.sol";
import { RootChainable } from "../mixin/RootChainable.sol";

import { StakeManagerInterface } from "./StakeManagerInterface.sol";
import { RootChain } from "./RootChain.sol";
import { ValidatorSet } from "./ValidatorSet.sol"; 


contract StakeManager is StakeManagerInterface, RootChainable, Lockable {
  using SafeMath for uint256;
  using SafeMath for uint8;
  using ECVerify for bytes32;

  PriorityQueue stakeQueue;
  ValidatorSet validatorSet;

  ERC20 public tokenObj;

  event ThresholdChange(uint256 newThreshold, uint256 oldThreshold);

  //optional event to ack unstaking
  event UnstakeInit(address indexed user, uint256 amount, uint256 total, bytes data); 

  uint256 public _validatorThreshold = 0;
  uint256 public totalStake = 0;
  uint256 public currentEpoch = 0;

  //Todo: dynamically update
  uint256 public minStakeAmount = 0;
  uint256 public minLockInPeriod = 1; //(unit epochs)
  uint256 public stakingIdCount = 0;  // just a counter/index to map it with PQ w/address

  enum ValidatorStatus { WAITING, VALIDATOR, UNSTAKING }

  struct Staker {
    uint256 epoch;  // init 0 
    uint256 amount;
    bytes data;
    ValidatorStatus status;
    uint256 stakingId; 
  }

  address[] exiterList;
  address[] stakersList;
  address[] public currentValidators;

  mapping (address => Staker) stakers; 
  mapping (uint256 => address) stakingIdToAddress;

  constructor(address _token) public {
    require(_token != 0x0);
    tokenObj = ERC20(_token);
    stakeQueue = new PriorityQueue();
  }

  // only staker
  modifier onlyStaker() {
    require(totalStakedFor(msg.sender) > 0);
    _;
  }

  
  function _priority(address user, uint256 amount, bytes data) private view returns(uint256) {
    // priority = priority << 64 | amount.div(totalStake) ;
    // return amount.mul(10000000).add(currentEpoch.mul(1000).add(amount.mul(100).div(user.balance)));
    return amount;
  }

  function stake(uint256 amount, bytes data) public {
    if (stakers[msg.sender].epoch==0) { 
      stakeFor(msg.sender, amount, data);
    } else {
      revert();
    }
  }

  function stakeFor(address user, uint256 amount, bytes data) public onlyWhenUnlocked {
    require(amount >= minStakeAmount); 

    // actual staker cannot be on index 0
    if (stakersList.length == 0) {
      stakersList.push(address(0x0));
      stakers[address(0x0)] = Staker(0, 0, new bytes(0), ValidatorStatus.WAITING, stakingIdCount);
      stakingIdToAddress[stakingIdCount] = address(0x0);
      stakingIdCount.add(1);
    }

    // transfer tokens to stake manager
    require(tokenObj.transferFrom(user, address(this), amount));
    
    uint256 priority = _priority(user, amount, data);

    // update total stake
    totalStake = totalStake.add(amount);

    stakers[user] = Staker(currentEpoch, amount, data, ValidatorStatus.WAITING, stakingIdCount);
    stakingIdToAddress[stakingIdCount] = user;
    
    stakeQueue.insert(priority, stakingIdCount);
    stakersList.push(user);
    
    stakingIdCount.add(1);
    
    emit Staked(user, amount, totalStake, data);
  }
  
  // returns validators
  function updateValidatorSet() public onlyRootChain returns (address[]) {
    // add condition for currentSize of PQ
    currentEpoch = currentEpoch.add(1);
    //trigger: lazy unstake with epoch validation
    _unstake();
    address validator;
    // add previous validators to priority queue
    for (i = 0; i < currentValidators.length; i++) {
      validator = currentValidators[i];
      if (stakers[validator].status != ValidatorStatus.UNSTAKING) {
        uint256 priority = _priority(validator, stakers[validator].amount, stakers[validator].data);
        stakeQueue.insert(priority, stakingIdCount);
        stakingIdToAddress[stakingIdCount] = validator;
        stakingIdCount.add(1);
      }
    }

    require(stakeQueue.currentSize() >= _validatorThreshold); 
    validatorSet = new ValidatorSet();
    delete currentValidators;
    uint256 stakerId;
      
    for (uint256 i = 0; i < _validatorThreshold; i++) {
      ( , stakerId) = stakeQueue.delMin();
      validator = stakingIdToAddress[stakerId];
      currentValidators.push(validator);
      stakers[validator].status = ValidatorStatus.VALIDATOR;
      validatorSet.addValidator(validator, stakers[validator].amount);
      delete stakingIdToAddress[stakerId];
    }

    return currentValidators;
  }

  // unstake and transfer amount for all valid exiters
  function _unstake() private {
    for (uint256 i = 0; i < exiterList.length; i++) {
      address exiter = exiterList[i];
      
      if (stakers[exiter].status == ValidatorStatus.UNSTAKING && (
        currentEpoch - stakers[exiter].epoch) <= minLockInPeriod ) {
        // stakersList[] = stakersList[] delete index 
        require(tokenObj.transfer(exiter, stakers[exiter].amount));
        totalStake = totalStake.sub(stakers[exiter].amount);
        emit Unstaked(exiter, stakers[exiter].amount, totalStake, "0");
        delete stakers[exiter];

        //delete from exiter list
        exiterList[i] = exiterList[exiterList.length - 1]; 
        delete exiterList[exiterList.length - 1]; 
        // Todo: delete from staker list if there is no stake left
      }
    }
  }

  function unstake(uint256 amount, bytes data) public { // onlyownder
    // require(stakers[msg.sender]); //staker exists
    // require(stakers[msg.sender].epoch!=0); 
    require(stakers[msg.sender].amount == amount);
    stakers[msg.sender].status = ValidatorStatus.UNSTAKING;
    exiterList.push(msg.sender); 
    emit UnstakeInit(msg.sender, amount, totalStake.sub(amount), "0");
  }

  function totalStakedFor(address addr) public view returns (uint256) { // onlyowner ?
    // require(stakers[addr]!=address(0));
    return stakers[addr].amount;
  }

  function totalStaked() public view returns (uint256){
    return totalStake;
  }

  function token() public view returns (address){
    return address(tokenObj);
  }

  function supportsHistory() public pure returns (bool){
    return false;
  }

  function validatorThreshold() public view returns (uint256) {
    return _validatorThreshold;
  }

  // Change the number of validators required to allow a passed header root
  function updateValidatorThreshold(uint256 newThreshold) public onlyRootChain {
    emit ThresholdChange(newThreshold, _validatorThreshold);
    _validatorThreshold = newThreshold;
  }

  // function finalizeCommit(address proposer) public onlyRootChain { 

  // }

  function updateMinStakeAmount(uint256 amount) public onlyRootChain {
    minStakeAmount = amount;
  }

  function updateMinLockInPeriod(uint256 epochs) public onlyRootChain {
    minLockInPeriod = epochs;
  }

  // need changes 
  function getProposer()  public view returns (address) {
    return validatorSet.proposer();
  }

  function checkSignatures(
    bytes32 root,
    uint256 start,
    uint256 end,
    bytes sigs
  ) public view returns (uint256) {
    // create hash
    bytes32 h = keccak256(
      abi.encodePacked(
        RootChain(rootChain).chain(), root, start, end
      )
    );

    // total signers
    uint256 totalSigners = 0;

    address lastAdd = address(0); // cannot have address(0) as an owner
    for (uint64 i = 0; i < sigs.length; i += 65) {
      bytes memory sigElement = BytesLib.slice(sigs, i, 65);
      address signer = h.ecrecovery(sigElement);

      // check if signer is stacker and not proposer
      if (totalStakedFor(signer) > 0 && signer != getProposer() && signer > lastAdd) {
        lastAdd = signer;
        totalSigners++;
      } else {
        break;
      }
    }

    return totalSigners;
  }
}