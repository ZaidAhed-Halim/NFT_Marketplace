// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.9.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./INft_Marketplace.sol";
import "./FeeManager.sol";

contract Nft_Marketplace is INft_Marketplace, FeeManager {
  using SafeMath for uint256;

  // Binance Testnet Addresses
  ERC20 cifiTokenContractTest =
    ERC20(0xe56aB536c90E5A8f06524EA639bE9cB3589B8146);
  ERC20 bnbTokenContractTest =
    ERC20(0xB8c77482e45F1F44dE1745F52C74426C631bDD52);

  // From ERC721 registry assetId to Order (to avoid asset collision)
  mapping(address => mapping(uint256 => Order)) orderByAssetId;

  // From ERC721 registry assetId to Bid (to avoid asset collision)
  mapping(address => mapping(uint256 => Bid)) bidByOrderId;

  // from ERC20 symbols to their addresses
  mapping(string => address) acceptedTokens;

  // array that saves all the symbols of accepted tokens
  string[] public acceptedTokensSymbols;

  constructor() public {
    string memory CifiSymbol = "CIFI";
    address cifiTokenContract = 0x0000000000000000000000000000000000000000;
    acceptedTokens[CifiSymbol] = cifiTokenContract;
    acceptedTokensSymbols.push(CifiSymbol);

    string memory bnbSymbol = "BNB";
    address bnbTokenContract = 0x0000000000000000000000000000000000000000;
    acceptedTokens[bnbSymbol] = bnbTokenContract;
    acceptedTokensSymbols.push(bnbSymbol);
  }

  // 721 Interfaces
  bytes4 public constant _INTERFACE_ID_ERC721 = 0x80ac58cd;

  /**
   * Creates a new order
   *  _nftAddress - Non fungible contract address
   *  _assetId - ID of the published NFT
   *  _priceInAnyOfTheFourCurrencies - price In Any Of The Four Currencies
   *  _expiresAt - Duration of the order (in hours)
   */
  function createOrder(
    address _nftAddress,
    uint256 _assetId,
    address _acceptedToken,
    uint256 _price,
    uint256 _expiresAt
  ) public {
    _createOrder(_nftAddress, _assetId, _acceptedToken, _price, _expiresAt);
  }

  /**
   *  Cancel an already published order
   *  can only be canceled by seller or the contract owner
   *  nftAddress - Address of the NFT registry
   *  assetId - ID of the published NFT
   */
  function cancelOrder(
    address _nftAddress,
    uint256 _assetId
  ) public {
    Order memory order = orderByAssetId[_nftAddress][_assetId];

    require(order.seller == msg.sender, "Marketplace: unauthorized sender");

    // Remove pending bid if any
    Bid memory bid = bidByOrderId[_nftAddress][_assetId];

    if (bid.id != 0) {
      _cancelBid(
        bid.id,
        _nftAddress,
        _assetId,
        bid.bidder,
        bid.acceptedToken,
        bid.price
      );
    }

    // Cancel order.
    _cancelOrder(order.id, _nftAddress, _assetId, msg.sender);
  }

  /**
   * @dev Update an already published order
   *  can only be updated by seller
   * @param _nftAddress - Address of the NFT registry
   * @param _assetId - ID of the published NFT
   */
  function updateOrder(
    address _nftAddress,
    uint256 _assetId,
    address _acceptedToken,
    uint256 _price,
    uint256 _expiresAt
  ) public {
    Order memory order = orderByAssetId[_nftAddress][_assetId];

    // Check valid order to update
    require(order.id != 0, "Marketplace: asset not published");
    require(order.seller == msg.sender, "Marketplace: sender not allowed");
    require(order.expiresAt >= block.timestamp, "Marketplace: order expired");

    // check order updated params
    require(_price > 0, "Marketplace: Price should be bigger than 0");
    require(
      _expiresAt > block.timestamp.add(1 minutes),
      "Marketplace: Expire time should be more than 1 minute in the future"
    );

    order.price = _price;
    order.expiresAt = _expiresAt;
    order.acceptedToken = _acceptedToken;

    emit OrderUpdated(order.id, _acceptedToken, _price, _expiresAt);
  }

  /**
   * Executes the sale for a published NFT
   *  nftAddress - Address of the NFT registry
   *  assetId - ID of the published NFT
   *  priceInAnyOfTheFourCurrencies - Order price
   */

  function safeExecuteOrder(
    address _nftAddress,
    uint256 _assetId,
    address _acceptedToken,
    uint256 _price
  ) public {
    // Get the current valid order for the asset or fail
    Order memory order = _getValidOrder(_nftAddress, _assetId);

    /// Check the execution price matches the order price
    require(order.price == _price, "Marketplace: invalid price");
    require(order.seller != msg.sender, "Marketplace: unauthorized sender");

    // market fee to cut
    uint256 saleShareAmount = 0;

    ERC20 acceptedToken = ERC20(_acceptedToken);

    // Send market fees to owner
    if (FeeManager.cutPerMillion > 0) {
      // Calculate sale share
      saleShareAmount = _price.mul(FeeManager.cutPerMillion).div(1e6);

      if (acceptedToken == cifiTokenContractTest) {
        // Transfer half of share amount for marketplace Owner
        acceptedToken.transferFrom(
          msg.sender, //buyer
          owner(),
          saleShareAmount.div(2)
        );
      } else {
        // Transfer share amount for marketplace Owner
        acceptedToken.transferFrom(
          msg.sender, //buyer
          owner(),
          saleShareAmount
        );
      }
    }

    if (acceptedToken == cifiTokenContractTest) {
      // Transfer accepted token amount minus market fee to seller
      acceptedToken.transferFrom(
        msg.sender, // buyer
        order.seller, // seller
        order.price.sub(saleShareAmount.div(2))
      );
    } else {
      // Transfer accepted token amount minus market fee to seller
      acceptedToken.transferFrom(
        msg.sender, // buyer
        order.seller, // seller
        order.price.sub(saleShareAmount)
      );
    }

    // Remove pending bid if any
    Bid memory bid = bidByOrderId[_nftAddress][_assetId];

    if (bid.id != 0) {
      _cancelBid(
        bid.id,
        _nftAddress,
        _assetId,
        bid.bidder,
        _acceptedToken,
        bid.price
      );
    }

    _executeOrder(
      order.id,
      msg.sender, // buyer
      _nftAddress,
      _assetId,
      _acceptedToken,
      _price
    );
  }

  /**
   *  Places a bid for a published NFT
   *  _nftAddress - Address of the NFT registry
   *  _assetId - ID of the published NFT
   *  _priceInAny Of The Four Currencies - Bid price in acceptedToken currency
   *  _expiresAt - Bid expiration time
   */
  function safePlaceBid(
    address _nftAddress,
    uint256 _assetId,
    address _acceptedToken,
    uint256 _price,
    uint256 _expiresAt
  ) public {
    _createBid(_nftAddress, _assetId, _acceptedToken, _price, _expiresAt);
  }

  /**
   * @dev Cancel an already published bid
   *  can only be canceled by seller or the contract owner
   * @param _nftAddress - Address of the NFT registry
   * @param _assetId - ID of the published NFT
   */
  function cancelBid(
    address _nftAddress,
    uint256 _assetId,
    address _acceptedToken
  ) public {
    Bid memory bid = bidByOrderId[_nftAddress][_assetId];

    require(
      bid.bidder == msg.sender || msg.sender == owner(),
      "Marketplace: Unauthorized sender"
    );

    _cancelBid(
      bid.id,
      _nftAddress,
      _assetId,
      bid.bidder,
      _acceptedToken,
      bid.price
    );
  }

  /**
   * Executes the sale for a published NFT by accepting a current bid
   *  _nftAddress - Address of the NFT registry
   *  _assetId - ID of the published NFT
   *  _priceInAnyOfTheFourCurrencies - price In Any Of The Four Currencies
   */
  function acceptBid(
    address _nftAddress,
    uint256 _assetId,
    address _acceptedToken,
    uint256 _price
  ) public {
    // check order validity
    Order memory order = _getValidOrder(_nftAddress, _assetId);

    // item seller is the only allowed to accept a bid
    require(order.seller == msg.sender, "Marketplace: unauthorized sender");

    Bid memory bid = bidByOrderId[_nftAddress][_assetId];

    require(bid.price == _price, "Marketplace: invalid bid price");
    require(bid.expiresAt >= block.timestamp, "Marketplace: the bid expired");

    // remove bid
    delete bidByOrderId[_nftAddress][_assetId];

    emit BidAccepted(bid.id);

    // calc market fees
    uint256 saleShareAmount = bid.price.mul(FeeManager.cutPerMillion).div(1e6);

    // bidding is only with CifiToken ( this needs to be updated when we go live to Binance smart chain )
    ERC20 acceptedToken = ERC20(_acceptedToken);

    // transfer escrowed bid amount minus market fee to seller
    acceptedToken.transfer(bid.bidder, bid.price.sub(saleShareAmount));

    _executeOrder(
      order.id,
      bid.bidder,
      _nftAddress,
      _assetId,
      _acceptedToken,
      _price
    );
  }

  /**
   * Internal function gets Order by nftRegistry and assetId. Checks for the order validity
   * nftAddress - Address of the NFT registry
   * assetId - ID of the published NFT
   */
  function _getValidOrder(address _nftAddress, uint256 _assetId)
    internal
    view
    returns (Order memory order)
  {
    order = orderByAssetId[_nftAddress][_assetId];

    require(order.id != 0, "Marketplace: asset not published");
    require(order.expiresAt >= block.timestamp, "Marketplace: order expired");
  }

  /**
   * Executes the sale for a published NFT
   *  orderId - Order Id to execute
   *  buyer - address
   *  nftAddress - Address of the NFT registry
   *  assetId - NFT id
   *  price - Order price
   */
  function _executeOrder(
    bytes32 _orderId,
    address _buyer,
    address _nftAddress,
    uint256 _assetId,
    address _acceptedToken,
    uint256 _price
  ) internal {
    // remove order
    delete orderByAssetId[_nftAddress][_assetId];

    // Transfer NFT asset
    IERC721(_nftAddress).safeTransferFrom(address(this), _buyer, _assetId);

    // Notify ..
    emit OrderSuccessful(_orderId, _acceptedToken, _buyer, _price);
  }

  /**
   * Creates a new order
   *  nftAddress - Non fungible contract address
   *  assetId - ID of the published NFT
   *  priceInAnyOfTheFourCurrencies - price In Any Of The Four Currencies
   *  expiresAt - Expiration time for the order
   */
  function _createOrder(
    address _nftAddress,
    uint256 _assetId,
    address _acceptedToken,
    uint256 _price,
    uint256 _expiresAt
  ) internal {
    // Check nft registry
    IERC721 nftRegistry = _requireERC721(_nftAddress);

    // Check order creator is the asset owner
    address assetOwner = nftRegistry.ownerOf(_assetId);

    require(
      assetOwner == msg.sender,
      "Marketplace: Only the asset owner can create orders"
    );

    require(_price > 0, "Marketplace: Price should be bigger than 0");

    require(
      _expiresAt > block.timestamp.add(1 minutes),
      "Marketplace: Publication should be more than 1 minute in the future"
    );

    // get NFT asset from seller
    nftRegistry.safeTransferFrom(assetOwner, address(this), _assetId);

    // create the orderId
    bytes32 orderId =
      keccak256(
        abi.encodePacked(
          block.timestamp,
          assetOwner,
          _nftAddress,
          _assetId,
          _acceptedToken,
          _price
        )
      );

    // save order
    orderByAssetId[_nftAddress][_assetId] = Order({
      id: orderId,
      seller: assetOwner,
      nftAddress: _nftAddress,
      acceptedToken: _acceptedToken,
      price: _price,
      expiresAt: _expiresAt
    });

    emit OrderCreated(
      orderId,
      assetOwner,
      _nftAddress,
      _acceptedToken,
      _assetId,
      _price,
      _expiresAt
    );
  }

  /**
   *  Creates a new bid on a existing order
   *  nftAddress - Non fungible contract address
   *  assetId - ID of the published NFT
   *  priceInAnyOfTheFourCurrencies - price In Any Of The Four Currencies
   *  expiresAt - expires time
   */
  function _createBid(
    address _nftAddress,
    uint256 _assetId,
    address _acceptedToken,
    uint256 _price,
    uint256 _expiresAt
  ) internal {
    // Checks order validity
    Order memory order = _getValidOrder(_nftAddress, _assetId);

    // check on expire time
    if (_expiresAt > order.expiresAt) {
      _expiresAt = order.expiresAt;
    }

    // Check price if theres previous a bid
    Bid memory bid = bidByOrderId[_nftAddress][_assetId];

    // if theres no previous bid, just check price > 0
    if (bid.id != 0) {
      if (bid.expiresAt >= block.timestamp) {
        require(
          _price > bid.price,
          "Marketplace: bid price should be higher than last bid"
        );
      } else {
        require(_price > 0, "Marketplace: bid should be > 0");
      }

      _cancelBid(
        bid.id,
        _nftAddress,
        _assetId,
        bid.bidder,
        _acceptedToken,
        bid.price
      );
    } else {
      require(_price > 0, "Marketplace: bid should be > 0");
    }

    // bidding is only with CifiToken ( this needs to be updated when we go live to Binance smart chain )
    ERC20 acceptedToken = ERC20(_acceptedToken);

    // Transfer sale amount from bidder to escrow
    acceptedToken.transferFrom(
      msg.sender, // bidder
      address(this),
      _price
    );

    // Create bid
    bytes32 bidId =
      keccak256(
        abi.encodePacked(
          block.timestamp,
          msg.sender,
          order.id,
          _price,
          _expiresAt
        )
      );

    // Save Bid for this order
    bidByOrderId[_nftAddress][_assetId] = Bid({
      id: bidId,
      bidder: msg.sender,
      acceptedToken: _acceptedToken,
      price: _price,
      expiresAt: _expiresAt
    });

    emit BidCreated(
      bidId,
      _nftAddress,
      _assetId,
      msg.sender, // bidder
      _acceptedToken,
      _price,
      _expiresAt
    );
  }

  /**
   * Cancel an already published order
   *  can only be canceled by seller or the contract owner
   * orderId - Bid identifier
   * nftAddress - Address of the NFT registry
   * assetId - ID of the published NFT
   * seller - Address
   */
  function _cancelOrder(
    bytes32 _orderId,
    address _nftAddress,
    uint256 _assetId,
    address _seller
  ) internal {
    delete orderByAssetId[_nftAddress][_assetId];

    /// send asset back to seller
    IERC721(_nftAddress).safeTransferFrom(address(this), _seller, _assetId);

    emit OrderCancelled(_orderId);
  }

  /**
   * Cancel bid from an already published order
   *  can only be canceled by seller or the contract owner
   * bidId - Bid identifier
   * nftAddress - registry address
   * assetId - ID of the published NFT
   * bidder - Address
   * escrowAmount - in acceptenToken currency
   */
  function _cancelBid(
    bytes32 _bidId,
    address _nftAddress,
    uint256 _assetId,
    address _bidder,
    address _acceptedToken,
    uint256 _escrowAmount
  ) internal {
    delete bidByOrderId[_nftAddress][_assetId];

    // bidding is only with CifiToken ( this needs to be updated when we go live to Binance smart chain )
    ERC20 acceptedToken = ERC20(_acceptedToken);

    // return escrow to canceled bidder
    acceptedToken.transfer(_bidder, _escrowAmount);

    emit BidCancelled(_bidId);
  }

  function _requireERC721(address _nftAddress) internal view returns (IERC721) {
    require(
      IERC721(_nftAddress).supportsInterface(_INTERFACE_ID_ERC721),
      "The NFT contract has an invalid ERC721 implementation"
    );
    return IERC721(_nftAddress);
  }

  function addAcceptedToken(
    address acceptedTokenAddress,
    string memory acceptedTokenSymbol
  ) public onlyOwner returns (bool) {
    acceptedTokens[acceptedTokenSymbol] = acceptedTokenAddress;
    acceptedTokensSymbols.push(acceptedTokenSymbol);
    return true;
  }
}
