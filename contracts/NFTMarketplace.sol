// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

/**
 * @title NFTMarketplace
 * @notice 支持固定价格销售、版税分配的 NFT 交易市场
 * @dev 
 * 支持 ETH 和 ERC20 代币支付，集成 EIP-2981 版税标准
 * 
 * 核心功能：
 * - 固定价格销售：创建挂单、购买、取消
 * - 版税支持：自动分配 EIP-2981 版税
 * - 多代币支付：支持 ETH 和白名单 ERC20 代币
 * 
 * 可升级：使用 UUPS 代理模式
 */
contract NFTMarketplace is 
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable 
{
    using SafeERC20 for IERC20;

    // ============================================================
    //                         STRUCTS
    // ============================================================

    /// @notice 挂单信息
    struct Listing {
        address seller;           // 卖家地址
        address nftContract;      // NFT 合约地址
        uint256 tokenId;          // Token ID
        uint256 price;            // 价格
        address paymentToken;     // 支付代币 (address(0) = ETH)
        uint64 createdAt;         // 创建时间
        bool active;              // 是否有效
    }

    // ============================================================
    //                        STORAGE
    // ============================================================

    /// @notice 平台手续费 (基点, 100 = 1%)
    uint16 public platformFeeBps;
    
    /// @notice 手续费接收地址
    address public feeRecipient;
    
    /// @notice 挂单 ID 计数器
    uint256 private _listingIdCounter;
    
    /// @notice 挂单 ID => 挂单信息
    mapping(uint256 => Listing) public listings;
    
    /// @notice NFT 合约 => tokenId => 挂单 ID (用于快速查找)
    mapping(address => mapping(uint256 => uint256)) public nftToListingId;
    
    /// @notice 支持的支付代币白名单
    mapping(address => bool) public supportedPaymentTokens;

    /// @notice 支持的 NFT 合约地址
    address public nftContract;

    // ============================================================
    //                         ERRORS
    // ============================================================

    error ErrZeroAddress();
    error ErrZeroPrice();
    error ErrNotOwner();
    error ErrNotApproved();
    error ErrListingNotActive();
    error ErrInsufficientPayment();
    error ErrPaymentTokenNotSupported();
    error ErrCannotBuyOwnListing();
    error ErrAlreadyListed();
    error ErrFeeTooHigh();
    error ErrTransferFailed();
    error ErrArrayLengthMismatch();
    error ErrBatchTooLarge();

    // ============================================================
    //                         EVENTS
    // ============================================================

    event Listed(
        uint256 indexed listingId,
        address indexed seller,
        address indexed nftContract,
        uint256 tokenId,
        uint256 price,
        address paymentToken
    );
    
    event Sale(
        uint256 indexed listingId,
        address indexed buyer,
        address indexed seller,
        address nftContract,
        uint256 tokenId,
        uint256 price,
        address paymentToken
    );
    
    event ListingCancelled(uint256 indexed listingId);
    event ListingUpdated(uint256 indexed listingId, uint256 newPrice);
    event BatchListed(
        address indexed seller,
        address indexed nftContract,
        uint256[] tokenIds,
        uint256[] listingIds,
        uint256[] prices,
        address paymentToken
    );
    event PlatformFeeUpdated(uint16 newFeeBps);
    event FeeRecipientUpdated(address newRecipient);
    event PaymentTokenUpdated(address token, bool supported);

    // ============================================================
    //                       INITIALIZER
    // ============================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice 初始化合约
     * @param owner_ 合约所有者
     * @param nftContract_ NFT 合约地址
     * @param feeRecipient_ 手续费接收地址
     * @param platformFeeBps_ 平台手续费 (基点)
     */
    function initialize(
        address owner_,
        address nftContract_,
        address feeRecipient_,
        uint16 platformFeeBps_
    ) external initializer {
        if (owner_ == address(0) || nftContract_ == address(0) || feeRecipient_ == address(0)) revert ErrZeroAddress();
        if (platformFeeBps_ > 1000) revert ErrFeeTooHigh(); // 最高 10%

        __Ownable2Step_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _transferOwnership(owner_);
        nftContract = nftContract_;
        feeRecipient = feeRecipient_;
        platformFeeBps = platformFeeBps_;
        _listingIdCounter = 1;

        // ETH 默认支持
        supportedPaymentTokens[address(0)] = true;
    }

    // ============================================================
    //                     LISTING FUNCTIONS
    // ============================================================

    /**
     * @notice 创建挂单
     * @param nftContract_ NFT 合约地址
     * @param tokenId Token ID
     * @param price 价格
     * @param paymentToken 支付代币 (address(0) = ETH)
     * @return listingId 挂单 ID
     */
    function createListing(
        address nftContract_,
        uint256 tokenId,
        uint256 price,
        address paymentToken
    ) external returns (uint256 listingId) {
        if (price == 0) revert ErrZeroPrice();
        if (!supportedPaymentTokens[paymentToken]) revert ErrPaymentTokenNotSupported();
        
        IERC721 nft = IERC721(nftContract_);
        if (nft.ownerOf(tokenId) != msg.sender) revert ErrNotOwner();
        if (!nft.isApprovedForAll(msg.sender, address(this)) &&
            nft.getApproved(tokenId) != address(this)) {
            revert ErrNotApproved();
        }

        // 检查是否已挂单
        uint256 existingId = nftToListingId[nftContract_][tokenId];
        if (existingId != 0 && listings[existingId].active) {
            revert ErrAlreadyListed();
        }

        listingId = _listingIdCounter++;

        listings[listingId] = Listing({
            seller: msg.sender,
            nftContract: nftContract_,
            tokenId: tokenId,
            price: price,
            paymentToken: paymentToken,
            createdAt: uint64(block.timestamp),
            active: true
        });

        nftToListingId[nftContract_][tokenId] = listingId;

        emit Listed(listingId, msg.sender, nftContract_, tokenId, price, paymentToken);
    }

    /**
     * @notice 批量创建挂单（最多 1000 个）
     * @param tokenIds Token ID 数组
     * @param prices 价格数组（对应每个 tokenId）
     * @param paymentToken 支付代币 (address(0) = ETH)
     * @return listingIds 挂单 ID 数组
     */
    function batchCreateListings(
        uint256[] calldata tokenIds,
        uint256[] calldata prices,
        address paymentToken
    ) external returns (uint256[] memory listingIds) {
        uint256 length = tokenIds.length;
        if (length != prices.length) revert ErrArrayLengthMismatch();
        if (length == 0 || length > 1000) revert ErrBatchTooLarge(); // 限制批量大小避免 gas 过高

        if (!supportedPaymentTokens[paymentToken]) revert ErrPaymentTokenNotSupported();

        IERC721 nft = IERC721(nftContract);
        listingIds = new uint256[](length);

        // 预检查所有 NFT
        for (uint256 i; i < length;) {
            uint256 tokenId = tokenIds[i];
            uint256 price = prices[i];

            if (price == 0) revert ErrZeroPrice();
            if (nft.ownerOf(tokenId) != msg.sender) revert ErrNotOwner();

            // 检查是否已挂单
            uint256 existingId = nftToListingId[nftContract][tokenId];
            if (existingId != 0 && listings[existingId].active) {
                revert ErrAlreadyListed();
            }

            unchecked { ++i; }
        }

        // 检查授权（只需要检查一次，因为所有 NFT 都属于同一个所有者）
        if (!nft.isApprovedForAll(msg.sender, address(this))) {
            // 如果没有设置 isApprovedForAll，需要检查每个 token 的 getApproved
            for (uint256 i; i < length;) {
                if (nft.getApproved(tokenIds[i]) != address(this)) {
                    revert ErrNotApproved();
                }
                unchecked { ++i; }
            }
        }

        // 批量创建挂单
        unchecked {
            for (uint256 i; i < length; ++i) {
                uint256 listingId = _listingIdCounter++;
                uint256 tokenId = tokenIds[i];
                uint256 price = prices[i];

                listings[listingId] = Listing({
                    seller: msg.sender,
                    nftContract: nftContract,
                    tokenId: tokenId,
                    price: price,
                    paymentToken: paymentToken,
                    createdAt: uint64(block.timestamp),
                    active: true
                });

                nftToListingId[nftContract][tokenId] = listingId;
                listingIds[i] = listingId;
            }
        }

        emit BatchListed(msg.sender, nftContract, tokenIds, listingIds, prices, paymentToken);
    }

    /**
     * @notice 购买 NFT
     * @param listingId 挂单 ID
     */
    function buy(uint256 listingId) external payable nonReentrant {
        Listing storage listing = listings[listingId];
        if (!listing.active) revert ErrListingNotActive();
        if (listing.seller == msg.sender) revert ErrCannotBuyOwnListing();
        
        listing.active = false;
        delete nftToListingId[listing.nftContract][listing.tokenId];
        
        // 处理支付
        _processPayment(listing);
        
        // 转移 NFT
        IERC721(listing.nftContract).safeTransferFrom(
            listing.seller,
            msg.sender,
            listing.tokenId
        );
        
        emit Sale(
            listingId,
            msg.sender,
            listing.seller,
            listing.nftContract,
            listing.tokenId,
            listing.price,
            listing.paymentToken
        );
    }

    /**
     * @notice 取消挂单
     * @param listingId 挂单 ID
     */
    function cancelListing(uint256 listingId) external {
        Listing storage listing = listings[listingId];
        if (!listing.active) revert ErrListingNotActive();
        if (listing.seller != msg.sender) revert ErrNotOwner();
        
        listing.active = false;
        delete nftToListingId[listing.nftContract][listing.tokenId];
        
        emit ListingCancelled(listingId);
    }

    /**
     * @notice 更新挂单价格
     * @param listingId 挂单 ID
     * @param newPrice 新价格
     */
    function updateListing(uint256 listingId, uint256 newPrice) external {
        if (newPrice == 0) revert ErrZeroPrice();
        
        Listing storage listing = listings[listingId];
        if (!listing.active) revert ErrListingNotActive();
        if (listing.seller != msg.sender) revert ErrNotOwner();
        
        listing.price = newPrice;
        
        emit ListingUpdated(listingId, newPrice);
    }

    // ============================================================
    //                     ADMIN FUNCTIONS
    // ============================================================

    /**
     * @notice 设置平台手续费
     * @param newFeeBps 新手续费 (基点)
     */
    function setPlatformFee(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > 1000) revert ErrFeeTooHigh();
        platformFeeBps = newFeeBps;
        emit PlatformFeeUpdated(newFeeBps);
    }

    /**
     * @notice 设置手续费接收地址
     * @param newRecipient 新地址
     */
    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ErrZeroAddress();
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);
    }

    /**
     * @notice 设置支付代币支持状态
     * @param token 代币地址
     * @param supported 是否支持
     */
    function setPaymentToken(address token, bool supported) external onlyOwner {
        supportedPaymentTokens[token] = supported;
        emit PaymentTokenUpdated(token, supported);
    }

    // ============================================================
    //                     VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice 获取挂单信息
     * @param listingId 挂单 ID
     */
    function getListing(uint256 listingId) external view returns (Listing memory) {
        return listings[listingId];
    }

    /**
     * @notice 通过 NFT 获取挂单 ID
     * @param nftContract_ NFT 合约地址
     * @param tokenId Token ID
     */
    function getListingIdByNFT(address nftContract_, uint256 tokenId) external view returns (uint256) {
        return nftToListingId[nftContract_][tokenId];
    }

    /**
     * @notice 获取当前挂单计数
     */
    function listingCount() external view returns (uint256) {
        return _listingIdCounter - 1;
    }

    // ============================================================
    //                   INTERNAL FUNCTIONS
    // ============================================================

    /**
     * @notice 处理支付（含版税和手续费分配）
     */
    function _processPayment(Listing storage listing) internal {
        uint256 price = listing.price;
        uint256 platformFee = (price * platformFeeBps) / 10000;
        uint256 royaltyAmount = 0;
        address royaltyRecipient = address(0);
        
        // 检查 EIP-2981 版税
        try IERC2981(listing.nftContract).royaltyInfo(listing.tokenId, price) returns (
            address receiver,
            uint256 amount
        ) {
            if (receiver != address(0) && amount > 0 && amount <= price - platformFee) {
                royaltyRecipient = receiver;
                royaltyAmount = amount;
            }
        } catch {}
        
        uint256 sellerAmount = price - platformFee - royaltyAmount;
        
        if (listing.paymentToken == address(0)) {
            // ETH 支付
            if (msg.value < price) revert ErrInsufficientPayment();
            
            // 退还多余 ETH
            if (msg.value > price) {
                (bool refundSuccess, ) = msg.sender.call{value: msg.value - price}("");
                if (!refundSuccess) revert ErrTransferFailed();
            }
            
            // 分配资金
            if (platformFee > 0) {
                (bool feeSuccess, ) = feeRecipient.call{value: platformFee}("");
                if (!feeSuccess) revert ErrTransferFailed();
            }
            
            if (royaltyAmount > 0) {
                (bool royaltySuccess, ) = royaltyRecipient.call{value: royaltyAmount}("");
                if (!royaltySuccess) revert ErrTransferFailed();
            }
            
            (bool sellerSuccess, ) = listing.seller.call{value: sellerAmount}("");
            if (!sellerSuccess) revert ErrTransferFailed();
            
        } else {
            // ERC20 支付
            IERC20 token = IERC20(listing.paymentToken);
            
            if (platformFee > 0) {
                token.safeTransferFrom(msg.sender, feeRecipient, platformFee);
            }
            
            if (royaltyAmount > 0) {
                token.safeTransferFrom(msg.sender, royaltyRecipient, royaltyAmount);
            }
            
            token.safeTransferFrom(msg.sender, listing.seller, sellerAmount);
        }
    }

    /**
     * @notice UUPS 升级授权
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @notice 获取合约版本
     */
    function version() external pure returns (string memory) {
        return "1.0.0";
    }
}
