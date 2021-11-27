//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.6;
pragma experimental ABIEncoderV2;

//import "@chainlink/contracts/src/v0.6/ChainlinkClient.sol";
//import "@openzeppelin/contracts/access/Ownable.sol";

import "https://github.com/smartcontractkit/chainlink/contracts/src/v0.6/ChainlinkClient.sol";
import "https://github.com/smartcontractkit/chainlink/contracts/src/v0.6/vendor/Ownable.sol";

contract WildfireInsurance is ChainlinkClient, Ownable {

    //CONFIG: Network
    /////////////////
   
    function setJob(string memory _jobId) 
    public onlyOwner 
    { 
        oracle_jobid = _jobId;
    }

    function setOracle(address _oracle) 
    public onlyOwner 
    { 
        oracle_address = _oracle; 
    }
  
    function setJobAndOracle(string memory _jobId, address _oracle) 
    public onlyOwner 
    { 
        oracle_jobid = _jobId;
        oracle_address = _oracle; 
    }
    
    uint256 private constant ORACLE_PAYMENT = 0.1 * 10 ** 18;
    uint256 private CONTRACT_NETWORK = 42;
    address public oracle_address = address(0x270C24d79A8c334240b3449B8431DaCA1972F438);
    string public oracle_jobid = "0813e7cccc164e699961dd15eea486b3";

    // Insurance Structures
    ///////////////////////
    //bytes32 public fire;
    address public contractowner;
    uint256 private liquidityPool = 0;
    
    struct product {
        uint256 prodId;
        uint256 price;
        uint256 payoutMultiplier;
    }
    
    struct policy {
        address payable masterAddress;
        address payable policyAddress;
        uint256 productId;
        string iplCoordinates;
        uint256 payableAmount;
        uint256 payed;
        bytes32 payedFireId;
    }
    
    mapping(uint256 => product) private products;
    mapping(bytes32 => policy) public claims;    
    mapping(address => mapping(address => policy)) public policies;
    mapping(address => address[]) policyIndex;
 
    // Constructor
    //////////////////////
    
    constructor() public Ownable() {
        setPublicChainlinkToken();
        contractowner = msg.sender;
        products[0] = product(0,100,2);
        products[1] = product(1,500,5);
        products[2] = product(2,1000,10);
        oracle_address =  0x270C24d79A8c334240b3449B8431DaCA1972F438;
        oracle_jobid = "6701dabd9cd14898aa132d20dbe8a14a";
    }
   
   
    // Insurance Functions
    //////////////////////
    
    function buyPolicy(address payable _policyAddress, uint256 _productId, string memory _iplCoordinates) 
    public payable
    {
        require(msg.value > 0, "No value policy purchase");
        require(msg.value >= products[_productId].price, "Insufficient tx value for policy purchase");
        
        uint256 payableAmount = msg.value * products[_productId].payoutMultiplier;
        liquidityPool += uint256(msg.value);      
        
        policy memory ipl = policy(msg.sender, _policyAddress, _productId, _iplCoordinates, payableAmount, 0, 0);
        policies[msg.sender][_policyAddress] = ipl;
        policyIndex[msg.sender].push(_policyAddress);
    }
    
    function viewPolicy(address _policyAddress) 
    public view returns (policy memory)
    {
        policy memory ipl = policies[msg.sender][_policyAddress];
        return ipl;
    }
   
    function viewPoliciesIdx() 
    public view returns (address[] memory)
    {
        address[] memory adr = policyIndex[msg.sender];
        return adr;
    }

   function tryClaim(address _policyAddress) 
    public {

        policy memory ipl = policies[msg.sender][_policyAddress];

        if (ipl.masterAddress != address(0)){
            Chainlink.Request memory req = buildChainlinkRequest(stringToBytes32(oracle_jobid), address(this), this.fulfillClaimInquiry.selector);
            req.add("get", ipl.iplCoordinates);
            bytes32 reqId = sendChainlinkRequestTo(oracle_address, req, 1000000000000000000);
            claims[reqId] = ipl;
        }
    }

    function fulfillClaimInquiry(bytes32 _requestId, bytes32 _data) public recordChainlinkFulfillment(_requestId)
    {
    //fire = _data;
        if (_data != 0){
            //Fire Found - Update policy and pay out
            policy memory pol = claims[_requestId];
            policies[pol.masterAddress][pol.policyAddress].payed = 1;
            policies[pol.masterAddress][pol.policyAddress].payedFireId = _data;
            pol.policyAddress.transfer(pol.payableAmount);
        }
    }
    
    
    //ACCOUNTING: Owner Balance & Withdrawal Functions
    //////////////////////////////////////////////////

    function addToBalance() 
    public payable 
    {}

    function getLPBalance() 
    public onlyOwner view returns(uint256) {
        return liquidityPool;
    }
    
    function getBalance() 
    public onlyOwner view returns(uint256) {
        return address(this).balance;
    }

    function withdrawAll() 
    public onlyOwner {
        address payable to = payable(msg.sender);
        to.transfer(getBalance());
    }

    function withdrawAmount(uint256 amount) 
    public onlyOwner {
        address payable to = payable(msg.sender);
        to.transfer(amount);
    }

    function withdrawLink() 
    public onlyOwner {
        LinkTokenInterface link = LinkTokenInterface(chainlinkTokenAddress());
        require(link.transfer(msg.sender, link.balanceOf(address(this))), "Unable to transfer");
    }
    
    
    //UTILS
    ///////

    function getChainlinkToken() 
    public view returns (address) 
    {
        return chainlinkTokenAddress();
    }

    function bytes32ToStr(bytes32 _bytes32) 
    private pure returns (string memory) 
    {
        bytes memory bytesArray = new bytes(32);
        for (uint256 i; i < 32; i++) {
            bytesArray[i] = _bytes32[i];
        }
        return string(bytesArray);
    }
    
    function stringToBytes32(string memory source) 
    private pure returns (bytes32 result) 
    {
        bytes memory tempEmptyStringTest = bytes(source);
        if (tempEmptyStringTest.length == 0) {
            return 0x0;
        }

        assembly {
            // solhint-disable-line no-inline-assembly
            result := mload(add(source, 32))
        }
    
    }

    function splitBytes32(bytes32 r) 
    private pure returns (uint256 s1, uint256 s2, uint256 s3, uint256 s4)
    {
        uint256 rr = uint256(r);
        s1 = uint256(uint64(rr >> (64 * 3)));
        s2 = uint256(uint64(rr >> (64 * 2)));
        s3 = uint256(uint64(rr >> (64 * 1)));
        s4 = uint256(uint64(rr >> (64 * 0)));
        // (uint256 _s1, uint256 _s2, uint256 _s3, uint256 _s4) = splitBytes32(dataObjectBytes32);
    }

}
