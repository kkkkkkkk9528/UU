// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title NFT
 * @notice Tiered ERC721 NFT contract supporting collectible rarity + membership benefits
 * @dev
 * Tier system: Silver(1) → Gold(2) → Diamond(3)
 * Each tier has independent mint price, supply cap, benefit multiplier
 */
contract NFT is ERC721, ERC721Enumerable, ERC721URIStorage, Ownable2Step, ReentrancyGuard {
    
    // ============================================================
    //                         ENUMS
    // ============================================================
    
    /// @notice NFT tier
    enum Tier {
        None,       // 0 - Invalid
        Silver,     // 1 - Silver
        Gold,       // 2 - Gold
        Diamond     // 3 - Diamond
    }

    // ============================================================
    //                        STRUCTS
    // ============================================================
    
    /// @notice Tier configuration
    struct TierConfig {
        uint64 maxSupply;         // Max supply for this tier (0 = unlimited)
        uint64 minted;            // Number minted for this tier
        uint128 mintPrice;        // Mint price
        uint16 benefitMultiplier; // Benefit multiplier (100 = 1x, 200 = 2x)
        bool publicMintEnabled;   // Whether public minting is enabled
    }

    // ============================================================
    //                        STORAGE
    // ============================================================
    
    /// @notice Next tokenId (starts from 1)
    uint256 private _nextTokenId;

    /// @notice Base URI
    string private _baseTokenURI;

    /// @notice tokenId => tier
    mapping(uint256 => Tier) private _tokenTier;

    /// @notice tier => configuration
    mapping(Tier => TierConfig) public tierConfigs;

    // ============================================================
    //                         ERRORS
    // ============================================================
    
    error ErrZeroAddress();
    error ErrInvalidTier();
    error ErrTierMaxSupplyReached();
    error ErrInsufficientPayment();
    error ErrPublicMintDisabled();
    error ErrInvalidAmount();
    error ErrWithdrawFailed();
    error ErrNotTokenOwner();

    // ============================================================
    //                         EVENTS
    // ============================================================
    
    event BaseURIUpdated(string newBaseURI);
    event TierConfigUpdated(Tier indexed tier, uint64 maxSupply, uint128 mintPrice, uint16 benefitMultiplier);
    event TierPublicMintToggled(Tier indexed tier, bool enabled);
    event Minted(address indexed to, uint256 indexed tokenId, Tier indexed tier);
    event BatchMinted(address indexed to, uint256 startTokenId, uint256 amount, Tier tier);

    // ============================================================
    //                       CONSTRUCTOR
    // ============================================================
    
    /**
     * @param name_ NFT name
     * @param symbol_ NFT symbol
     * @param owner_ Contract owner
     * @param baseURI_ Base URI
     */
    constructor(
        string memory name_,
        string memory symbol_,
        address owner_,
        string memory baseURI_
    ) ERC721(name_, symbol_) Ownable(owner_) {
        if (owner_ == address(0)) revert ErrZeroAddress();
        
        _nextTokenId = 1;
        _baseTokenURI = baseURI_;
        
        // Default tier configurations (total supply: 21000)
        // Silver: 12000, 1x benefits
        // Gold:   8000, 2x benefits
        // Diamond: 2100, 5x benefits
        tierConfigs[Tier.Silver]  = TierConfig(12000, 0, 0.05 ether, 100, false);
        tierConfigs[Tier.Gold]    = TierConfig(8000,  0, 0.05 ether, 200, false);
        tierConfigs[Tier.Diamond] = TierConfig(2100,  0, 0.05 ether, 500, false);
    }

    // ============================================================
    //                      MINT FUNCTIONS
    // ============================================================
    
    /**
     * @notice Owner mint specific tier NFT
     * @param to Recipient address
     * @param tier Tier
     * @return tokenId Minted tokenId
     */
    function mint(address to, Tier tier) external onlyOwner returns (uint256 tokenId) {
        tokenId = _mintWithTier(to, tier);
    }
    
    /**
     * @notice Owner mint and set URI
     * @param to Recipient address
     * @param tier Tier
     * @param uri Token URI
     * @return tokenId Minted tokenId
     */
    function mintWithURI(address to, Tier tier, string calldata uri) external onlyOwner returns (uint256 tokenId) {
        tokenId = _mintWithTier(to, tier);
        _setTokenURI(tokenId, uri);
    }
    
    /**
     * @notice Owner batch mint same tier NFTs and set URI
     * @param to Recipient address
     * @param tier Tier
     * @param amount Mint amount
     * @param uri Shared URI for all tokens
     * @return startTokenId Starting tokenId
     */
    function batchMintWithURI(address to, Tier tier, uint256 amount, string calldata uri) external onlyOwner returns (uint256 startTokenId) {
        if (amount == 0 || amount > 1000) revert ErrInvalidAmount();  // Limit 1000 with URI to avoid high gas costs
        if (to == address(0)) revert ErrZeroAddress();
        _validateTier(tier);
        
        TierConfig storage config = tierConfigs[tier];
        if (config.maxSupply != 0 && config.minted + amount > config.maxSupply) {
            revert ErrTierMaxSupplyReached();
        }
        
        startTokenId = _nextTokenId;
        
        unchecked {
            config.minted += uint64(amount);
            for (uint256 i; i < amount; ++i) {
                uint256 tokenId = _nextTokenId++;
                _tokenTier[tokenId] = tier;
                _safeMint(to, tokenId);
                _setTokenURI(tokenId, uri);
            }
        }
        
        emit BatchMinted(to, startTokenId, amount, tier);
    }
    
    /**
     * @notice Public mint specific tier
     * @param tier Tier
     * @return tokenId Minted tokenId
     */
    function publicMint(Tier tier) external payable nonReentrant returns (uint256 tokenId) {
        _validateTier(tier);
        
        TierConfig storage config = tierConfigs[tier];
        if (!config.publicMintEnabled) revert ErrPublicMintDisabled();
        if (msg.value < config.mintPrice) revert ErrInsufficientPayment();
        
        tokenId = _mintWithTier(msg.sender, tier);
    }

    // ============================================================
    //                      BURN FUNCTIONS
    // ============================================================
    
    /**
     * @notice Burn NFT (token owner only)
     * @param tokenId TokenId to burn
     */
    function burn(uint256 tokenId) external {
        if (ownerOf(tokenId) != msg.sender) revert ErrNotTokenOwner();
        
        Tier tier = _tokenTier[tokenId];
        if (tier != Tier.None) {
            unchecked {
                tierConfigs[tier].minted--;
            }
        }
        
        delete _tokenTier[tokenId];
        _burn(tokenId);
    }

    // ============================================================
    //                     ADMIN FUNCTIONS
    // ============================================================
    
    /**
     * @notice Set tier configuration
     * @param tier Tier
     * @param maxSupply Max supply
     * @param mintPrice Mint price
     * @param benefitMultiplier Benefit multiplier
     */
    function setTierConfig(
        Tier tier,
        uint64 maxSupply,
        uint128 mintPrice,
        uint16 benefitMultiplier
    ) external onlyOwner {
        _validateTier(tier);
        
        TierConfig storage config = tierConfigs[tier];
        config.maxSupply = maxSupply;
        config.mintPrice = mintPrice;
        config.benefitMultiplier = benefitMultiplier;
        
        emit TierConfigUpdated(tier, maxSupply, mintPrice, benefitMultiplier);
    }
    
    /**
     * @notice Enable/disable public minting for specific tier
     * @param tier Tier
     * @param enabled Whether to enable
     */
    function setTierPublicMint(Tier tier, bool enabled) external onlyOwner {
        _validateTier(tier);
        tierConfigs[tier].publicMintEnabled = enabled;
        emit TierPublicMintToggled(tier, enabled);
    }
    
    /**
     * @notice Set base URI
     * @param baseURI_ New base URI
     */
    function setBaseURI(string calldata baseURI_) external onlyOwner {
        _baseTokenURI = baseURI_;
        emit BaseURIUpdated(baseURI_);
    }
    
    /**
     * @notice Set individual token URI
     * @param tokenId Token ID
     * @param uri New URI
     */
    function setTokenURI(uint256 tokenId, string calldata uri) external onlyOwner {
        _setTokenURI(tokenId, uri);
    }
    
    /**
     * @notice Withdraw contract balance
     * @param to Recipient address
     */
    function withdraw(address to) external onlyOwner {
        if (to == address(0)) revert ErrZeroAddress();

        payable(to).transfer(address(this).balance);  // Use transfer for security with fixed gas stipend
    }

    // ============================================================
    //                     VIEW FUNCTIONS
    // ============================================================
    
    /**
     * @notice Get token tier
     * @param tokenId Token ID
     * @return Tier
     */
    function getTier(uint256 tokenId) external view returns (Tier) {
        return _tokenTier[tokenId];
    }
    
    /**
     * @notice Get token benefit multiplier
     * @param tokenId Token ID
     * @return Benefit multiplier (100 = 1x)
     */
    function getBenefitMultiplier(uint256 tokenId) external view returns (uint16) {
        Tier tier = _tokenTier[tokenId];
        if (tier == Tier.None) return 0;
        return tierConfigs[tier].benefitMultiplier;
    }
    
    /**
     * @notice Get user's highest tier
     * @param user User address
     * @return highestTier Highest tier
     */
    function getUserHighestTier(address user) external view returns (Tier highestTier) {
        uint256 balance = balanceOf(user);
        
        for (uint256 i; i < balance;) {
            uint256 tokenId = tokenOfOwnerByIndex(user, i);
            Tier tier = _tokenTier[tokenId];
            if (tier > highestTier) {
                highestTier = tier;
                if (highestTier == Tier.Diamond) break;
            }
            unchecked { ++i; }
        }
    }
    
    /**
     * @notice Get user's benefit multiplier (highest)
     * @param user User address
     * @return Benefit multiplier (100 = 1x)
     */
    function getUserBenefitMultiplier(address user) external view returns (uint16) {
        uint256 balance = balanceOf(user);
        if (balance == 0) return 0;
        
        Tier highestTier;
        for (uint256 i; i < balance;) {
            uint256 tokenId = tokenOfOwnerByIndex(user, i);
            Tier tier = _tokenTier[tokenId];
            if (tier > highestTier) {
                highestTier = tier;
                if (highestTier == Tier.Diamond) break;
            }
            unchecked { ++i; }
        }
        
        return tierConfigs[highestTier].benefitMultiplier;
    }
    
    /**
     * @notice Check if user has minimum tier
     * @param user User address
     * @param requiredTier Required tier
     * @return Whether user has the tier
     */
    function hasMinTier(address user, Tier requiredTier) external view returns (bool) {
        uint256 balance = balanceOf(user);
        
        for (uint256 i; i < balance;) {
            if (_tokenTier[tokenOfOwnerByIndex(user, i)] >= requiredTier) {
                return true;
            }
            unchecked { ++i; }
        }
        return false;
    }
    
    /**
     * @notice Get tier statistics
     * @param tier Tier
     * @return maxSupply Max supply
     * @return minted Number minted
     * @return remaining Remaining to mint
     */
    function getTierStats(Tier tier) external view returns (
        uint64 maxSupply,
        uint64 minted,
        uint64 remaining
    ) {
        TierConfig storage config = tierConfigs[tier];
        maxSupply = config.maxSupply;
        minted = config.minted;
        remaining = maxSupply == 0 ? type(uint64).max : maxSupply - minted;
    }
    


    // ============================================================
    //                   INTERNAL FUNCTIONS
    // ============================================================
    
    function _mintWithTier(address to, Tier tier) internal returns (uint256 tokenId) {
        if (to == address(0)) revert ErrZeroAddress();
        _validateTier(tier);
        
        TierConfig storage config = tierConfigs[tier];
        if (config.maxSupply != 0 && config.minted >= config.maxSupply) {
            revert ErrTierMaxSupplyReached();
        }
        
        tokenId = _nextTokenId;
        
        unchecked {
            ++_nextTokenId;
            ++config.minted;
        }
        
        _tokenTier[tokenId] = tier;
        _safeMint(to, tokenId);
        
        emit Minted(to, tokenId, tier);
    }
    
    function _validateTier(Tier tier) internal pure {
        if (tier == Tier.None || tier > Tier.Diamond) revert ErrInvalidTier();
    }

    // ============================================================
    //                      OVERRIDES
    // ============================================================
    
    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }
    
    function tokenURI(uint256 tokenId) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }
    
    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC721Enumerable, ERC721URIStorage) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
    
    function _update(address to, uint256 tokenId, address auth) internal override(ERC721, ERC721Enumerable) returns (address) {
        return super._update(to, tokenId, auth);
    }
    
    function _increaseBalance(address account, uint128 value) internal override(ERC721, ERC721Enumerable) {
        super._increaseBalance(account, value);
    }
}
