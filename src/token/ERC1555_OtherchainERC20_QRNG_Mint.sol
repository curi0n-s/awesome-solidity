// SPDX-License-Identifier: MIT
pragma solidity >=0.8.16 <0.9.0;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@api3/airnode-protocol/contracts/rrp/requesters/RrpRequesterV0.sol";

//Hyperlane V1 Imports
import "@hyperlane-xyz/core/interfaces/IOutbox.sol";
import "@hyperlane-xyz/core/interfaces/IInbox.sol";
import "@hyperlane-xyz/core/interfaces/IInterchainGasPaymaster.sol";

/**
    @title ERC1155 with Hyperlane Messaging for ERC20 on another chain and QRNG minting
    @notice NFT will reside on ETH mainnet, while the utility token to which it connects will be deployed on Polygon
    @notice uses Hyperlane V1 (would require update to V2 for current use. V2 was not yet deployed at time of writing)
*/   

/** STEPS TO INCLUDE HYPERLANE v2
    1. Import new interfaces: IMailbox, IInterchainGasPaymaster
    2. Switch outbox to mailbox
    3. Add paymasterAddress and setHyperlaneParams wrapped with new interfaceId
*/


//-------------------------------------------------------------------------------
// HYPERLANE V2 INTERFACES
// Will anything with handle() need to change? Likely not from looks of v2 repo
//-------------------------------------------------------------------------------

interface IInterchainGasPaymasterV2 {
    function payForGas(
        bytes32 _messageId,
        uint32 _destinationDomain,
        uint256 _gas,
        address _refundAddress
    ) external payable;
}

interface IMailboxV2 {
    function localDomain() external view returns (uint32);

    function dispatch(
        uint32 _destinationDomain,
        bytes32 _recipientAddress,
        bytes calldata _messageBody
    ) external returns (bytes32);

    function process(bytes calldata _metadata, bytes calldata _message)
        external;

    function count() external view returns (uint32);

    function root() external view returns (bytes32);

    function latestCheckpoint() external view returns (bytes32, uint32);
}

//-------------------------------------------------------------------------------
// ROYALTY FILTER REGISTRY INTERFACE
//-------------------------------------------------------------------------------
interface IBeforeTokenTransferHandler {
    function beforeTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external;
}

