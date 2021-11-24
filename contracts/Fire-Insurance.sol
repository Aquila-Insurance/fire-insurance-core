pragma solidity 0.8.10;
pragma experimental ABIEncoderV2;

import "@chainlink/contracts/src/v0.6/ChainlinkClient.sol";
import "@chainlink/contracts/src/v0.6/vendor/Ownable.sol";
import "@chainlink/contracts/src/v0.6/interfaces/LinkTokenInterface.sol";
import "@chainlink/contracts/src/v0.6/interfaces/AggregatorInterface.sol";
import "@chainlink/contracts/src/v0.6/interfaces/AggregatorV3Interface.sol";
import "@chainlink/contracts/src/v0.7/KeeperCompatible.sol";


contract InsuranceProvider {
  address public insurer = msg.sender;
  AggregatorV3Interface internal priceFeed; 

  uint public constant DAY_IN_SECONDS = 60; 
  uint private constant ORACLE_PAYMENT = 0.1 * 10**18;
  address public constant LINK_KOVAN = 0xa36085F69e2889c224210F603D836748e7dC0088;
  
  //here is where all the insurance contracts are stored.
  mapping (address => InsuranceContract) contracts;

  // add address ???
  constructor() public payable {
    priceFeed = AggregatorV3Interface();
  }

  // @dev Prevents a function being run unless it's called by the Insurance Provider
  modifier onlyOwner() {
    require(insurer == msg.sender, 'Only Insurance provider can do this!');
    _;
  }

  // @dev Event to log when a contract is created
  event contractCreated(address _insuranceContract, uint _premium, uint _totalCover);

  // @dev Create a new contract for client, automatically approved and deployed to the blockchain
  function newContract(address _client, uint _duration, uint _premium, uint _payoutValue, string _farmLocation) public payable onlyOwner() returns(address) {
    
    //create contract, send payout amount so contract is fully funded plus a small buffer
    InsuranceContract i = (new InsuranceContract).value((_payoutValue * 1 ether)/(uint(getLastestPrice())))(_client, _duration, _premium, _payoutValue, _farmLocation, LINK_KOVAN, ORACLE_PAYMENT);
    contracts[address(i)] = i;
    
    //emit an event to say the contract has been created and funded
    emit contractCreated(address(i), msg.value, _payoutValue);
    
    //now that contract has been created, we need to fund it with enough LINK tokens to fulfil 1 Oracle request per day, with a small buffer added
    LinkTokenInterface link = LinkTokenInterface(i.getChainlinkToken());
    link.transfer(address(i), ((_duration/(DAY_IN_SECONDS)) + 2) * ORACLE_PAYMENT * 2);

    return address(i);
  }

  // @dev returns the contract for a given address
  function getContract(address _contract) external view returns (InsuranceContract) {
    return contracts[_contract];
  }

  // @dev updates the contract for a given address
  function updateContract(address _contract) external {
    InsuranceContract i = InsuranceContract(_contract);
    i.updateContract();
  }

  // @dev gets the current rainfall for a given contract address
  function getContractFire(address _contract) external view returns (bool) {
    InsuranceContract i = InsuranceContract(_contract);
    return i.getCurrentFire();
  }

  // @dev gets the current rainfall for a given contract address
  function getContractRequestCount(address _contract) external view returns (uint) {
    InsuranceContract i = InsuranceContract(_contract);
    return i.getRequestCount();
  }

  // @dev Get the insurer address for this insurance provider
  function getInsurer() external view returns(address) {
    return insurer;
  }

  // @dev Get the status of a given Contract
  function getContractStatus(address _address) external view returns (bool) {
    InsuranceContract i = InsuranceContract(_adrees);
    return i.getContractStatus();
  }

  // @dev Return how much ether is in this master contract
  function getContractBalance() external view returns (uint) {
    return address(this).balance;
  }

  // @dev Function to end provider contract, in case of bugs or needing to update logic etc, funds are returned to insurance provider, 
  // including any remaining LINK tokens
  function endContractProvider() external payable onlyOwner() {
    LinkTokenInterface link = LinkTokenInterface(LINK_KOVAN);
    require(link.transfer(msg.sender, link.balanceOf(address(this))), "Unable to transfer!");
  }

  // Returns the latest price
  function getLastestPrice() public view returns (uint) {
    (
      uint80 roundID,
      uint price,
      uint startedAt, 
      uint timeStamp,
      uint answeredInRound
    ) = priceFeed.lastestRoundData();
    
    // If the round is not complete yet, timestamp is 0
    require(timeStamp > 0, "Round not complete");
    return price;
  }

  // @dev fallback function, to receive ether
  fallback() external payable { }

}



