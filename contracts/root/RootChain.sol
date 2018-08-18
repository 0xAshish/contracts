pragma solidity ^0.4.24;
pragma experimental ABIEncoderV2;

import { Ownable } from "openzeppelin-solidity/contracts/ownership/Ownable.sol";

import { SafeMath } from "../lib/SafeMath.sol";
import { PriorityQueue } from "../lib/PriorityQueue.sol";
import { Merkle } from "../lib/Merkle.sol";
import { MerklePatriciaProof } from "../lib/MerklePatriciaProof.sol";

import { DepositManager } from "./DepositManager.sol";
import { WithdrawManager } from "./WithdrawManager.sol";
import { StakeManager } from "./StakeManager.sol";


contract RootChain is Ownable, DepositManager, WithdrawManager {
  using SafeMath for uint256;
  using Merkle for bytes32;

  // chain identifier
  // keccak256('Matic Network v0.0.1-beta.1')
  bytes32 public chain = 0x2984301e9762b14f383141ec6a9a7661409103737c37bba9e0a22be26d63486d;

  // stake interface
  StakeManager public stakeManager;
  mapping(address => bool) public validatorContracts;

  // child chain contract
  address public childChainContract;

  // list of header blocks (address => header block object)
  mapping(uint256 => HeaderBlock) public headerBlocks;

  // current header block number
  uint256 private _currentHeaderBlock;

  //
  // Constructor
  //

  constructor (address _stakeManager) public {
    setStakeManager(_stakeManager);
  }

  //
  // Events
  //
  event ChildChainChanged(address indexed previousChildChain, address indexed newChildChain);
  event ValidatorAdded(address indexed validator, address indexed from);
  event ValidatorRemoved(address indexed validator, address indexed from);
  event NewHeaderBlock(
    address indexed proposer,
    uint256 indexed number,
    uint256 start,
    uint256 end,
    bytes32 root
  );

  //
  // Modifiers
  //

  /**
   * @dev Throws if deposit is not valid
   */
  modifier validateDeposit(address token, uint256 value) {
    // token must be supported
    require(tokens[token] != address(0x0));

    // token amount must be greater than 0
    require(value > 0);

    _;
  }

  // Checks is msg.sender is valid validator
  modifier isValidator(address _address) {
    require(validatorContracts[_address] == true);
    _;
  }

  // deposit ETH by sending to this contract
  function () public payable {
    depositEthers(msg.sender);
  }

  //
  // Admin functions
  //

  function networkId() public pure returns (bytes) {
    return "\x0d";
  }

  // change child chain contract
  function setChildContract(address newChildChain) public onlyOwner {
    require(newChildChain != address(0));
    emit ChildChainChanged(childChainContract, newChildChain);
    childChainContract = newChildChain;
  }

  // map child token to root token
  function mapToken(address _rootToken, address _childToken) public onlyOwner {
    // map root token to child token
    _mapToken(_rootToken, _childToken);

    // create exit queue
    exitsQueues[_rootToken] = address(new PriorityQueue());
  }

  // set WETH
  function setWETHToken(address _token) public onlyOwner {
    wethToken = _token;

    // weth token queue
    exitsQueues[wethToken] = address(new PriorityQueue());
  }

  // add validator
  function addValidator(address _validator) public onlyOwner {
    require(_validator != address(0) && validatorContracts[_validator] != true);
    emit ValidatorAdded(_validator, msg.sender);
    validatorContracts[_validator] = true;
  }

  // remove validator
  function removeValidator(address _validator) public onlyOwner {
    require(validatorContracts[_validator] == true);
    emit ValidatorAdded(_validator, msg.sender);
    delete validatorContracts[_validator];
  }

  //
  // PoS functions
  //
  function setStakeManager(address _stakeManager) public onlyOwner {
    require(_stakeManager != 0x0);
    stakeManager = StakeManager(_stakeManager);
  }

  function submitHeaderBlock(bytes32 root, uint256 end, bytes sigs) public {
    uint256 start = currentChildBlock();
    if (start > 0) {
      start = start.add(1);
    }

    // Make sure we are adding blocks
    require(end > start);

    // Make sure enough validators sign off on the proposed header root
    require(
      stakeManager.checkSignatures(root, start, end, sigs) >= stakeManager.validatorThreshold()
    );

    // Add the header root
    HeaderBlock memory headerBlock = HeaderBlock({
      root: root,
      start: start,
      end: end,
      createdAt: block.timestamp
    });
    headerBlocks[_currentHeaderBlock] = headerBlock;
    emit NewHeaderBlock(
      msg.sender,
      _currentHeaderBlock,
      headerBlock.start,
      headerBlock.end,
      root
    );
    _currentHeaderBlock = _currentHeaderBlock.add(1);

    // TODO add rewards

    // finalize commit
    stakeManager.finalizeCommit(msg.sender);
  }

  //
  // Exit NFT
  //

  function setExitNFTContract(address _nftContract) public onlyOwner {
    require(_nftContract != address(0));
    exitNFTContract = _nftContract;
  }

  //
  // Header block
  //

  function currentChildBlock() public view returns(uint256) {
    if (_currentHeaderBlock != 0) {
      return headerBlocks[_currentHeaderBlock.sub(1)].end;
    }

    return 0;
  }

  function currentHeaderBlock() public view returns(uint256) {
    return _currentHeaderBlock;
  }

  function getHeaderBlock(
    uint256 headerNumber
  ) internal view returns (HeaderBlock _headerBlock) {
    _headerBlock = headerBlocks[headerNumber];
  }

  function headerBlock(uint256 _headerNumber) public view returns (
    bytes32 _root,
    uint256 _start,
    uint256 _end,
    uint256 _createdAt
  ) {
    HeaderBlock memory _headerBlock = headerBlocks[_headerNumber];

    _root = _headerBlock.root;
    _start = _headerBlock.start;
    _end = _headerBlock.end;
    _createdAt = _headerBlock.createdAt;
  }

  // deposit ethers
  function depositEthers() public payable {
    depositEthers(msg.sender);
  }

  // slash stakers if fraud is detected
  function slash() public isValidator(msg.sender) {
    // TODO pass block/proposer
  }
}
