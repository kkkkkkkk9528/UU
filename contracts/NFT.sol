// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title NFT
 * @notice 分等级 ERC721 NFT 合约，支持收藏品稀有度 + 会员权益
 * @dev 
 * 等级体系: Silver(1) → Gold(2) → Diamond(3)
 * 每个等级有独立铸造价格、供应上限、权益倍数
 */
contract NFT is ERC721, ERC721Enumerable, ERC721URIStorage, Ownable2Step, ReentrancyGuard {
    
    // ============================================================
    //                         ENUMS
    // ============================================================
    
    /// @notice NFT 等级
    enum Tier {
        None,       // 0 - 无效
        Silver,     // 1 - 白银
        Gold,       // 2 - 黄金
        Diamond     // 3 - 钻石
    }

    // ============================================================
    //                        STRUCTS
    // ============================================================
    
    /// @notice 等级配置
    struct TierConfig {
        uint64 maxSupply;         // 该等级最大供应量（0 = 无限制）
        uint64 minted;            // 该等级已铸造数量
        uint128 mintPrice;        // 铸造价格
        uint16 benefitMultiplier; // 权益倍数 (100 = 1x, 200 = 2x)
        bool publicMintEnabled;   // 是否开放公开铸造
    }

    // ============================================================
    //                        STORAGE
    // ============================================================
    
    /// @notice 下一个 tokenId（从 1 开始）
    uint256 private _nextTokenId;
    
    /// @notice 基础 URI
    string private _baseTokenURI;
    
    /// @notice tokenId => 等级
    mapping(uint256 => Tier) private _tokenTier;
    
    /// @notice 等级 => 配置
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
     * @param name_ NFT 名称
     * @param symbol_ NFT 符号
     * @param owner_ 合约所有者
     * @param baseURI_ 基础 URI
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
        
        // 默认等级配置 (总量 21000)
        // Silver: 12000, 1x 权益
        // Gold:   8000, 2x 权益
        // Diamond: 2100, 5x 权益
        tierConfigs[Tier.Silver]  = TierConfig(12000, 0, 0.05 ether, 100, false);
        tierConfigs[Tier.Gold]    = TierConfig(8000,  0, 0.05 ether, 200, false);
        tierConfigs[Tier.Diamond] = TierConfig(2100,  0, 0.05 ether, 500, false);
    }

    // ============================================================
    //                      MINT FUNCTIONS
    // ============================================================
    
    /**
     * @notice Owner 铸造指定等级 NFT
     * @param to 接收地址
     * @param tier 等级
     * @return tokenId 铸造的 tokenId
     */
    function mint(address to, Tier tier) external onlyOwner returns (uint256 tokenId) {
        tokenId = _mintWithTier(to, tier);
    }
    
    /**
     * @notice Owner 铸造并设置 URI
     * @param to 接收地址
     * @param tier 等级
     * @param uri Token URI
     * @return tokenId 铸造的 tokenId
     */
    function mintWithURI(address to, Tier tier, string calldata uri) external onlyOwner returns (uint256 tokenId) {
        tokenId = _mintWithTier(to, tier);
        _setTokenURI(tokenId, uri);
    }
    
    /**
     * @notice Owner 批量铸造同等级 NFT 并设置 URI
     * @param to 接收地址
     * @param tier 等级
     * @param amount 铸造数量
     * @param uri 所有 token 共用的 URI
     * @return startTokenId 起始 tokenId
     */
    function batchMintWithURI(address to, Tier tier, uint256 amount, string calldata uri) external onlyOwner returns (uint256 startTokenId) {
        if (amount == 0 || amount > 1000) revert ErrInvalidAmount();  // 带 URI 限制 1000，避免 gas 过高
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
     * @notice 公开铸造指定等级
     * @param tier 等级
     * @return tokenId 铸造的 tokenId
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
     * @notice 销毁 NFT（仅 token 持有者）
     * @param tokenId 要销毁的 tokenId
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
     * @notice 设置等级配置
     * @param tier 等级
     * @param maxSupply 最大供应量
     * @param mintPrice 铸造价格
     * @param benefitMultiplier 权益倍数
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
     * @notice 开启/关闭指定等级的公开铸造
     * @param tier 等级
     * @param enabled 是否开启
     */
    function setTierPublicMint(Tier tier, bool enabled) external onlyOwner {
        _validateTier(tier);
        tierConfigs[tier].publicMintEnabled = enabled;
        emit TierPublicMintToggled(tier, enabled);
    }
    
    /**
     * @notice 设置基础 URI
     * @param baseURI_ 新的基础 URI
     */
    function setBaseURI(string calldata baseURI_) external onlyOwner {
        _baseTokenURI = baseURI_;
        emit BaseURIUpdated(baseURI_);
    }
    
    /**
     * @notice 设置单个 token 的 URI
     * @param tokenId Token ID
     * @param uri 新的 URI
     */
    function setTokenURI(uint256 tokenId, string calldata uri) external onlyOwner {
        _setTokenURI(tokenId, uri);
    }
    
    /**
     * @notice 提取合约余额
     * @param to 接收地址
     */
    function withdraw(address to) external onlyOwner {
        if (to == address(0)) revert ErrZeroAddress();

        payable(to).transfer(address(this).balance);  // 使用 transfer，更安全，有固定 gas 限制
    }

    // ============================================================
    //                     VIEW FUNCTIONS
    // ============================================================
    
    /**
     * @notice 获取 token 等级
     * @param tokenId Token ID
     * @return 等级
     */
    function getTier(uint256 tokenId) external view returns (Tier) {
        return _tokenTier[tokenId];
    }
    
    /**
     * @notice 获取 token 权益倍数
     * @param tokenId Token ID
     * @return 权益倍数 (100 = 1x)
     */
    function getBenefitMultiplier(uint256 tokenId) external view returns (uint16) {
        Tier tier = _tokenTier[tokenId];
        if (tier == Tier.None) return 0;
        return tierConfigs[tier].benefitMultiplier;
    }
    
    /**
     * @notice 获取用户最高等级
     * @param user 用户地址
     * @return highestTier 最高等级
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
     * @notice 获取用户权益倍数（取最高）
     * @param user 用户地址
     * @return 权益倍数 (100 = 1x)
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
     * @notice 检查用户是否达到指定等级
     * @param user 用户地址
     * @param requiredTier 要求的等级
     * @return 是否达到
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
     * @notice 获取等级统计信息
     * @param tier 等级
     * @return maxSupply 最大供应量
     * @return minted 已铸造数量
     * @return remaining 剩余可铸造数量
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