contract ERC1155OtherchainERC20QRNGMint is ERC1155, AccessControl, RrpRequesterV0 {
    
    //----------------------
    // State Variables
    // **CHANGES: Hyperlane V2 mailbox + interchainGasPaymaster [ ],
    //   cleaning up variables i.e. outbox vs outboxAddress (could use address(outbox) for ex.)
    // [ ] inbuilt royalties (specifically for ERC1155)
    //----------------------

    // Constraints:
    // 1. Can't mint more than 10,000 NFTs
    // 2. Only this contract and the admin can send messages via hyperlane

    //Hyperlane V1
    IOutbox public outbox;
    IInbox public inbox; //to goerli from Mumbai: 0x666a24F62f7A97BA33c151776Eb3D9441a059eB8
    IInterchainGasPaymaster public hyperlaneV1Paymaster;

    //Hyperlane V2
    IMailboxV2 public mailboxV2;
    IInterchainGasPaymasterV2 public hyperlaneV2Paymaster;

    
    address public airnode; //API3 airnode address
    address public beforeTokenTransferHandler;
    address public sponsorWallet; //derived wallet address OR this contract address (see: https://medium.com/@ashar2shahid/building-quantumon-part-1-smart-contract-integration-with-qrng-714cfecf336c)
    address public sponsorAddressWhichIsNotSponsorWallet; //sponsor address - could be creator EOA, or this contract        
    address public withdrawToAddress; 

    address[] public partnerNftAddresses; //array of partner addresses

    bool public mintIsPaused;
    bool public offChainHyperlaneGasCalculationIsOn;
    bool public utilityTokenIsDeployed;
    bool public whitelistMintIsPaused;


    bytes32 public ADMIN_ROLE;
    bytes32 public destinationContractBytes;
    bytes32 public endpointIdUint256Array;
    bytes32 public whitelistMerkleRootTier1;
    bytes32 public whitelistMerkleRootTier2;

    bytes[] public pendingMessagesForUtilityToken;

    string public name;
    string public symbol;

    uint32 public destinationDomain; //mumbai: 80001, polygon: ?

    uint256 public apiCallForwardingValue;//0.005 ether; 
    uint256 public backupGasMultiplier; //for hyperlane gas estimation
    uint256 public backupGasDivisor; //for hyperlane gas estimation
    uint256 public currentlyActivePriceTier;
    uint256 public goldSupply;
    uint256 public hyperlaneV1GasFee; //1 wei, adjust as needed
    uint256 public hyperlaneV2GasFee;
    uint256 public hyperlaneVersion;
    uint256 public hyperlaneForwardingValue;//0.005 ether;
    uint256 public latestHyperlaneGasPrice; //for hyperlane gas estimation
    uint256 public mintSupply;
    uint256 public maxMintsPerTxn; //change later, to like 10?
    uint256 public maxMintsPerAddress;
    uint256 public mintPrice; //0.001 ether for testing only 0.2 -> 0.3? make adjustable?
    uint256 public totalSupply;
    uint256 public whitelistMintPrice; //0.001 ether for testing only 0.2 -> 0.3? make adjustable?

    mapping(address => uint256) public amountMinted;
    mapping(bytes32 => bool) public expectingRequestWithIdToBeFulfilled;
    mapping(bytes32 => uint256) public requestIdToMintCostCalculatedOffChain;
    mapping(bytes32 => address) public requestIdToSender;
    mapping(uint256 => bool) public tokenIdIsGold;

    event MintFulfilled(bytes message);
    event MessageAddedToPending(address indexed sender, uint256 timestamp, bytes message);
    event RequestedUint256Array(bytes32 indexed requestId, uint256 size);
    event ReceivedUint256Array(bytes32 indexed requestId, uint256[] response);
    event ReceivedMessage(uint32 indexed origin, bytes32 indexed sender, bytes data);
    event SentMessage(uint32 destinationDomain, bytes32 recipient, bytes message); //var names overlap, double check this is ok
    
    error CallerMustBeInboxOrAdmin();
    error ExceededMaxMintsPerTxn();
    error ForwardFailed();
    error InvalidPassId();
    error InvalidHyperlaneMessage();
    error InvalidIndex();
    error InvalidMerkleOrWrongSender();
    error InvalidSupplyDecrease();
    error InsufficientBalanceForPendingMessages();
    error InsufficientFunds();
    error MaxMintsPerAddress();
    error MintPaused();
    error MaxSupplyReached();
    error UnknownAirnodeRequestId();
    error YouDoNotOwnThisPass();
    error ZeroPartnerNftBalance();
    error ZeroMintQuantity();

    //----------------------
    // Setup
    //----------------------

    constructor(
        address _airnodeRrp, //0xa0AD79D995DdeeB18a14eAef56A549A04e3Aa1Bd
        address _withdrawToAddress
        ) 
        ERC1155("") 
        RrpRequesterV0(_airnodeRrp)
    {
        address creator = msg.sender;
        
        //initial config
        mintIsPaused = true;
        whitelistMintIsPaused = true;
        utilityTokenIsDeployed = false;
        offChainHyperlaneGasCalculationIsOn = false;
        ADMIN_ROLE = keccak256('ADMIN_ROLE');
        name = "Silly NFT";
        symbol = "SILLY";
        hyperlaneV1GasFee = 1; //1 wei, adjust as needed
        hyperlaneV2GasFee = 1;
        hyperlaneVersion = 1;
        apiCallForwardingValue = 0;//0.005 ether;
        hyperlaneForwardingValue = 0;
        totalSupply = 10000;
        mintSupply = 10000;
        goldSupply = 500;
        maxMintsPerTxn = 20; //limited by the 500k API3 gas limit. Increase if ANU (Mainnet RNG Source) Gas > BYOG (Goerli RNG Source) Gas
        mintPrice = 0.00001 ether;
        whitelistMintPrice = 0.00001 ether;
        backupGasMultiplier = 2;
        backupGasDivisor = 1;
        latestHyperlaneGasPrice = 1;

        _grantRole(DEFAULT_ADMIN_ROLE, creator);
        _grantRole(ADMIN_ROLE, creator);
        
        setWithdrawToAddress(_withdrawToAddress);
        
        //set gold IDs (500 of 10000 spaced evenly)
        uint256 _goldSpacing = Math.mulDiv(totalSupply, 1, goldSupply);
        uint256 _tokenId = _goldSpacing;
        // tokenIdIsGold[1] = true;
        for(uint256 i=0; i<goldSupply-1; i++) {
            tokenIdIsGold[_tokenId] = true;
            _tokenId += _goldSpacing;
        }

    }

    receive() external payable {}

    //---------------------------------
    //          MINTING
    //---------------------------------

    // FEEDBACK for minting on paper.xyz
    function isMintPaused() public view returns (string memory) {
        if(mintIsPaused) {
            return "Mint is not active!";
        }
        return "";
    }

    function testMint() external onlyRole(ADMIN_ROLE) {
        sendQrngRequest(msg.sender, 2, 1);
    }

    /**
    @notice requests mints 2 or 1 at a time until total requested to be minted are 
            fulfilled because of gas limitations of Airnode fulfillment calls (500k gas)
    */
    function requestMint(
        address _minter, 
        uint256 _mintQuantity,
        uint256 _offChainDeterminedGasFee
    ) public payable {
        uint256 remainingMints = _mintQuantity;
        if( mintIsPaused && !hasRole(ADMIN_ROLE, msg.sender) ) { revert MintPaused(); }
        if( mintSupply == 0 ) { revert MaxSupplyReached(); }
        if( _mintQuantity == 0 ) { revert ZeroMintQuantity(); }
        if( _mintQuantity > maxMintsPerTxn ) { revert ExceededMaxMintsPerTxn(); }
        if( amountMinted[_minter] + _mintQuantity > maxMintsPerAddress ) { revert MaxMintsPerAddress(); }
        if( msg.value < ( (mintPrice + apiCallForwardingValue + hyperlaneForwardingValue) * _mintQuantity) ) { revert InsufficientFunds(); }
        
        (bool fwd, ) = sponsorWallet.call{value: apiCallForwardingValue }(""); 
        if(!fwd){ revert ForwardFailed(); }
        
        // mints 1 or 2 based on mod of remainingMints
        uint256 thisHyperlaneGasFee = hyperlaneForwardedGasFee(_offChainDeterminedGasFee);
        while(remainingMints > 0) {
            if(remainingMints % 2 == 0){
                remainingMints -= 2;
                sendQrngRequest(_minter, 2, thisHyperlaneGasFee);
            } else if (remainingMints % 2 == 1) {
                remainingMints -= 1;
                sendQrngRequest(_minter, 1, thisHyperlaneGasFee);
            }
        }
    }

    function requestWhitelistMint(
        uint256 _mintQuantity,
        bytes32 _leaf,
        bytes32[] calldata _proof,
        uint256 _priceTier,
        uint256 _offChainDeterminedGasFee
    ) public payable {
        uint256 remainingMints = _mintQuantity;
        address _minter = msg.sender;
        if( !isValidMerkle(_proof, _leaf, _minter, _priceTier) && !hasRole(ADMIN_ROLE, msg.sender) ) { revert InvalidMerkleOrWrongSender(); }
        if( whitelistMintIsPaused && !hasRole(ADMIN_ROLE, msg.sender) ) { revert MintPaused(); }
        if( mintSupply == 0 ) { revert MaxSupplyReached(); }
        if( _mintQuantity == 0 ) { revert ZeroMintQuantity(); }
        if( _mintQuantity > maxMintsPerTxn ) { revert ExceededMaxMintsPerTxn(); }
        if( amountMinted[_minter] + _mintQuantity > maxMintsPerAddress ) { revert MaxMintsPerAddress(); }
        if( msg.value < ( (whitelistMintPrice + apiCallForwardingValue + hyperlaneForwardingValue) * _mintQuantity) ) { revert InsufficientFunds(); }
        
        //check that this is required beyond msg.value (i.e. both will not result in more funds being requested than intended)
        (bool fwd, ) = sponsorWallet.call{value: apiCallForwardingValue }(""); 
        if(!fwd){ revert ForwardFailed(); }

        // mints 2 at a time until there is only 1 left, then mints 1
        uint256 thisHyperlaneGasFee = hyperlaneForwardedGasFee(_offChainDeterminedGasFee);
        while(remainingMints > 0) {
            if(remainingMints % 2 == 0){
                remainingMints -= 2;
                sendQrngRequest(_minter, 2, thisHyperlaneGasFee);
            } else if (remainingMints % 2 == 1) {
                remainingMints -= 1;
                sendQrngRequest(_minter, 1, thisHyperlaneGasFee);
            }
        }    
    }

    function sendQrngRequest(address _minter, uint256 _mintQuantity, uint256 _offChainDeterminedGasFee) private {
        bytes32 requestId = airnodeRrp.makeFullRequest(
            airnode,
            endpointIdUint256Array,
            sponsorAddressWhichIsNotSponsorWallet,
            sponsorWallet,
            address(this),
            this.fulfillMint.selector, //specified callback function
            // Using Airnode ABI to encode the parameters
            abi.encode(bytes32("1u"), bytes32("size"), _mintQuantity)
        );
        expectingRequestWithIdToBeFulfilled[requestId] = true;
        requestIdToSender[requestId] = _minter;
        requestIdToMintCostCalculatedOffChain[requestId] = _offChainDeterminedGasFee;
        latestHyperlaneGasPrice = _offChainDeterminedGasFee;
        emit RequestedUint256Array(requestId, _mintQuantity);
    }

    /// @dev see the pun here? :)
    function fulfillMint(bytes32 _requestId, bytes calldata data)
        external
        onlyAirnodeRrp
    {
        if( !expectingRequestWithIdToBeFulfilled[_requestId] ) { revert UnknownAirnodeRequestId(); }
        expectingRequestWithIdToBeFulfilled[_requestId] = false;
        uint256[] memory qrngUint256Array = abi.decode(data, (uint256[]));
        uint256 mintQuantity = qrngUint256Array.length;
        for (uint256 i = 0; i < mintQuantity; i++) {
            uint256 thisTier = getTierFromQrnAndManageSupply(qrngUint256Array[i]);
            address mintTo = requestIdToSender[_requestId];
            _mint(mintTo, thisTier, 1, "");
            bytes memory transferSignalToChild = abi.encode(block.timestamp, thisTier, mintTo, address(0), 0, 0, 0);
            amountMinted[mintTo] += 1; //add to amount minted before calling mint function
            
            if(utilityTokenIsDeployed){
                sendOwnerInfo(transferSignalToChild, requestIdToMintCostCalculatedOffChain[_requestId]);
            } else {
                pendingMessagesForUtilityToken.push(transferSignalToChild);
                emit MessageAddedToPending(mintTo, block.timestamp, transferSignalToChild);
            }            

            emit MintFulfilled(transferSignalToChild);
        }
        
        emit ReceivedUint256Array(_requestId, qrngUint256Array);
    }

    //------------------------------------------

    /**
    @notice Returns the tier of the token to be minted via random selection without replacement, 
            and manages both gold tier and total supplies
    [!!] check mod to ensure all outputs are within bounds of [1, mintSupply]
    */ 
    function getTierFromQrnAndManageSupply(uint256 _QRN) private returns (uint256) {
        uint256 thisRandomId = (_QRN % mintSupply) + 1; //inclusive of 1...
        uint256 thisTier;
        if (tokenIdIsGold[thisRandomId] && goldSupply > 0) {
            thisTier = 2;
            goldSupply--;
            tokenIdIsGold[thisRandomId] = false;
        } else {
            thisTier = 1;
        }
        mintSupply--;
        return thisTier;
    }

    /// @dev validates merkle tree info for whitelisting (i.e. groups like stepn holders)
    function isValidMerkle(bytes32[] memory _proof, bytes32 _leaf, address _mintingAddress, uint256 _priceTier) private view returns (bool) {
        if (_leaf == keccak256(abi.encodePacked(_mintingAddress)) && _priceTier == currentlyActivePriceTier && currentlyActivePriceTier == 1) { //redundant?
            return MerkleProof.verify(_proof, whitelistMerkleRootTier1, _leaf);
        } else if (_leaf == keccak256(abi.encodePacked(_mintingAddress)) && _priceTier == currentlyActivePriceTier && currentlyActivePriceTier == 2) { //redundant?
            return MerkleProof.verify(_proof, whitelistMerkleRootTier2, _leaf);
        } else {
            revert InvalidMerkleOrWrongSender();
        }
    }

    //----------------------------------------------------------------
    //---------- HYPERLANE-RELATED -----------------------------------
    //----------------------------------------------------------------

    function hyperlaneForwardedGasFee(uint256 _offChainDeterminedGasFee) public view returns (uint256) {
        if (_offChainDeterminedGasFee == 0) {
            return Math.mulDiv(backupGasMultiplier, latestHyperlaneGasPrice, backupGasDivisor);
        } else if (_offChainDeterminedGasFee == 1) {
            return hyperlaneV1GasFee;
        } else if (_offChainDeterminedGasFee == 2) {
            return hyperlaneV2GasFee;
        } else {
            return _offChainDeterminedGasFee;
        }
    }

    function sendOwnerInfo(
        bytes memory _message,
        uint256 _offChainDeterminedGasFee
    ) private {
        if (hyperlaneVersion == 1) {
            uint256 messageId = outbox.dispatch(destinationDomain, destinationContractBytes, _message);
                hyperlaneV1Paymaster.payGasFor{
                    value: hyperlaneForwardedGasFee(_offChainDeterminedGasFee) //may need to be adjusted later when dynamic fees are implemented
                }(
                    address(outbox),
                    messageId,
                    destinationDomain
                );
        } else if (hyperlaneVersion == 2) {
            bytes32 messageId = mailboxV2.dispatch(destinationDomain, destinationContractBytes, _message);
                hyperlaneV2Paymaster.payForGas{
                    value: hyperlaneForwardedGasFee(_offChainDeterminedGasFee) 
                }(
                    messageId,
                    destinationDomain,
                    hyperlaneForwardedGasFee(_offChainDeterminedGasFee),
                    address(this)
                );
        }
        emit SentMessage(destinationDomain, destinationContractBytes, _message);
    }

    // [ ] MAKE SURE handle() will work for Hyperlane V1 and V2!
    // use address of sender EOA not the inbox address

    function handle(
        uint32 _origin,
        bytes32 _sender,
        bytes calldata _message
    ) external {
        if ( (_origin!=destinationDomain) || (msg.sender!=address(inbox)) ) { revert InvalidHyperlaneMessage(); }
        address requester = abi.decode(_message, (address));
        updatePartnerNFTBalancesOnUtilityToken(requester);
        emit ReceivedMessage(_origin, _sender, _message);
    }
    
    function updatePartnerNFTBalancesOnUtilityToken(address _requester) public {
        if ( msg.sender != address(inbox) && msg.sender != address(this) && !hasRole(ADMIN_ROLE, msg.sender) ) { revert CallerMustBeInboxOrAdmin(); }
        
        uint256 userPartnerNftBalance;
        for(uint256 i=0; i<partnerNftAddresses.length; i++) {
            userPartnerNftBalance += IERC721(partnerNftAddresses[i]).balanceOf(_requester);
        }
        
        if (userPartnerNftBalance == 0) { revert ZeroPartnerNftBalance(); }
        
        // timestamp, tier (0 if updating partner balances), requester, previous owner, partnerNftBalance
        bytes memory transferSignalToChild = abi.encode(block.timestamp, 0, _requester, address(0), userPartnerNftBalance);
        
        sendOwnerInfo(transferSignalToChild, hyperlaneForwardedGasFee(0));

    }

    function sendPendingMessages(uint256 _offChainDeterminedGasFee) public onlyRole(ADMIN_ROLE) {
        if (address(this).balance < pendingMessagesForUtilityToken.length * hyperlaneForwardingValue) { revert InsufficientBalanceForPendingMessages(); }
        for(uint256 i=0; i<pendingMessagesForUtilityToken.length; i++) {
            sendOwnerInfo(pendingMessagesForUtilityToken[i], hyperlaneForwardedGasFee(_offChainDeterminedGasFee));
        }
    }
    
    function sendMessageManually(bytes memory _message, uint256 _offChainDeterminedGasFee) public onlyRole(ADMIN_ROLE) {
        sendOwnerInfo(_message, hyperlaneForwardedGasFee(_offChainDeterminedGasFee));
    }

    //---------------------------------
    // SETTERS, ADMIN
    //---------------------------------

    function configMintParams(
        uint256 _mintPrice,
        uint256 _whitelistMintPrice,
        uint256 _maxMintsPerTxn,
        uint256 _apiCallForwardingValue,
        uint256 _hyperlaneForwardingValue,
        bytes32 _whitelistMerkleRootTier1,
        bytes32 _whitelistMerkleRootTier2,
        uint256 _currentlyActivePriceTier
    ) external onlyRole(ADMIN_ROLE) {
        mintPrice = _mintPrice;
        whitelistMintPrice = _whitelistMintPrice;
        maxMintsPerTxn = _maxMintsPerTxn;
        apiCallForwardingValue = _apiCallForwardingValue;
        hyperlaneForwardingValue = _hyperlaneForwardingValue;
        whitelistMerkleRootTier1 = _whitelistMerkleRootTier1;
        whitelistMerkleRootTier2 = _whitelistMerkleRootTier2;
        currentlyActivePriceTier = _currentlyActivePriceTier;
    }

    function setURI(string memory newuri) external onlyRole(ADMIN_ROLE) {
        _setURI(newuri);
    }

    function setAPI3RequestParameters(
        address _airnode, //goerli: 0x9d3C147cA16DB954873A498e0af5852AB39139f2
        bytes32 _endpointIdUint256Array, //goerli: 0x27cc2713e7f968e4e86ed274a051a5c8aaee9cca66946f23af6f29ecea9704c3
        address _sponsorWallet, //derived with this contract address
        address _sponsorAddressWhichIsNotSponsorWallet, //this contract address or creator EOA
        uint256 _apiCallForwardingValue
    ) external onlyRole(ADMIN_ROLE) {
        airnode = _airnode;
        endpointIdUint256Array = _endpointIdUint256Array;
        sponsorWallet = _sponsorWallet;
        sponsorAddressWhichIsNotSponsorWallet = _sponsorAddressWhichIsNotSponsorWallet;
        apiCallForwardingValue = _apiCallForwardingValue;
    }

    function setMintStates(bool _mintIsPaused, bool _whitelistMintIsPaused) external onlyRole(ADMIN_ROLE) {
        mintIsPaused = _mintIsPaused;
        whitelistMintIsPaused = _whitelistMintIsPaused;
    }

    function setWithdrawToAddress(address _addr) public onlyRole(ADMIN_ROLE) {
        withdrawToAddress = _addr;
    }

    // add (true) or remove (false) partner NFT addresses
    function setPartnerNftAddresses(bool _action, address[] memory _addressList) external onlyRole(ADMIN_ROLE) {
        if(_action) {
            for(uint256 i=0; i<_addressList.length; i++) {
                partnerNftAddresses.push(_addressList[i]);
            }
        } else {
            for(uint256 i=0; i<_addressList.length; i++) {
                if(_addressList[i] == partnerNftAddresses[i]) {
                    delete partnerNftAddresses[i];
                }
            }
        }
    }

    function setUtilityTokenIsDeployed() public onlyRole(ADMIN_ROLE) {
        utilityTokenIsDeployed = !utilityTokenIsDeployed;
    }

    function setHyperlaneParams(
        address _newInboxAddress, 
        address _newOutboxAddress, 
        uint32 _destinationDomain, 
        address _paymasterAddress, 
        address _recipientAddress, 
        uint256 _gasFee, 
        uint256 _hyperlaneForwardingValue,
        bool _offChainHyperlaneGasCalculationIsOn,
        uint256 _backupGasMultiplier, 
        uint256 _backupGasDivisor
    ) external onlyRole(ADMIN_ROLE) {
        hyperlaneVersion = 1;
        inbox = IInbox(_newInboxAddress);
        outbox = IOutbox(_newOutboxAddress);
        destinationDomain = _destinationDomain;
        hyperlaneV1Paymaster = IInterchainGasPaymaster(_paymasterAddress);
        destinationContractBytes = bytes32(uint256(uint160(_recipientAddress))); //conversion from address to bytes32
        hyperlaneV1GasFee = _gasFee; //may need updates in v2 for dynamic gas fees?
        hyperlaneForwardingValue = _hyperlaneForwardingValue;
        offChainHyperlaneGasCalculationIsOn = _offChainHyperlaneGasCalculationIsOn;
        backupGasMultiplier = _backupGasMultiplier; 
        backupGasDivisor = _backupGasDivisor;
    }

    function setHyperlaneV2Params(
        address _newMailboxAddress, 
        uint32 _destinationDomain, 
        address _paymasterAddress, 
        address _recipientAddress, 
        uint256 _gasFee, 
        uint256 _hyperlaneForwardingValue,
        bool _offChainHyperlaneGasCalculationIsOn,
        uint256 _backupGasMultiplier,
        uint256 _backupGasDivisor
    ) external onlyRole(ADMIN_ROLE) {
        hyperlaneVersion = 2;
        mailboxV2 = IMailboxV2(_newMailboxAddress);
        destinationDomain = _destinationDomain;
        hyperlaneV2Paymaster = IInterchainGasPaymasterV2(_paymasterAddress);
        destinationContractBytes = bytes32(uint256(uint160(_recipientAddress)));
        hyperlaneV2GasFee = _gasFee;
        hyperlaneForwardingValue = _hyperlaneForwardingValue;
        offChainHyperlaneGasCalculationIsOn = _offChainHyperlaneGasCalculationIsOn;
        backupGasMultiplier = _backupGasMultiplier;
        backupGasDivisor = _backupGasDivisor;
    }


    /// @dev admin control of mint tiers for payment and marketing purposes
    function adminMintTo(
        uint256[] memory _tierArray, 
        address _recipient,
        uint256 _offChainDeterminedGasFee
    ) external onlyRole(ADMIN_ROLE) {
        amountMinted[_recipient] += _tierArray.length; //add to amount minted before calling mint function
        for(uint256 i=0; i<_tierArray.length; i++){
            mintSupply--;
            
            if(_tierArray[i]==1) {
                _mint(_recipient, 1, 1, ""); // _mint(account, id, amount, data);
            } else {
                goldSupply--;
                tokenIdIsGold[findFirstGoldIdMatch()] = false;
                _mint(_recipient, 2, 1, ""); // _mint(account, id, amount, data);
            }

            bytes memory transferSignalToChild = abi.encode(block.timestamp, _tierArray[i], _recipient, address(0), 0, 0, 0);
            
            if(utilityTokenIsDeployed){
                sendOwnerInfo(transferSignalToChild, hyperlaneForwardedGasFee(_offChainDeterminedGasFee));
            } else {
                pendingMessagesForUtilityToken.push(transferSignalToChild);
                emit MessageAddedToPending(msg.sender, block.timestamp, transferSignalToChild);
            }     

            emit MintFulfilled(transferSignalToChild);
        }
    }

    function findFirstGoldIdMatch() public view returns(uint256) {
        uint256 firstMatch;
        for(uint256 i=0; i<500; i++) {
            if(tokenIdIsGold[i]) {
                firstMatch = i;
            }
        }
        return firstMatch;
    }
        
    /// @dev tool to decrease supply if need be
    function decreaseSupply(uint256 _amount) external onlyRole(ADMIN_ROLE) {
        if(mintSupply - _amount > 0) {
            totalSupply -= _amount;
            mintSupply -= _amount;
        } else {
            revert InvalidSupplyDecrease();
        }
    }

    function burnPass(uint256 _id) public {
        if(_id==1 || _id==2) {
            if(balanceOf(msg.sender, _id) > 0) {
                _burn(msg.sender, _id, 1);
            } else {
                revert YouDoNotOwnThisPass();
            }
        } else {
            revert InvalidPassId();
        }
    }

    // withdraw funds from contract to payment spitter for treasury, etc
    function withdrawERC20(address _token, uint256 _amount) external onlyRole(ADMIN_ROLE) {
        IERC20(_token).transfer(withdrawToAddress, _amount);
    }

    function withdrawEthFromContract() external onlyRole(ADMIN_ROLE)  {
        (bool os, ) = payable(withdrawToAddress).call{ value: address(this).balance }('');
        if(!os){ revert ForwardFailed(); }
    }

    function withdrawEthFromSponsorWallet() external onlyRole(ADMIN_ROLE) {
        airnodeRrp.requestWithdrawal(airnode, sponsorWallet);
    }


    //---------------------------------------------
    // OVERRIDES
    //---------------------------------------------

    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data
    ) public virtual override {
        
        // require(msg.value >= hyperlaneForwardingValue);

        super.safeTransferFrom(from, to, id, amount, data);
        
        //use amount to get balance of each tier, send transfer messages to hyperlane one at a time to keep processing on the UT side simple
        bytes memory transferSignalToChild;
        for(uint256 i=0; i<amount; i++) {
            transferSignalToChild = abi.encode(block.timestamp, id, to, from, 0, 0, 0);
            
            if (utilityTokenIsDeployed) {
                sendOwnerInfo(transferSignalToChild, hyperlaneForwardedGasFee(0));
            } else {
                pendingMessagesForUtilityToken.push(transferSignalToChild);
                emit MessageAddedToPending(from, block.timestamp, transferSignalToChild);
            }

        }
    }

    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) public virtual override {
        super.safeBatchTransferFrom(from, to, ids, amounts, data);

        bytes memory transferSignalToChild;
        for(uint256 i=0; i<amounts.length; i++) {
            for(uint256 j=0; j<amounts[i]; j++) {
                transferSignalToChild = abi.encode(block.timestamp, ids[i], to, from, 0, 0, 0);
                if (utilityTokenIsDeployed) {
                    sendOwnerInfo(transferSignalToChild, hyperlaneForwardedGasFee(0));
                } else {
                    pendingMessagesForUtilityToken.push(transferSignalToChild);
                    emit MessageAddedToPending(from, block.timestamp, transferSignalToChild);
                }
            }
        }

    }

    /// @notice Handles pre-transfer filtering of approved operator addresses according to those specified on an external registry
    function _beforeTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal virtual override{
        if(beforeTokenTransferHandler != address(0)) {
            IBeforeTokenTransferHandler(beforeTokenTransferHandler).beforeTokenTransfer(operator, from, to, ids, amounts, data);
        }
        super._beforeTokenTransfer(operator, from, to, ids, amounts, data);
    }

    // The following functions are overrides required by Solidity.
    function supportsInterface(bytes4 interfaceId) public view override(ERC1155, AccessControl) returns (bool){
        return super.supportsInterface(interfaceId);
    }

}