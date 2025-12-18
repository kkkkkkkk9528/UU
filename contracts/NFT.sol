// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";

/**
 * @title NFT(塞翁马版)
 * @notice 支持多种铸造方式、等级系统和版税的 NFT 合约
 * @dev 实现 ERC721、ERC721Enumerable、ERC2981 标准
 * 
 * 核心功能：
 * 1. 三种等级系统（Common、Rare、Epic）
 * 2. 六种铸造方式（所有者免费、ETH支付、ERC20支付，各支持单个和批量）
 * 3. 五维角色属性系统（攻击、防御、速度、生命、魔法）
 * 4. EIP-2981 版税标准
 * 5. 完整的安全机制（重入保护、暂停机制、权限控制）
 */
contract NFT is 
    ERC721, 
    ERC721Enumerable, 
    ERC721URIStorage, 
    Ownable, 
    ReentrancyGuard, 
    Pausable,
    IERC2981 
{
    using SafeERC20 for IERC20;

    // ============ 类型定义 ============

    /**
     * @notice NFT 等级枚举
     * @dev 三个等级，每个等级有不同的价格和属性范围
     */
    enum Level {
        Common,  // 普通：属性范围 25-35
        Rare,    // 稀有：属性范围 30-40
        Epic     // 史诗：属性范围 35-45
    }

    /**
     * @notice 角色属性结构
     * @dev 五维属性系统，基于等级和随机性生成
     */
    struct Character {
        uint8 attack;    // 攻击力
        uint8 defense;   // 防御力
        uint8 speed;     // 速度
        uint8 health;    // 生命值
        uint8 magic;     // 魔法值
        Level level;     // 等级
    }

    /**
     * @notice 版税信息结构
     * @dev 符合 EIP-2981 标准
     */
    struct RoyaltyInfo {
        address receiver;  // 版税接收者
        uint96 royaltyFraction;  // 版税比例（基点，10000 = 100%）
    }

    // ============ 状态变量 ============

    /// @notice 下一个要铸造的代币 ID
    uint256 private _nextTokenId;

    /// @notice 最大供应量（0 表示无限制）
    uint256 public maxSupply;

    /// @notice 各等级的铸造价格（ETH）
    mapping(Level => uint256) public levelPrices;

    /// @notice 接受的 ERC20 代币及其价格
    mapping(address => mapping(Level => uint256)) public tokenPrices;

    /// @notice 代币 ID 到角色属性的映射
    mapping(uint256 => Character) public characters;

    /// @notice 默认版税信息
    RoyaltyInfo private _defaultRoyaltyInfo;

    /// @notice 单个代币的自定义版税信息
    mapping(uint256 => RoyaltyInfo) private _tokenRoyaltyInfo;

    /// @notice 版税分母（10000 = 100%）
    uint96 private constant _ROYALTY_DENOMINATOR = 10000;

    /// @notice 黑名单 NFT 映射（被拉黑的 tokenId 无法转账）
    mapping(uint256 => bool) public blacklistedTokens;

    // ============ 事件 ============

    /// @notice 铸造事件
    event Minted(
        address indexed to,
        uint256 indexed tokenId,
        Level level,
        uint8 attack,
        uint8 defense,
        uint8 speed,
        uint8 health,
        uint8 magic
    );

    /// @notice 等级价格更新事件
    event LevelPriceUpdated(Level indexed level, uint256 price);

    /// @notice ERC20 代币价格更新事件
    event TokenPriceUpdated(address indexed token, Level indexed level, uint256 price);

    /// @notice 最大供应量更新事件
    event MaxSupplyUpdated(uint256 maxSupply);

    /// @notice 提取 ETH 事件
    event Withdrawn(address indexed to, uint256 amount);

    /// @notice 提取 ERC20 事件
    event TokenWithdrawn(address indexed token, address indexed to, uint256 amount);

    /// @notice NFT 加入黑名单事件
    event TokenBlacklisted(uint256 indexed tokenId);

    /// @notice NFT 移出黑名单事件
    event TokenUnblacklisted(uint256 indexed tokenId);

    // ============ 构造函数 ============

    /**
     * @notice 构造函数
     * @param name NFT 名称
     * @param symbol NFT 符号
     * @param initialMaxSupply 最大供应量（0 表示无限制）
     * @param defaultRoyaltyReceiver 默认版税接收者
     * @param defaultRoyaltyFraction 默认版税比例（基点）
     */
    constructor(
        string memory name,
        string memory symbol,
        uint256 initialMaxSupply,
        address defaultRoyaltyReceiver,
        uint96 defaultRoyaltyFraction
    ) ERC721(name, symbol) Ownable(msg.sender) {
        require(defaultRoyaltyFraction <= _ROYALTY_DENOMINATOR, "Royalty too high");
        require(defaultRoyaltyReceiver != address(0), "Invalid receiver");
        
        maxSupply = initialMaxSupply;
        _defaultRoyaltyInfo.receiver = defaultRoyaltyReceiver;
        _defaultRoyaltyInfo.royaltyFraction = defaultRoyaltyFraction;
    }

    // ============ 铸造函数 ============

    /**
     * @notice 所有者免费单个铸造
     * @dev 只有合约所有者可以调用，不收取费用
     * @param to 接收者地址
     * @param level NFT 等级
     * @param uri 代币 URI
     */
    function ownerMint(
        address to,
        Level level,
        string memory uri
    ) external onlyOwner whenNotPaused {
        _mintInternal(to, level, uri);
    }

    /**
     * @notice 所有者免费批量铸造
     * @dev 只有合约所有者可以调用，不收取费用
     * @param to 接收者地址
     * @param levels NFT 等级数组
     * @param uris 代币 URI 数组
     */
    function ownerBatchMint(
        address to,
        Level[] calldata levels,
        string[] calldata uris
    ) external onlyOwner whenNotPaused {
        uint256 length = levels.length;
        require(length == uris.length, "Length mismatch");
        require(length != 0, "Empty array");

        unchecked {
            for (uint256 i = 0; i < length; ++i) {
                _mintInternal(to, levels[i], uris[i]);
            }
        }
    }

    /**
     * @notice ETH 支付单个铸造
     * @dev 用户支付 ETH 铸造 NFT，必须精确支付
     * @param level NFT 等级
     * @param uri 代币 URI
     */
    function mint(
        Level level,
        string memory uri
    ) external payable nonReentrant whenNotPaused {
        uint256 price = levelPrices[level];
        require(msg.value == price, "Incorrect payment");

        _mintInternal(msg.sender, level, uri);
    }

    /**
     * @notice ETH 支付批量铸造
     * @dev 用户支付 ETH 批量铸造 NFT，每个等级使用对应价格，必须精确支付
     * @param levels NFT 等级数组
     * @param uris 代币 URI 数组
     */
    function mintBatch(
        Level[] calldata levels,
        string[] calldata uris
    ) external payable nonReentrant whenNotPaused {
        uint256 length = levels.length;
        require(length == uris.length, "Length mismatch");
        require(length != 0, "Empty array");

        // 计算总价格
        uint256 totalPrice;
        unchecked {
            for (uint256 i = 0; i < length; ++i) {
                totalPrice += levelPrices[levels[i]];
            }
        }

        require(msg.value == totalPrice, "Incorrect payment");

        // 批量铸造
        unchecked {
            for (uint256 i = 0; i < length; ++i) {
                _mintInternal(msg.sender, levels[i], uris[i]);
            }
        }
    }

    /**
     * @notice ERC20 支付单个铸造
     * @dev 用户支付 ERC20 代币铸造 NFT
     * @param token ERC20 代币地址
     * @param level NFT 等级
     * @param uri 代币 URI
     */
    function mintWithToken(
        address token,
        Level level,
        string memory uri
    ) external nonReentrant whenNotPaused {
        uint256 price = tokenPrices[token][level];
        require(price != 0, "Token not accepted");

        IERC20(token).safeTransferFrom(msg.sender, address(this), price);
        _mintInternal(msg.sender, level, uri);
    }

    /**
     * @notice ERC20 支付批量铸造
     * @dev 用户支付 ERC20 代币批量铸造 NFT，每个等级使用对应价格
     * @param token ERC20 代币地址
     * @param levels NFT 等级数组
     * @param uris 代币 URI 数组
     */
    function mintBatchWithToken(
        address token,
        Level[] calldata levels,
        string[] calldata uris
    ) external nonReentrant whenNotPaused {
        uint256 length = levels.length;
        require(length == uris.length, "Length mismatch");
        require(length != 0, "Empty array");

        // 计算总价格
        uint256 totalPrice;
        unchecked {
            for (uint256 i = 0; i < length; ++i) {
                uint256 price = tokenPrices[token][levels[i]];
                require(price != 0, "Token not accepted for level");
                totalPrice += price;
            }
        }

        IERC20(token).safeTransferFrom(msg.sender, address(this), totalPrice);

        // 批量铸造
        unchecked {
            for (uint256 i = 0; i < length; ++i) {
                _mintInternal(msg.sender, levels[i], uris[i]);
            }
        }
    }

    // ============ 内部铸造逻辑 ============

    /**
     * @notice 内部铸造函数
     * @dev 执行实际的铸造逻辑，生成随机属性
     * 
     * 算法步骤：
     * 1. 检查供应量限制
     * 2. 生成随机属性（基于区块哈希和代币ID）
     * 3. 铸造 NFT
     * 4. 设置 URI
     * 5. 存储角色属性
     * 6. 触发事件
     * 
     * 边界条件：
     * - 检查最大供应量
     * - 确保接收者地址有效
     * - 属性值在合理范围内
     * 
     * @param to 接收者地址
     * @param level NFT 等级
     * @param uri 代币 URI
     */
    function _mintInternal(
        address to,
        Level level,
        string memory uri
    ) private {
        require(to != address(0), "Invalid address");
        
        // 检查供应量限制
        if (maxSupply != 0) {
            require(_nextTokenId < maxSupply, "Max supply reached");
        }

        uint256 tokenId = _nextTokenId;
        unchecked {
            ++_nextTokenId;
        }

        // 生成并存储随机属性
        characters[tokenId] = _generateCharacter(tokenId, level);

        // 铸造 NFT
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, uri);

        Character storage character = characters[tokenId];
        emit Minted(
            to,
            tokenId,
            level,
            character.attack,
            character.defense,
            character.speed,
            character.health,
            character.magic
        );
    }

    /**
     * @notice 生成角色属性
     * @dev 基于区块随机性和代币ID生成属性
     * 
     * 随机性来源：
     * - blockhash(block.number - 1)：前一个区块的哈希
     * - tokenId：当前代币ID
     * - block.timestamp：当前时间戳
     * 
     * 注意：这种随机性可以被预测，但对于游戏属性来说是可接受的
     * 
     * 属性范围：
     * - Common: 25-35
     * - Rare: 30-40
     * - Epic: 35-45
     * 
     * @param tokenId 代币 ID
     * @param level NFT 等级
     * @return character 生成的角色属性
     */
    function _generateCharacter(
        uint256 tokenId,
        Level level
    ) private view returns (Character memory) {
        // 生成随机种子
        bytes32 seed = keccak256(
            abi.encodePacked(
                blockhash(block.number - 1),
                tokenId,
                block.timestamp
            )
        );

        // 根据等级确定属性范围
        (uint256 minStat, uint256 range) = _getStatRange(level);

        // 使用单个随机值通过位移生成所有属性，节省 gas
        uint256 randomValue = uint256(seed);

        // 生成五维属性（每个属性使用不同的位段）
        return Character({
            attack: uint8(minStat + ((randomValue >> 0) % range)),
            defense: uint8(minStat + ((randomValue >> 51) % range)),
            speed: uint8(minStat + ((randomValue >> 102) % range)),
            health: uint8(minStat + ((randomValue >> 153) % range)),
            magic: uint8(minStat + ((randomValue >> 204) % range)),
            level: level
        });
    }

    /**
     * @notice 根据等级获取属性范围
     * @param level NFT 等级
     * @return minStat 最小属性值
     * @return range 属性范围
     */
    function _getStatRange(Level level) private pure returns (uint256 minStat, uint256 range) {
        // 使用数学公式：Common(0):25, Rare(1):30, Epic(2):35
        minStat = 25 + uint256(level) * 5;
        range = 11; // 所有等级范围都是 11 (0-10)
    }

    // ============ 管理函数 ============

    /**
     * @notice 设置单个等级价格
     * @param level 等级
     * @param price 价格（ETH）
     */
    function setLevelPrice(Level level, uint256 price) external onlyOwner {
        _updateLevelPrice(level, price);
    }

    /**
     * @notice 批量设置等级价格
     * @param prices 价格数组 [Common, Rare, Epic]
     */
    function setLevelPrices(uint256[3] calldata prices) external onlyOwner {
        _updateLevelPrice(Level.Common, prices[0]);
        _updateLevelPrice(Level.Rare, prices[1]);
        _updateLevelPrice(Level.Epic, prices[2]);
    }

    /**
     * @notice 内部函数：更新等级价格
     * @param level 等级
     * @param price 新价格
     */
    function _updateLevelPrice(Level level, uint256 price) private {
        if (levelPrices[level] != price) {
            levelPrices[level] = price;
            emit LevelPriceUpdated(level, price);
        }
    }

    /**
     * @notice 设置 ERC20 代币价格
     * @param token ERC20 代币地址
     * @param level 等级
     * @param price 价格
     */
    function setTokenPrice(
        address token,
        Level level,
        uint256 price
    ) external onlyOwner {
        require(token != address(0), "Invalid token");
        _updateTokenPrice(token, level, price);
    }

    /**
     * @notice 批量设置 ERC20 代币价格
     * @param token ERC20 代币地址
     * @param prices 价格数组 [Common, Rare, Epic]
     */
    function setTokenPrices(
        address token,
        uint256[3] calldata prices
    ) external onlyOwner {
        require(token != address(0), "Invalid token");
        
        _updateTokenPrice(token, Level.Common, prices[0]);
        _updateTokenPrice(token, Level.Rare, prices[1]);
        _updateTokenPrice(token, Level.Epic, prices[2]);
    }

    /**
     * @notice 内部函数：更新代币价格
     * @param token 代币地址
     * @param level 等级
     * @param price 新价格
     */
    function _updateTokenPrice(address token, Level level, uint256 price) private {
        if (tokenPrices[token][level] != price) {
            tokenPrices[token][level] = price;
            emit TokenPriceUpdated(token, level, price);
        }
    }

    /**
     * @notice 设置最大供应量
     * @param newMaxSupply 最大供应量（0 表示无限制）
     */
    function setMaxSupply(uint256 newMaxSupply) external onlyOwner {
        require(newMaxSupply == 0 || newMaxSupply >= _nextTokenId, "Invalid max supply");
        if (maxSupply == newMaxSupply) return;
        maxSupply = newMaxSupply;
        emit MaxSupplyUpdated(newMaxSupply);
    }

    /**
     * @notice 设置默认版税
     * @param receiver 版税接收者
     * @param feeNumerator 版税比例（基点，10000 = 100%）
     */
    function setDefaultRoyalty(
        address receiver,
        uint96 feeNumerator
    ) external onlyOwner {
        require(feeNumerator <= _ROYALTY_DENOMINATOR, "Royalty too high");
        require(receiver != address(0), "Invalid receiver");
        _defaultRoyaltyInfo.receiver = receiver;
        _defaultRoyaltyInfo.royaltyFraction = feeNumerator;
    }

    /**
     * @notice 设置单个 NFT 版税
     * @param tokenId 代币 ID
     * @param receiver 版税接收者
     * @param feeNumerator 版税比例（基点）
     */
    function setTokenRoyalty(
        uint256 tokenId,
        address receiver,
        uint96 feeNumerator
    ) external onlyOwner {
        require(feeNumerator <= _ROYALTY_DENOMINATOR, "Royalty too high");
        require(receiver != address(0), "Invalid receiver");
        require(_ownerOf(tokenId) != address(0), "Token does not exist");
        _tokenRoyaltyInfo[tokenId].receiver = receiver;
        _tokenRoyaltyInfo[tokenId].royaltyFraction = feeNumerator;
    }

    /**
     * @notice 重置 NFT 版税（使用默认版税）
     * @param tokenId 代币 ID
     */
    function resetTokenRoyalty(uint256 tokenId) external onlyOwner {
        require(_ownerOf(tokenId) != address(0), "Token does not exist");
        delete _tokenRoyaltyInfo[tokenId];
    }

    /**
     * @notice 提取 ETH
     * @param to 接收者地址
     */
    function withdraw(address payable to) external nonReentrant onlyOwner {
        require(to != address(0), "Invalid address");
        uint256 balance = address(this).balance;
        require(balance != 0, "No balance");

        (bool success, ) = to.call{value: balance}("");
        require(success, "Withdraw failed");

        emit Withdrawn(to, balance);
    }

    /**
     * @notice 提取 ERC20 代币
     * @param token ERC20 代币地址
     * @param to 接收者地址
     */
    function withdrawToken(
        address token,
        address to
    ) external nonReentrant onlyOwner {
        require(token != address(0), "Invalid token");
        require(to != address(0), "Invalid address");

        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance != 0, "No balance");

        IERC20(token).safeTransfer(to, balance);

        emit TokenWithdrawn(token, to, balance);
    }

    /**
     * @notice 暂停合约
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice 恢复合约
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice 将 NFT 加入黑名单
     * @dev 只有合约所有者可以调用，被拉黑的 NFT 无法转账
     * @param tokenId 要加入黑名单的 NFT ID
     */
    function blacklistToken(uint256 tokenId) external onlyOwner {
        require(_ownerOf(tokenId) != address(0), "Token does not exist");
        if (!blacklistedTokens[tokenId]) {
            blacklistedTokens[tokenId] = true;
            emit TokenBlacklisted(tokenId);
        }
    }

    /**
     * @notice 将 NFT 移出黑名单
     * @dev 只有合约所有者可以调用
     * @param tokenId 要移出黑名单的 NFT ID
     */
    function unblacklistToken(uint256 tokenId) external onlyOwner {
        require(_ownerOf(tokenId) != address(0), "Token does not exist");
        if (blacklistedTokens[tokenId]) {
            blacklistedTokens[tokenId] = false;
            emit TokenUnblacklisted(tokenId);
        }
    }

    /**
     * @notice 批量将 NFT 加入黑名单
     * @dev 只有合约所有者可以调用
     * @param tokenIds 要加入黑名单的 NFT ID 数组
     * @return successCount 成功加入黑名单的数量
     */
    function batchBlacklistTokens(uint256[] calldata tokenIds) external onlyOwner returns (uint256 successCount) {
        uint256 length = tokenIds.length;
        require(length != 0, "Empty array");
        
        unchecked {
            for (uint256 i = 0; i < length; ++i) {
                uint256 tokenId = tokenIds[i];
                if (_ownerOf(tokenId) != address(0) && !blacklistedTokens[tokenId]) {
                    blacklistedTokens[tokenId] = true;
                    emit TokenBlacklisted(tokenId);
                    ++successCount;
                }
            }
        }
    }

    /**
     * @notice 批量将 NFT 移出黑名单
     * @dev 只有合约所有者可以调用
     * @param tokenIds 要移出黑名单的 NFT ID 数组
     * @return successCount 成功移出黑名单的数量
     */
    function batchUnblacklistTokens(uint256[] calldata tokenIds) external onlyOwner returns (uint256 successCount) {
        uint256 length = tokenIds.length;
        require(length != 0, "Empty array");
        
        unchecked {
            for (uint256 i = 0; i < length; ++i) {
                uint256 tokenId = tokenIds[i];
                if (_ownerOf(tokenId) != address(0) && blacklistedTokens[tokenId]) {
                    blacklistedTokens[tokenId] = false;
                    emit TokenUnblacklisted(tokenId);
                    ++successCount;
                }
            }
        }
    }

    /**
     * @notice 检查 NFT 是否在黑名单中
     * @param tokenId 要检查的 NFT ID
     * @return 是否在黑名单中
     */
    function isTokenBlacklisted(uint256 tokenId) external view returns (bool) {
        return blacklistedTokens[tokenId];
    }

    /**
     * @notice 批量检查 NFT 是否在黑名单中
     * @param tokenIds NFT ID 数组
     * @return statuses 黑名单状态数组
     */
    function batchIsTokenBlacklisted(uint256[] calldata tokenIds) external view returns (bool[] memory statuses) {
        uint256 length = tokenIds.length;
        statuses = new bool[](length);
        
        unchecked {
            for (uint256 i = 0; i < length; ++i) {
                statuses[i] = blacklistedTokens[tokenIds[i]];
            }
        }
    }

    // ============ 查询函数 ============

    /**
     * @notice 获取下一个代币 ID
     */
    function nextTokenId() external view returns (uint256) {
        return _nextTokenId;
    }

    /**
     * @notice 检查 NFT 是否存在
     */
    function exists(uint256 tokenId) external view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    /**
     * @notice 获取用户拥有的所有 NFT
     * @param owner 用户地址
     * @return tokenIds 代币 ID 数组
     */
    function tokensOfOwner(address owner) external view returns (uint256[] memory) {
        uint256 balance = balanceOf(owner);
        uint256[] memory tokenIds = new uint256[](balance);
        
        unchecked {
            for (uint256 i = 0; i < balance; ++i) {
                tokenIds[i] = tokenOfOwnerByIndex(owner, i);
            }
        }
        
        return tokenIds;
    }

    /**
     * @notice 批量获取 URI
     * @param tokenIds 代币 ID 数组
     * @return uris URI 数组
     */
    function batchTokenURI(
        uint256[] calldata tokenIds
    ) external view returns (string[] memory uris) {
        uint256 length = tokenIds.length;
        uris = new string[](length);
        
        unchecked {
            for (uint256 i = 0; i < length; ++i) {
                uris[i] = tokenURI(tokenIds[i]);
            }
        }
    }

    /**
     * @notice 批量获取角色属性
     * @param tokenIds 代币 ID 数组
     * @return chars 角色属性数组
     */
    function batchGetCharacters(
        uint256[] calldata tokenIds
    ) external view returns (Character[] memory chars) {
        uint256 length = tokenIds.length;
        chars = new Character[](length);
        
        unchecked {
            for (uint256 i = 0; i < length; ++i) {
                chars[i] = characters[tokenIds[i]];
            }
        }
    }

    /**
     * @notice 获取合约配置
     * @return nextTokenId_ 下一个代币 ID
     * @return maxSupply_ 最大供应量
     * @return totalSupply_ 当前总供应量
     * @return commonPrice Common 等级价格
     * @return rarePrice Rare 等级价格
     * @return epicPrice Epic 等级价格
     */
    function getConfig() external view returns (
        uint256 nextTokenId_,
        uint256 maxSupply_,
        uint256 totalSupply_,
        uint256 commonPrice,
        uint256 rarePrice,
        uint256 epicPrice
    ) {
        nextTokenId_ = _nextTokenId;
        maxSupply_ = maxSupply;
        totalSupply_ = totalSupply();
        commonPrice = levelPrices[Level.Common];
        rarePrice = levelPrices[Level.Rare];
        epicPrice = levelPrices[Level.Epic];
    }

    /**
     * @notice 获取等级价格
     * @return prices 价格数组 [Common, Rare, Epic]
     */
    function getLevelPrices() external view returns (uint256[3] memory) {
        return [
            levelPrices[Level.Common],
            levelPrices[Level.Rare],
            levelPrices[Level.Epic]
        ];
    }

    /**
     * @notice 查询版税信息（EIP-2981）
     * @param tokenId 代币 ID
     * @param salePrice 销售价格
     * @return receiver 版税接收者
     * @return royaltyAmount 版税金额
     */
    function royaltyInfo(
        uint256 tokenId,
        uint256 salePrice
    ) external view override returns (address receiver, uint256 royaltyAmount) {
        RoyaltyInfo memory royalty = _tokenRoyaltyInfo[tokenId];

        if (royalty.receiver == address(0)) {
            royalty = _defaultRoyaltyInfo;
        }

        royaltyAmount = (salePrice * royalty.royaltyFraction) / _ROYALTY_DENOMINATOR;
        receiver = royalty.receiver;
    }

    // ============ 重写函数 ============

    /**
     * @dev 重写 _update 函数以支持暂停机制和黑名单检查
     */
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override(ERC721, ERC721Enumerable) whenNotPaused returns (address) {
        address from = _ownerOf(tokenId);
        
        // 检查 NFT 黑名单（铸造时 from 为 address(0)，不需要检查；销毁时 to 为 address(0)，也不需要检查）
        if (from != address(0) && to != address(0)) {
            require(!blacklistedTokens[tokenId], "Token is blacklisted");
        }
        
        return super._update(to, tokenId, auth);
    }

    /**
     * @dev 重写 _increaseBalance 函数
     */
    function _increaseBalance(
        address account,
        uint128 value
    ) internal override(ERC721, ERC721Enumerable) {
        super._increaseBalance(account, value);
    }

    /**
     * @dev 重写 tokenURI 函数
     */
    function tokenURI(
        uint256 tokenId
    ) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    /**
     * @dev 重写 supportsInterface 函数
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC721, ERC721Enumerable, ERC721URIStorage, IERC165) returns (bool) {
        return interfaceId == type(IERC2981).interfaceId || super.supportsInterface(interfaceId);
    }
}
