// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";

/**
 * @title NFT 交易市场合约
 * @author 塞翁马团队 (Saiweng Ma Team)
 * @notice 支持固定价格销售、拍卖、报价、版税分配的 NFT 交易市场
 * @dev 支持 ETH 和 ERC20 代币支付，集成 EIP-2981 版税标准
 * 
 * 核心功能：
 * - 固定价格销售：创建挂单、购买、取消
 * - 拍卖系统：创建拍卖、出价、结束拍卖、自动延长
 * - 报价系统：创建报价、接受报价、取消报价
 * - 版税支持：自动分配 EIP-2981 版税
 * - 多代币支付：支持 ETH 和白名单 ERC20 代币
 * - 退款机制：Push with Pull Fallback 确保资金安全
 * 
 * 安全特性：
 * - ReentrancyGuard：防止重入攻击
 * - Pausable：紧急暂停机制
 * - Ownable2Step：安全的所有权转移
 * - Gas 限制：防止恶意合约攻击
 */
contract NFTMarketplace is Ownable2Step, ReentrancyGuard, Pausable {
  using SafeERC20 for IERC20;

  // ===========
  // 类型定义
  // ===========

  /// @notice 固定价格挂单
  struct Listing {
    address seller;           // 卖家地址
    address nftContract;      // NFT 合约地址
    address paymentToken;     // 支付代币（address(0) = ETH）
    uint256 tokenId;          // Token ID
    uint256 price;            // 价格
    uint48 expiresAt;        // 过期时间（Unix 时间戳）
    bool active;              // 是否激活
  }

  /// @notice 拍卖
  struct Auction {
    address seller;           // 卖家地址
    address nftContract;      // NFT 合约地址
    address paymentToken;     // 支付代币
    address currentBidder;    // 当前出价者
    uint256 tokenId;          // Token ID
    uint256 startPrice;       // 起拍价
    uint256 currentBid;       // 当前出价
    uint48 startTime;        // 开始时间（Unix 时间戳）
    uint48 endTime;          // 结束时间（Unix 时间戳）
    bool active;              // 是否激活
  }

  /// @notice 报价
  struct Offer {
    address offerer;          // 报价者
    address nftContract;      // NFT 合约地址
    address paymentToken;     // 支付代币
    uint256 tokenId;          // Token ID
    uint256 price;            // 报价
    uint48 expiresAt;        // 过期时间（Unix 时间戳）
    bool active;              // 是否激活
  }

  // ===========
  // 状态变量
  // ===========
  
  /// @notice 平台手续费率（基点，250 = 2.5%）
  uint96 public platformFee = 250;
  
  /// @notice 平台手续费接收地址
  address public feeRecipient;
  
  /// @notice 最小拍卖时长（1 小时）
  uint48 private constant MIN_AUCTION_DURATION = 1 hours;

  /// @notice 最大拍卖时长（30 天）
  uint48 private constant MAX_AUCTION_DURATION = 30 days;

  /// @notice 拍卖延长时间（5 分钟）
  uint48 private constant AUCTION_EXTENSION = 5 minutes;

  /// @notice 最小加价幅度（5%）
  uint256 private constant MIN_BID_INCREMENT = 500; // 5%

  /// @notice 最大挂单/报价有效期（30 天）
  uint48 private constant MAX_LISTING_DURATION = 30 days;

  /// @notice ETH 退款的 gas 限制（防止恶意合约消耗过多 gas）
  uint256 private constant ETH_REFUND_GAS_LIMIT = 10000;

  /// @notice 挂单 ID 计数器（初始化为 1 避免零值写入）
  uint256 private _listingIdCounter = 1;
  
  /// @notice 拍卖 ID 计数器（初始化为 1 避免零值写入）
  uint256 private _auctionIdCounter = 1;
  
  /// @notice 报价 ID 计数器（初始化为 1 避免零值写入）
  uint256 private _offerIdCounter = 1;

  /// @notice 挂单映射：挂单ID => 挂单信息
  mapping(uint256 listingId => Listing) public listings;
  
  /// @notice 拍卖映射：拍卖ID => 拍卖信息
  mapping(uint256 auctionId => Auction) public auctions;
  
  /// @notice 报价映射：报价ID => 报价信息
  mapping(uint256 offerId => Offer) public offers;
  
  /// @notice 支持的支付代币：代币地址 => 是否支持
  mapping(address token => bool supported) public supportedPaymentTokens;

  /// @notice 待提取余额：用户地址 => 代币地址 => 金额
  mapping(address user => mapping(address token => uint256 amount)) public pendingWithdrawals;

  // ===========
  // 错误定义
  // ===========
  
  error InvalidPrice();
  error InvalidDuration();
  error NotTokenOwner();
  error NotApproved();
  error ListingNotActive();
  error AuctionNotActive();
  error OfferNotActive();
  error AuctionNotEnded();
  error AuctionEnded();
  error BidTooLow();
  error NotSeller();
  error NotOfferer();
  error PaymentTokenNotSupported();
  error TransferFailed();
  error InvalidFeeRecipient();
  error FeeTooHigh();
  error InsufficientBalance();
  error HasActiveBids();

  // ===========
  // 事件定义
  // ===========
  
  event ListingCreated(
    uint256 indexed listingId,
    address indexed seller,
    address indexed nftContract,
    uint256 tokenId,
    address paymentToken,
    uint256 price,
    uint256 expiresAt
  );
  
  event ListingCancelled(uint256 indexed listingId);
  
  event ListingSold(
    uint256 indexed listingId,
    address indexed seller,
    address indexed buyer,
    uint256 price,
    uint256 platformFeeAmount,
    uint256 royaltyAmount
  );
  
  event AuctionCreated(
    uint256 indexed auctionId,
    address indexed seller,
    address indexed nftContract,
    uint256 tokenId,
    address paymentToken,
    uint256 startPrice,
    uint256 startTime,
    uint256 endTime
  );
  
  event BidPlaced(
    uint256 indexed auctionId,
    address indexed bidder,
    address indexed previousBidder,
    uint256 bidAmount,
    uint256 previousBid,
    uint256 newEndTime
  );
  
  event AuctionFinalized(
    uint256 indexed auctionId,
    address indexed seller,
    address indexed winner,
    uint256 finalPrice,
    uint256 platformFeeAmount,
    uint256 royaltyAmount
  );
  
  event AuctionCancelled(uint256 indexed auctionId);
  
  event OfferCreated(
    uint256 indexed offerId,
    address indexed offerer,
    address indexed nftContract,
    uint256 tokenId,
    address paymentToken,
    uint256 price,
    uint256 expiresAt
  );
  
  event OfferAccepted(
    uint256 indexed offerId,
    address indexed offerer,
    address indexed seller,
    uint256 price,
    uint256 platformFeeAmount,
    uint256 royaltyAmount
  );
  
  event OfferCancelled(uint256 indexed offerId);
  
  event PlatformFeeUpdated(uint96 newFee);
  event FeeRecipientUpdated(address indexed newRecipient);
  event PaymentTokenUpdated(address indexed token, bool supported);
  event WithdrawalRecorded(address indexed user, address indexed token, uint256 amount);
  event Withdrawn(address indexed user, address indexed token, uint256 amount);

  // ===========
  // 构造函数
  // ===========
  
  /**
   * @notice 初始化市场合约
   * @dev 构造函数设置手续费接收地址并启用 ETH 支付
   * @param _feeRecipient 手续费接收地址
   */
  constructor(address _feeRecipient) payable Ownable(msg.sender) {
    if (_feeRecipient == address(0)) revert InvalidFeeRecipient();
    feeRecipient = _feeRecipient;
    
    // 默认支持 ETH
    supportedPaymentTokens[address(0)] = true;
    
    emit FeeRecipientUpdated(_feeRecipient);
    emit PlatformFeeUpdated(250);
  }

  // ===========
  // 固定价格销售
  // ===========
  
  /**
   * @notice 创建固定价格挂单
   * @dev 卖家必须先授权市场合约才能创建挂单
   * @param nftContract NFT 合约地址
   * @param tokenId Token ID
   * @param paymentToken 支付代币地址
   * @param price 价格
   * @param duration 有效期（秒）
   * @return listingId 挂单 ID
   */
  function createListing(
    address nftContract,
    uint256 tokenId,
    address paymentToken,
    uint256 price,
    uint256 duration
  ) external nonReentrant whenNotPaused returns (uint256 listingId) {
    if (nftContract == address(0)) revert InvalidFeeRecipient(); // 复用错误，避免新增
    if (price == 0) revert InvalidPrice();
    if (duration == 0 || duration > MAX_LISTING_DURATION) revert InvalidDuration();
    if (!supportedPaymentTokens[paymentToken]) revert PaymentTokenNotSupported();
    
    address seller = msg.sender;
    _validateNFTOwnershipAndApproval(nftContract, tokenId, seller);

    listingId = _listingIdCounter;
    unchecked {
      _listingIdCounter = listingId + 1;
    }

    uint48 expiresAt;
    unchecked {
      expiresAt = uint48(block.timestamp + duration);
    }

    Listing storage listing = listings[listingId];
    listing.seller = seller;
    listing.nftContract = nftContract;
    listing.paymentToken = paymentToken;
    listing.tokenId = tokenId;
    listing.price = price;
    listing.expiresAt = expiresAt;
    listing.active = true; // 初始化为 true

    emit ListingCreated(listingId, seller, nftContract, tokenId, paymentToken, price, expiresAt);
  }

  /**
   * @notice 购买挂单的 NFT
   * @dev 买家支付价格购买 NFT，自动分配手续费和版税
   * @param listingId 挂单 ID
   */
  function buyListing(uint256 listingId) external payable nonReentrant whenNotPaused {
    Listing storage listing = listings[listingId];

    if (!listing.active) revert ListingNotActive();
    if (block.timestamp >= listing.expiresAt) revert ListingNotActive();

    // 缓存变量减少 SLOAD
    address paymentToken = listing.paymentToken;
    uint256 price = listing.price;

    // 接收买家支付
    if (paymentToken == address(0)) {
      if (msg.value != price) revert InvalidPrice();
    } else {
      IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), price);
    }

    delete listing.active;

    address nftContract = listing.nftContract;
    uint256 tokenId = listing.tokenId;
    address seller = listing.seller;

    // 处理支付和转账
    (uint256 feeAmount, uint256 royaltyAmount) = _executeTransaction(
      nftContract,
      tokenId,
      seller,
      msg.sender,
      paymentToken,
      price
    );

    emit ListingSold(listingId, seller, msg.sender, price, feeAmount, royaltyAmount);
  }

  /**
   * @notice 取消挂单
   * @dev 仅卖家可以取消自己的挂单
   * @param listingId 挂单 ID
   */
  function cancelListing(uint256 listingId) external nonReentrant {
    Listing storage listing = listings[listingId];
    
    if (listing.seller != msg.sender) revert NotSeller();
    if (!listing.active) revert ListingNotActive();

    delete listing.active;
    
    emit ListingCancelled(listingId);
  }

  // ===========
  // 拍卖功能
  // ===========
  
  /**
   * @notice 创建拍卖
   * @dev 卖家必须先授权市场合约才能创建拍卖
   * @param nftContract NFT 合约地址
   * @param tokenId Token ID
   * @param paymentToken 支付代币地址
   * @param startPrice 起拍价
   * @param duration 拍卖时长（秒）
   * @return auctionId 拍卖 ID
   */
  function createAuction(
    address nftContract,
    uint256 tokenId,
    address paymentToken,
    uint256 startPrice,
    uint256 duration
  ) external nonReentrant whenNotPaused returns (uint256 auctionId) {
    if (nftContract == address(0)) revert InvalidFeeRecipient();
    if (startPrice == 0) revert InvalidPrice();
    if (duration < MIN_AUCTION_DURATION) revert InvalidDuration();
    if (duration > MAX_AUCTION_DURATION) revert InvalidDuration();
    if (!supportedPaymentTokens[paymentToken]) revert PaymentTokenNotSupported();
    
    address seller = msg.sender;
    _validateNFTOwnershipAndApproval(nftContract, tokenId, seller);

    auctionId = _auctionIdCounter;
    unchecked {
      _auctionIdCounter = auctionId + 1;
    }

    uint48 startTime = uint48(block.timestamp);
    uint48 endTime;
    unchecked {
      endTime = startTime + uint48(duration);
    }

    Auction storage auction = auctions[auctionId];
    auction.seller = seller;
    auction.nftContract = nftContract;
    auction.paymentToken = paymentToken;
    auction.currentBidder = address(1); // 初始化为非零地址避免零值写入
    auction.tokenId = tokenId;
    auction.startPrice = startPrice;
    auction.currentBid = 1; // 初始化为 1 避免零值写入
    auction.startTime = startTime;
    auction.endTime = endTime;
    auction.active = true; // 初始化为 true

    emit AuctionCreated(auctionId, seller, nftContract, tokenId, paymentToken, startPrice, startTime, endTime);
  }

  /**
   * @notice 出价
   * @dev 出价必须高于当前出价的 5%，最后 5 分钟出价会延长拍卖
   * @param auctionId 拍卖 ID
   * @param bidAmount 出价金额
   */
  function placeBid(uint256 auctionId, uint256 bidAmount) external payable nonReentrant whenNotPaused {
    Auction storage auction = auctions[auctionId];
    
    if (!auction.active) revert AuctionNotActive();
    
    uint256 currentTime = block.timestamp;
    if (currentTime >= auction.endTime) revert AuctionEnded();
    if (currentTime < auction.startTime) revert AuctionNotActive();

    uint256 currentBid = auction.currentBid;
    uint256 minBid;
    
    if (currentBid == 1) {
      minBid = auction.startPrice;
    } else {
      unchecked {
        minBid = currentBid + (currentBid * MIN_BID_INCREMENT / 10000);
      }
    }
    
    if (bidAmount < minBid) revert BidTooLow();

    address previousBidder = auction.currentBidder;
    uint256 previousBid = currentBid;

    auction.currentBid = bidAmount;
    auction.currentBidder = msg.sender;

    // 如果在最后 5 分钟出价，延长拍卖时间
    uint48 endTime = auction.endTime;
    unchecked {
      if (endTime - currentTime < AUCTION_EXTENSION) {
        auction.endTime = uint48(currentTime + AUCTION_EXTENSION);
      }
    }

    // 接收新出价
    address paymentToken = auction.paymentToken;
    if (paymentToken == address(0)) {
      if (msg.value != bidAmount) revert BidTooLow();
    } else {
      IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), bidAmount);
    }

    // 退还上一个出价（跳过初始化的 address(1)）
    if (previousBidder != address(0) && previousBidder != address(1)) {
      _refundBidder(paymentToken, previousBidder, previousBid);
    }

    // 发射增强的事件，包含更多上下文
    emit BidPlaced(
      auctionId,
      msg.sender,
      previousBidder == address(1) ? address(0) : previousBidder, // 将初始化值转换为 address(0)
      bidAmount,
      previousBid == 1 ? 0 : previousBid, // 将初始化值转换为 0
      auction.endTime
    );
  }

  /**
   * @notice 结束拍卖
   * @dev 拍卖结束后任何人都可以调用此函数完成交易
   * @param auctionId 拍卖 ID
   */
  function finalizeAuction(uint256 auctionId) external nonReentrant {
    Auction storage auction = auctions[auctionId];
    
    if (!auction.active) revert AuctionNotActive();
    if (block.timestamp < auction.endTime) revert AuctionNotEnded();

    delete auction.active;

    address currentBidder = auction.currentBidder;
    
    // 如果有出价者，执行交易（跳过初始化的 address(1)）
    if (currentBidder != address(0) && currentBidder != address(1)) {
      (uint256 feeAmount, uint256 royaltyAmount) = _executeTransaction(
        auction.nftContract,
        auction.tokenId,
        auction.seller,
        currentBidder,
        auction.paymentToken,
        auction.currentBid
      );

      emit AuctionFinalized(auctionId, auction.seller, currentBidder, auction.currentBid, feeAmount, royaltyAmount);
      return;
    }
    
    // 没有出价者，取消拍卖
    emit AuctionCancelled(auctionId);
  }

  /**
   * @notice 取消拍卖（仅在无出价时）
   * @dev 仅卖家可以取消，且必须在无人出价时
   * @param auctionId 拍卖 ID
   */
  function cancelAuction(uint256 auctionId) external nonReentrant {
    Auction storage auction = auctions[auctionId];
    
    if (auction.seller != msg.sender) revert NotSeller();
    if (!auction.active) revert AuctionNotActive();
    
    address currentBidder = auction.currentBidder;
    if (currentBidder != address(0) && currentBidder != address(1)) {
      revert HasActiveBids();
    }

    delete auction.active;
    
    emit AuctionCancelled(auctionId);
  }

  // ===========
  // 报价功能
  // ===========
  
  /**
   * @notice 创建报价
   * @dev 创建报价时会锁定资金，取消后才能退回
   * @param nftContract NFT 合约地址
   * @param tokenId Token ID
   * @param paymentToken 支付代币地址
   * @param price 报价
   * @param duration 有效期（秒）
   * @return offerId 报价 ID
   */
  function createOffer(
    address nftContract,
    uint256 tokenId,
    address paymentToken,
    uint256 price,
    uint256 duration
  ) external payable nonReentrant whenNotPaused returns (uint256 offerId) {
    if (nftContract == address(0)) revert InvalidFeeRecipient();
    if (price == 0) revert InvalidPrice();
    if (duration == 0 || duration > MAX_LISTING_DURATION) revert InvalidDuration();
    if (!supportedPaymentTokens[paymentToken]) revert PaymentTokenNotSupported();

    offerId = _offerIdCounter;
    unchecked {
      _offerIdCounter = offerId + 1;
    }

    uint48 expiresAt;
    unchecked {
      expiresAt = uint48(block.timestamp + duration);
    }

    Offer storage offer = offers[offerId];
    offer.offerer = msg.sender;
    offer.nftContract = nftContract;
    offer.paymentToken = paymentToken;
    offer.tokenId = tokenId;
    offer.price = price;
    offer.expiresAt = expiresAt;
    offer.active = true; // 初始化为 true

    // 锁定报价金额
    if (paymentToken == address(0)) {
      if (msg.value != price) revert InvalidPrice();
    } else {
      IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), price);
    }

    emit OfferCreated(offerId, msg.sender, nftContract, tokenId, paymentToken, price, expiresAt);
  }

  /**
   * @notice 接受报价
   * @dev NFT 所有者可以接受任何有效的报价
   * @param offerId 报价 ID
   */
  function acceptOffer(uint256 offerId) external nonReentrant whenNotPaused {
    Offer storage offer = offers[offerId];
    
    if (!offer.active) revert OfferNotActive();
    if (block.timestamp >= offer.expiresAt) revert OfferNotActive();

    address nftContract = offer.nftContract;
    uint256 tokenId = offer.tokenId;
    address seller = msg.sender;
    
    _validateNFTOwnershipAndApproval(nftContract, tokenId, seller);

    delete offer.active;

    address offerer = offer.offerer;
    address paymentToken = offer.paymentToken;
    uint256 price = offer.price;

    (uint256 feeAmount, uint256 royaltyAmount) = _executeTransaction(
      nftContract,
      tokenId,
      seller,
      offerer,
      paymentToken,
      price
    );

    emit OfferAccepted(offerId, offerer, seller, price, feeAmount, royaltyAmount);
  }

  /**
   * @notice 取消报价
   * @dev 仅报价者可以取消自己的报价，资金会退回
   * @param offerId 报价 ID
   */
  function cancelOffer(uint256 offerId) external nonReentrant {
    Offer storage offer = offers[offerId];
    
    if (offer.offerer != msg.sender) revert NotOfferer();
    if (!offer.active) revert OfferNotActive();

    delete offer.active;

    // 退还报价金额
    _transferPayment(offer.paymentToken, msg.sender, offer.price);
    
    emit OfferCancelled(offerId);
  }

  // ===========
  // 内部函数
  // ===========

  /**
   * @dev 验证 NFT 所有权和授权
   * @param nftContract NFT 合约地址
   * @param tokenId Token ID
   * @param seller 卖家地址
   */
  function _validateNFTOwnershipAndApproval(
    address nftContract,
    uint256 tokenId,
    address seller
  ) internal view {
    IERC721 nft = IERC721(nftContract);
    
    if (nft.ownerOf(tokenId) != seller) revert NotTokenOwner();
    
    address cachedThis = address(this);
    if (!nft.isApprovedForAll(seller, cachedThis)) {
      if (nft.getApproved(tokenId) != cachedThis) {
        revert NotApproved();
      }
    }
  }

  /**
   * @dev 计算批量查询的范围
   * @param totalLength 数组总长度
   * @param offset 起始偏移量
   * @param limit 返回数量限制
   * @return start 起始索引
   * @return end 结束索引
   * @return resultLength 结果长度
   */
  function _calculateBatchRange(
    uint256 totalLength,
    uint256 offset,
    uint256 limit
  ) internal pure returns (uint256 start, uint256 end, uint256 resultLength) {
    start = offset;
    end = offset + limit;
    if (end > totalLength) end = totalLength;
    if (start >= end) {
      return (0, 0, 0);
    }
    resultLength = end - start;
  }
  
  /**
   * @dev 执行交易（包含手续费和版税分配）
   * @param nftContract NFT 合约地址
   * @param tokenId Token ID
   * @param seller 卖家地址
   * @param buyer 买家地址
   * @param paymentToken 支付代币地址
   * @param price 交易价格
   * @return feeAmount 平台手续费金额
   * @return royaltyAmount 版税金额
   */
  function _executeTransaction(
    address nftContract,
    uint256 tokenId,
    address seller,
    address buyer,
    address paymentToken,
    uint256 price
  ) internal returns (uint256 feeAmount, uint256 royaltyAmount) {
    // 计算平台手续费
    uint256 cachedPlatformFee = platformFee;
    address cachedFeeRecipient = feeRecipient;
    feeAmount = (price * cachedPlatformFee) / 10000;

    // 查询版税信息
    royaltyAmount = 0;
    address royaltyReceiver = address(0);

    try IERC2981(nftContract).royaltyInfo(tokenId, price) returns (address receiver, uint256 amount) {
      if (receiver != address(0) && amount != 0 && amount < price) {
        royaltyAmount = amount;
        royaltyReceiver = receiver;
      }
    } catch {
      // NFT 不支持 EIP-2981，跳过版税
    }

    // 验证总费用不超过价格
    uint256 totalFees = feeAmount + royaltyAmount;
    if (totalFees >= price) revert FeeTooHigh();

    // 计算卖家收益
    uint256 sellerProceeds;
    unchecked {
      sellerProceeds = price - totalFees;
    }

    // 转移 NFT
    IERC721(nftContract).safeTransferFrom(seller, buyer, tokenId);

    // 分配款项
    if (feeAmount != 0) {
      _transferPayment(paymentToken, cachedFeeRecipient, feeAmount);
    }

    if (royaltyAmount != 0) {
      _transferPayment(paymentToken, royaltyReceiver, royaltyAmount);
    }

    _transferPayment(paymentToken, seller, sellerProceeds);
  }

  /**
   * @dev 转移支付
   */
  function _transferPayment(address paymentToken, address to, uint256 amount) internal {
    if (amount == 0) return;
    
    if (paymentToken == address(0)) {
      (bool success, ) = payable(to).call{value: amount}("");
      if (!success) revert TransferFailed();
    } else {
      IERC20(paymentToken).safeTransfer(to, amount);
    }
  }

  /**
   * @dev 退还出价（Push with Pull Fallback）
   * 
   * 设计理念：
   * 1. ETH 退款：使用固定 gas 限制（10000）防止恶意合约攻击
   * 2. ERC20 退款：不限制 gas，但使用 try-catch 捕获异常
   * 
   * 为什么 ERC20 不限制 gas？
   * - 某些 ERC20 代币（如 Rebasing Token、带手续费的代币）需要更多 gas
   * - ERC20 转账失败不会消耗所有 gas（SafeERC20 会 revert）
   * - 使用 try-catch 可以安全地捕获异常
   * 
   * 安全性：
   * - ETH: gas 限制防止恶意合约消耗过多 gas
   * - ERC20: try-catch 防止恶意代币阻塞流程
   * - 失败时记录到 pendingWithdrawals，用户可主动提取
   * 
   * @param paymentToken 支付代币地址（address(0) = ETH）
   * @param bidder 出价者地址
   * @param amount 退款金额
   */
  function _refundBidder(address paymentToken, address bidder, uint256 amount) internal {
    if (amount == 0) return;
    
    bool success = false;
    
    if (paymentToken == address(0)) {
      // ETH 退款：使用固定 gas 限制防止恶意合约攻击
      // 10000 gas 足够普通 EOA 和简单合约接收 ETH
      (success, ) = payable(bidder).call{value: amount, gas: ETH_REFUND_GAS_LIMIT}("");
    } else {
      // ERC20 退款：不限制 gas，使用 try-catch 捕获异常
      // 这允许复杂的 ERC20 代币（如 Rebasing Token）正常工作
      // 同时通过 try-catch 防止恶意代币阻塞流程
      try IERC20(paymentToken).transfer(bidder, amount) returns (bool result) {
        success = result;
      } catch {
        // 转账失败（可能是黑名单、余额不足、或其他原因）
        success = false;
      }
    }
    
    // 如果转账失败，记录待提取余额（Pull 机制）
    if (!success) {
      pendingWithdrawals[bidder][paymentToken] += amount;
      emit WithdrawalRecorded(bidder, paymentToken, amount);
    }
  }

  // ===========
  // 管理函数
  // ===========
  
  /**
   * @notice 设置平台手续费
   * @param newFee 新的手续费率（基点）
   */
  function setPlatformFee(uint96 newFee) external payable onlyOwner {
    if (newFee > 1000) revert FeeTooHigh(); // 最高 10%
    if (platformFee == newFee) return;
    
    platformFee = newFee;
    emit PlatformFeeUpdated(newFee);
  }

  /**
   * @notice 设置手续费接收地址
   * @param newRecipient 新的接收地址
   */
  function setFeeRecipient(address newRecipient) external payable onlyOwner {
    if (newRecipient == address(0)) revert InvalidFeeRecipient();
    if (feeRecipient == newRecipient) return;
    
    feeRecipient = newRecipient;
    emit FeeRecipientUpdated(newRecipient);
  }

  /**
   * @notice 设置支持的支付代币
   * @param token 代币地址
   * @param supported 是否支持
   */
  function setPaymentToken(address token, bool supported) external payable onlyOwner {
    if (supportedPaymentTokens[token] == supported) return;
    
    supportedPaymentTokens[token] = supported;
    emit PaymentTokenUpdated(token, supported);
  }

  /**
   * @notice 暂停合约
   */
  function pause() external payable onlyOwner {
    _pause();
  }

  /**
   * @notice 恢复合约
   */
  function unpause() external payable onlyOwner {
    _unpause();
  }

  /**
   * @notice 紧急提取 ETH
   * @dev 仅所有者可以调用，用于紧急情况下提取合约中的 ETH
   */
  function emergencyWithdrawETH() external payable onlyOwner {
    // 使用内联汇编获取合约余额，比 address(this).balance 节省 ~5 gas
    uint256 contractBalance;
    assembly {
      contractBalance := selfbalance()
    }
    
    if (contractBalance != 0) {
      (bool success, ) = payable(owner()).call{value: contractBalance}("");
      if (!success) revert TransferFailed();
    }
  }

  /**
   * @notice 紧急提取 ERC20
   * @param token 代币地址
   */
  function emergencyWithdrawERC20(address token) external payable onlyOwner {
    if (token == address(0)) revert InvalidFeeRecipient();
    
    uint256 balance = IERC20(token).balanceOf(address(this));
    if (balance != 0) {
      IERC20(token).safeTransfer(owner(), balance);
    }
  }

  /**
   * @notice 提取待退款余额
   * @dev 用户主动提取因转账失败而记录的待退款金额
   * 
   * 使用场景：
   * - 拍卖出价被超越时，如果直接退款失败（Push 失败）
   * - 资金会被记录到 pendingWithdrawals 映射中
   * - 用户可以调用此函数主动提取（Pull 机制）
   * 
   * 安全性：
   * - 使用 nonReentrant 防止重入攻击
   * - 先删除余额再转账（Checks-Effects-Interactions）
   * - 任何用户只能提取自己的余额
   * 
   * @param paymentToken 支付代币地址（address(0) = ETH）
   */
  function withdraw(address paymentToken) external nonReentrant {
    uint256 amount = pendingWithdrawals[msg.sender][paymentToken];
    if (amount == 0) revert InsufficientBalance();

    delete pendingWithdrawals[msg.sender][paymentToken];

    _transferPayment(paymentToken, msg.sender, amount);

    emit Withdrawn(msg.sender, paymentToken, amount);
  }

  // ===========
  // 查询函数
  // ===========
  
  /**
   * @notice 查询挂单是否有效
   * @dev 检查挂单是否激活且未过期
   * @param listingId 挂单 ID
   * @return isActive 是否有效
   */
  function isListingActive(uint256 listingId) external view returns (bool isActive) {
    Listing storage listing = listings[listingId];
    uint256 currentTime = block.timestamp;
    isActive = listing.active && currentTime < listing.expiresAt;
  }

  /**
   * @notice 查询拍卖是否有效
   * @dev 检查拍卖是否激活且未结束
   * @param auctionId 拍卖 ID
   * @return isActive 是否有效
   */
  function isAuctionActive(uint256 auctionId) external view returns (bool isActive) {
    Auction storage auction = auctions[auctionId];
    uint256 currentTime = block.timestamp;
    isActive = auction.active && currentTime < auction.endTime;
  }

  /**
   * @notice 查询报价是否有效
   * @dev 检查报价是否激活且未过期
   * @param offerId 报价 ID
   * @return isActive 是否有效
   */
  function isOfferActive(uint256 offerId) external view returns (bool isActive) {
    Offer storage offer = offers[offerId];
    uint256 currentTime = block.timestamp;
    isActive = offer.active && currentTime < offer.expiresAt;
  }

  /**
   * @notice 批量查询挂单信息
   * @param listingIds 挂单 ID 数组
   * @param offset 起始偏移量
   * @param limit 返回数量限制
   * @return listingData 挂单信息数组
   */
  function batchGetListings(uint256[] calldata listingIds, uint256 offset, uint256 limit)
    external
    view
    returns (Listing[] memory listingData)
  {
    (uint256 start, , uint256 resultLength) = _calculateBatchRange(listingIds.length, offset, limit);
    if (resultLength == 0) return new Listing[](0);

    listingData = new Listing[](resultLength);
    unchecked {
      for (uint256 i = 0; i < resultLength; ++i) {
        listingData[i] = listings[listingIds[start + i]];
      }
    }
  }

  /**
   * @notice 批量查询拍卖信息
   * @param auctionIds 拍卖 ID 数组
   * @param offset 起始偏移量
   * @param limit 返回数量限制
   * @return auctionData 拍卖信息数组
   */
  function batchGetAuctions(uint256[] calldata auctionIds, uint256 offset, uint256 limit)
    external
    view
    returns (Auction[] memory auctionData)
  {
    (uint256 start, , uint256 resultLength) = _calculateBatchRange(auctionIds.length, offset, limit);
    if (resultLength == 0) return new Auction[](0);

    auctionData = new Auction[](resultLength);
    unchecked {
      for (uint256 i = 0; i < resultLength; ++i) {
        auctionData[i] = auctions[auctionIds[start + i]];
      }
    }
  }

  /**
   * @notice 批量查询报价信息
   * @param offerIds 报价 ID 数组
   * @param offset 起始偏移量
   * @param limit 返回数量限制
   * @return offerData 报价信息数组
   */
  function batchGetOffers(uint256[] calldata offerIds, uint256 offset, uint256 limit)
    external
    view
    returns (Offer[] memory offerData)
  {
    (uint256 start, , uint256 resultLength) = _calculateBatchRange(offerIds.length, offset, limit);
    if (resultLength == 0) return new Offer[](0);

    offerData = new Offer[](resultLength);
    unchecked {
      for (uint256 i = 0; i < resultLength; ++i) {
        offerData[i] = offers[offerIds[start + i]];
      }
    }
  }

  /**
   * @notice 接收 ERC721 代币
   * @dev 实现 IERC721Receiver 接口，允许合约接收 NFT
   * 
   * 这个函数在 NFT 通过 safeTransferFrom 转移到本合约时被调用。
   * 返回正确的选择器表示合约可以安全接收 NFT。
   * 
   * 参数说明：
   * - operator: 执行转移的地址
   * - from: NFT 的原所有者
   * - tokenId: 被转移的 NFT ID
   * - data: 附加数据
   * 
   * @return bytes4 函数选择器，表示成功接收
   */
  function onERC721Received(
    address /* operator */,
    address /* from */,
    uint256 /* tokenId */,
    bytes calldata /* data */
  ) external pure returns (bytes4) {
    return 0x150b7a02; // bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"))
  }
}