contract InsuranceContract is ChainlinkClient, Ownable {

  AggregatorV3Interface internal priceFeed; 

  uint public constant DAY_IN_SECONDS = 60; //How many seconds in a day. 60 for testing, 86400 for Production
  bool public constant IS_FIRED = false; 
  uint private oraclePaymentAmount; 

  address public insurer; 
  address client; 
  uint startDate; 
  uint duration; 
  uint premium; 
  uint payoutValue; 
  string farmLocation; 

  uint256[2] public currentFireList; 
  bytes32[2] public jobIds; 
  address[2] public oracles;

  string constant GOV_BC_WILDFIRE_URL = "";
  string constant GOV_BC_WILDFIRE_KEY = "";
  string constant GOV_BC_WILDFIRE_PATH = "";

  // string constant EARTHDATA_BC_WILDFIRE_URL = "";
  // string constant EARTHDATA_BC_WILDFIRE_KEY = "";
  // string constant EARTHDATA_BC_WILDFIRE_PATH = "";

  uint daysWithoutRain; 
  bool contractActive; 
  bool contractPaid; 
  uint currentFire = 0; 
  uint currentFireDateChecked = now; 
  uint requestCount = 0; 
  uint dataRequestsSent = 0; 

// @dev Prevents a function being run unless it's called by Insurance Provider

  modifier onlyOwner() {
    require(insurer == msg.sender, 'Only Insurance Provider can do this!');
    _;
  }
// @dev Prevents a function being run unless the Insurance Contract duration has been reached

  modifier onContractEnded() {
    if (startDate + duration < now) {
      _;
    }
  }
// @dev Prevents a function being run unless contract is still active

  modifier onContractActive() {
    require(contractActive == true, 'Contract has ended, can not interact with it anymore!');
    _;
  }

    /**
 @dev Prevents a data request to be called unless it's been a day since the last call (to avoid spamming and spoofing results)
 apply a tolerance of 2/24 of a day or 2 hours.
     */

  modifier callFrequencyOnePerDay() {
    require((now - currentFireDateChecked) > (DAY_IN_SECONDS - DAY_IN_SECONDS/12), 'Can only check fire once per day!');
    _;
  }

  event contractCreated(address _insurer, address _client, uint _duration, uint _premium, uint _totalCover); 
  event contractPaidOut(uint _paidTime, uint _totalPaid, bool _finalFire);
  event contractEnded(uint _endTime, uint _totalReturned); 
  event isFireReset(bool _fire);
  event dataRequestsSent(bytes32 requestId);
  event dataReceived(bool _fire);

// @dev Creates a new Insurance contract

  constructor(address _client, uint _duration, uint _premium, uint _payoutValue, string _farmLocation, 
              address _link, uint _oraclePaymentAmount) payable Ownable() public {
    //set ETH/USD Price Feed
    priceFeed = AggregatorV3Interface(0x9326BFA02ADD2366b30bacB125260Af641031331);

    //initialize variables required for Chainlink Network interaction
    setChainlinkToken(_link);
    oraclePaymentAmount = _oraclePaymentAmount;

    //first ensure insurer has fully funded the contract
    require(msg.value >= _payoutValue.div(uint(getLatestPrice())), "Not enough funds sent to contract");

    //now initialize values for the contract
    insurer= msg.sender;
    client = _client;
    startDate = now ; //contract will be effective immediately on creation
    duration = _duration;
    premium = _premium;
    payoutValue = _payoutValue;
    contractActive = true;
    farmLocation = _farmLocation;

    //or if you have your own node and job setup you can use it for both requests
    oracles[0] = 0x05c8fadf1798437c143683e665800d58a42b6e19;
    jobIds[0] = 'a17e8fbf4cbf46eeb79e04b3eb864a4e';
    // oracles[1] = 0x05c8fadf1798437c143683e665800d58a42b6e19;
    // jobIds[1] = 'a17e8fbf4cbf46eeb79e04b3eb864a4e';

    emit contractCreated(insurer, client, duration, premium, payoutValue);

  }

  function updateContract() public onContractActive() returns (bytes32 requestId) {

  }

// @dev Calls out to an Oracle to obtain weather data

  function checkFire(address _oracle, bytes32 _jobId, string _url, string _path) private onContractActive() returns (bytes32 requestId) {
    
    //First build up a request to get the current rainfall
    Chainlink.Request memory req = buildChainlinkRequest(_jobId, address(this), this.checkFireCallBack.selector);
    req.add("get", _url); //sends the GET request to the oracle
    req.add("path", _path);
    req.add("times", 100);

    requestId = sendChainlinkRequestTo(_oracle, req, oraclePaymentAmount);

    emit dataRequestSent(requestId);
  }

  /**
@dev Callback function - This gets called by the Oracle Contract when the Oracle Node passes data back to the Oracle Contract
The function will take the rainfall given by the Oracle and updated the Inusrance Contract state
    */
  function checkFireCallBack(bytes32 _requestId, bool _fire) public recordChainlinkFulfillment(_requestId) onContractActive() callFrequencyOncePerDay() {
    
    if (_fire = true) {
      payOutContract();
      }
    
    emit dataReceived(_fire);
  }

  // @dev Insurance conditions have been met, do payout of total cover amount to client
  function payOutContract() private onContractActive() {
    
    //Transfer agreed amount to client
    client.transfer(address(this).balance);
    
    //Transfer any remaining funds (premium) back to Insurer
    LinkTokenInterface link = LinkTokenInterface(chainlinkTokenAddress());
    require(link.transfer(insurer, link.balanceOf(address(this))), "Unable to transfer!");
    
    emit contractPaidOut(now, payoutValue, currentFire);

    //now that amount has been transferred, can end the contract
    //mark contract as ended, so no future calls can be done
    contractActive = false; 
    contractPaid = true;
  }

  // @dev Insurance conditions have not been met, and contract expired, end contract and return funds
  function checkEndContract() private onContractEnded() {
    //Insurer needs to have performed at least 1 weather call per day to be eligible to retrieve funds back.
    //We will allow for 1 missed weather call to account for unexpected issues on a given day.
    if (requestCount >= (duration.div(DAY_IN_SECONDS) - 2)) {
        //return funds back to insurance provider then end/kill the contract
        insurer.transfer(address(this).balance);
    } else { //insurer hasn't done the minimum number of data requests, client is eligible to receive his premium back
        // need to use ETH/USD price feed to calculate ETH amount
        client.transfer(premium.div(uint(getLatestPrice())));
        insurer.transfer(address(this).balance);
    }

    //transfer any remaining LINK tokens back to the insurer
    LinkTokenInterface link = LinkTokenInterface(chainlinkTokenAddress());
    require(link.transfer(insurer, link.balanceOf(address(this))), "Unable to transfer remaining LINK tokens");

    //mark contract as ended, so no future state changes can occur on the contract
    contractActive = false;
    emit contractEnded(now, address(this).balance);

  }

  // Returns the latest price
  function getLastestPrice() public view returns (uint) {
    (
      uint80 roundID,
      uint price, 
      uint startedAt, 
      uint timeStamp,
      uint80 answeredInRound
    ) = priceFeed.latestRoundData();
    
    // If the round is not complete yet, timestamp is 0
    require(timeStamp > 0, "Round not complete!");
    return price;
  }

  // @dev Get the balance of the contract
  function getContractBalance() external view returns (uint) {
    return address(this).balance;
  }
  // @dev Get the farm Location

  function getLocation() external view returns (string) {
    return farmLocation;
  }

  // @dev Get the Total Cover
  function getPayoutValue() external view returns (uint) {
    return payoutValue;
  }

  // @dev Get the Premium paid
  function getPremium() externla view returns (uint) {
    return premium;
  }

  // @dev Get the status of the contract
  function getContractStatus() external view returns (bool) {
    return contractActive;
  }

  // @dev Get whether the contract has been paid out or not
  function getContractPaid() external view returns (bool) {
    return contractPaid;
  }

  // @dev Get the current recorded rainfall for the contract
  function getCurrentFire() external view returns (bool) {
    return currentFire;
  }

  // @dev Get the count of requests that has occured for the Insurance Contract
  function getRequestCount() external view returns (uint) {
    return requestCount;
  }

 // @dev Get the last time that the rainfall was checked for the contract
  function getCurrentFireDateCheck() external view returns (uint) {
    return currentFireDateChecked;
  }

  // @dev Get the contract duration
  function getDuration() external view returns (uint) {
    return duration;
  }

  // @dev Get the contract start date
  function getContractStartDate() external view returns (uint) {
    return startDate;
  }

  // @dev Get the current date/time according to the blockchain
  function getNow() external view returns (uint) {
    return now;
  }

  // @dev Get address of the chainlink token
  function getChainlinkToken() public view returns (address) {
    return chainlinkTokenAddress();
  }

  // @dev Helper function for converting a string to a bytes32 object
  function stringToBytes32(string memory source) private pure returns (bytes32 result) {
    bytes memory tempEmptyStringTest = bytes(source);
    if (tempEmptyStringTest.length == 0) {
      return 0x0;
    }

    assembly {
      result := mload(add(source, 32))
    }
  }

  // @dev Helper function for converting uint to a string
  function uint2str(uint _i) internal pure returns (string memory _uintAsString) {
    if (_i == 0) {
      return "0";
    }
    uint j = _i;
    uint len; 
    while (j != 0) {
      len++;
      j /= 10;
    }
    bytes memory bstr = new bytes(len);
    uint k = len - 1; 
    while (_i != 0) {
      bstr[k--] = bytes(uint8(48 + _i % 10));
      _i /= 10; 
    }
    return string(bstr);
  }

  // @dev Fallback function so contrat can receive ether when required
  fallback() external payable { }

}
