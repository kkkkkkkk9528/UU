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
 * @notice NFT marketplace supporting fixed-price sales and royalty distribution
 * @dev
 * Supports ETH and ERC20 token payments, integrates EIP-2981 royalty standard
 *
 * Core features:
 * - Fixed-price sales: create listings, buy, cancel
 * - Royalty support: automatic EIP-2981 royalty distribution
 * - Multi-token payments: supports ETH and whitelisted ERC20 tokens
 *
 * Upgradeable: uses UUPS proxy pattern
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

    /// @notice Listing information
    struct Listing {
        address seller;           // Seller address
        address nftContract;      // NFT contract address
        uint256 tokenId;          // Token ID
        uint256 price;            // Price
        address paymentToken;     // Payment token (address(0) = ETH)
        uint64 createdAt;         // Creation timestamp
        bool active;              // Whether active
    }

    // ============================================================
    //                        STORAGE
    // ============================================================

    /// @notice Platform fee in basis points (100 = 1%)
    uint16 public platformFeeBps;

    /// @notice Fee recipient address
    address public feeRecipient;

    /// @notice Listing ID counter
    uint256 private _listingIdCounter;

    /// @notice listingId => listing info
    mapping(uint256 => Listing) public listings;

    /// @notice NFT contract => tokenId => listingId (for quick lookup)
    mapping(address => mapping(uint256 => uint256)) public nftToListingId;

    /// @notice Supported payment token whitelist
    mapping(address => bool) public supportedPaymentTokens;

    /// @notice Supported NFT contract address
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
     * @notice Initialize contract
     * @param owner_ Contract owner
     * @param nftContract_ NFT contract address
     * @param feeRecipient_ Fee recipient address
     * @param platformFeeBps_ Platform fee in basis points
     */
    function initialize(
        address owner_,
        address nftContract_,
        address feeRecipient_,
        uint16 platformFeeBps_
    ) external initializer {
        if (owner_ == address(0) || nftContract_ == address(0) || feeRecipient_ == address(0)) revert ErrZeroAddress();
        if (platformFeeBps_ > 1000) revert ErrFeeTooHigh(); // Max 10%

        __Ownable2Step_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _transferOwnership(owner_);
        nftContract = nftContract_;
        feeRecipient = feeRecipient_;
        platformFeeBps = platformFeeBps_;
        _listingIdCounter = 1;

        // ETH supported by default
        supportedPaymentTokens[address(0)] = true;
    }

    // ============================================================
    //                     LISTING FUNCTIONS
    // ============================================================

    /**
     * @notice Create listing
     * @param nftContract_ NFT contract address
     * @param tokenId Token ID
     * @param price Price
     * @param paymentToken Payment token (address(0) = ETH)
     * @return listingId Listing ID
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

        // Check if already listed
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
     * @notice Batch create listings (max 1000)
     * @param tokenIds Token ID array
     * @param prices Price array (corresponding to each tokenId)
     * @param paymentToken Payment token (address(0) = ETH)
     * @return listingIds Listing ID array
     */
    function batchCreateListings(
        uint256[] calldata tokenIds,
        uint256[] calldata prices,
        address paymentToken
    ) external returns (uint256[] memory listingIds) {
        uint256 length = tokenIds.length;
        if (length != prices.length) revert ErrArrayLengthMismatch();
        if (length == 0 || length > 1000) revert ErrBatchTooLarge(); // Limit batch size to avoid high gas costs

        if (!supportedPaymentTokens[paymentToken]) revert ErrPaymentTokenNotSupported();

        IERC721 nft = IERC721(nftContract);
        listingIds = new uint256[](length);

        // Pre-check all NFTs
        for (uint256 i; i < length;) {
            uint256 tokenId = tokenIds[i];
            uint256 price = prices[i];

            if (price == 0) revert ErrZeroPrice();
            if (nft.ownerOf(tokenId) != msg.sender) revert ErrNotOwner();

            // Check if already listed
            uint256 existingId = nftToListingId[nftContract][tokenId];
            if (existingId != 0 && listings[existingId].active) {
                revert ErrAlreadyListed();
            }

            unchecked { ++i; }
        }

        // Check approvals (only once since all NFTs belong to same owner)
        if (!nft.isApprovedForAll(msg.sender, address(this))) {
            // If isApprovedForAll not set, check each token's getApproved
            for (uint256 i; i < length;) {
                if (nft.getApproved(tokenIds[i]) != address(this)) {
                    revert ErrNotApproved();
                }
                unchecked { ++i; }
            }
        }

        // Batch create listings
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
     * @notice Buy NFT
     * @param listingId Listing ID
     */
    function buy(uint256 listingId) external payable nonReentrant {
        Listing storage listing = listings[listingId];
        if (!listing.active) revert ErrListingNotActive();
        if (listing.seller == msg.sender) revert ErrCannotBuyOwnListing();
        
        // Cache storage variables (gas optimization)
        address seller = listing.seller;
        address nftAddr = listing.nftContract;
        uint256 tokenId = listing.tokenId;
        uint256 price = listing.price;
        address paymentToken = listing.paymentToken;

        // Effects: Update state first (CEI pattern)
        listing.active = false;
        delete nftToListingId[nftAddr][tokenId];

        // Emit event before external calls (CEI pattern)
        emit Sale(listingId, msg.sender, seller, nftAddr, tokenId, price, paymentToken);

        // Interactions: Process payment
        _processPayment(seller, nftAddr, tokenId, price, paymentToken);

        // Transfer NFT
        IERC721(nftAddr).safeTransferFrom(seller, msg.sender, tokenId);
    }

    /**
     * @notice Cancel listing
     * @param listingId Listing ID
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
     * @notice Update listing price
     * @param listingId Listing ID
     * @param newPrice New price
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
     * @notice Set platform fee
     * @param newFeeBps New fee in basis points
     */
    function setPlatformFee(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > 1000) revert ErrFeeTooHigh();
        if (newFeeBps == platformFeeBps) return; // Avoid redundant setting
        platformFeeBps = newFeeBps;
        emit PlatformFeeUpdated(newFeeBps);
    }

    /**
     * @notice Set fee recipient address
     * @param newRecipient New address
     */
    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ErrZeroAddress();
        if (newRecipient == feeRecipient) return; // Avoid redundant setting
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);
    }

    /**
     * @notice Set payment token support status
     * @param token Token address
     * @param supported Whether supported
     */
    function setPaymentToken(address token, bool supported) external onlyOwner {
        if (supportedPaymentTokens[token] == supported) return; // Avoid redundant setting
        supportedPaymentTokens[token] = supported;
        emit PaymentTokenUpdated(token, supported);
    }

    // ============================================================
    //                     VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Get listing information
     * @param listingId Listing ID
     */
    function getListing(uint256 listingId) external view returns (Listing memory) {
        return listings[listingId];
    }

    /**
     * @notice Get listing ID by NFT
     * @param nftContract_ NFT contract address
     * @param tokenId Token ID
     */
    function getListingIdByNFT(address nftContract_, uint256 tokenId) external view returns (uint256) {
        return nftToListingId[nftContract_][tokenId];
    }

    /**
     * @notice Get current listing count
     */
    function listingCount() external view returns (uint256) {
        return _listingIdCounter - 1;
    }

    // ============================================================
    //                   INTERNAL FUNCTIONS
    // ============================================================

    /**
     * @notice Process payment (including royalty and fee distribution)
     */
    function _processPayment(
        address seller,
        address nftAddr,
        uint256 tokenId,
        uint256 price,
        address paymentToken
    ) internal {
        // Cache storage variables (gas optimization)
        uint256 feeBps = platformFeeBps;
        address feeAddr = feeRecipient;

        uint256 platformFee = (price * feeBps) / 10000;
        uint256 royaltyAmount;
        address royaltyRecipient;

        // Check EIP-2981 royalty
        try IERC2981(nftAddr).royaltyInfo(tokenId, price) returns (
            address receiver,
            uint256 amount
        ) {
            if (receiver != address(0) && amount != 0 && amount <= price - platformFee) {
                royaltyRecipient = receiver;
                royaltyAmount = amount;
            }
        } catch {}
        
        uint256 sellerAmount = price - platformFee - royaltyAmount;
        
        if (paymentToken == address(0)) {
            // ETH payment
            if (msg.value < price) revert ErrInsufficientPayment();

            // Refund excess ETH
            if (msg.value > price) {
                (bool refundSuccess, ) = msg.sender.call{value: msg.value - price}("");
                if (!refundSuccess) revert ErrTransferFailed();
            }

            // Distribute funds
            if (platformFee != 0) {
                (bool feeSuccess, ) = feeAddr.call{value: platformFee}("");
                if (!feeSuccess) revert ErrTransferFailed();
            }
            
            if (royaltyAmount != 0) {
                (bool royaltySuccess, ) = royaltyRecipient.call{value: royaltyAmount}("");
                if (!royaltySuccess) revert ErrTransferFailed();
            }
            
            (bool sellerSuccess, ) = seller.call{value: sellerAmount}("");
            if (!sellerSuccess) revert ErrTransferFailed();
            
        } else {
            // ERC20 payment
            IERC20 token = IERC20(paymentToken);
            
            if (platformFee != 0) {
                token.safeTransferFrom(msg.sender, feeAddr, platformFee);
            }
            
            if (royaltyAmount != 0) {
                token.safeTransferFrom(msg.sender, royaltyRecipient, royaltyAmount);
            }
            
            token.safeTransferFrom(msg.sender, seller, sellerAmount);
        }
    }

    /**
     * @notice UUPS upgrade authorization
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @notice Get contract version
     */
    function version() external pure returns (string memory) {
        return "1.0.0";
    }
}
