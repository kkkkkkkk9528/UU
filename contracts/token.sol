// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ERC20BurnableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {UUPSUpgradeableBase} from "./UUPSUpgradeableBase.sol";

/**
 * @title BEP20 Token Upgradeable Contract
 * @author SWM Team
 * @notice 可升级的 ERC20 代币合约，支持批量转账、铸造、销毁
 * @dev 
 * 继承自 UUPSUpgradeableBase，支持：
 * - 多签钱包控制
 * - DAO 治理
 * - 升级时间锁
 */
contract BEP20TokenUpgradeable is
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    ERC20BurnableUpgradeable,
    UUPSUpgradeableBase
{
    // ============================================================
    //                        CONSTANTS
    // ============================================================
    
    /// @dev 批量转账最大接收者数量
    uint256 private constant _MAX_BATCH_RECIPIENTS = 1000;

    // ============================================================
    //                         STORAGE
    // ============================================================
    
    /// @notice 代币精度
    uint8 private _tokenDecimals;

    // ============================================================
    //                      STORAGE GAP
    // ============================================================
    
    /// @dev 预留存储槽位
    uint256[49] private __gap;

    // ============================================================
    //                         ERRORS
    // ============================================================
    
    /// @dev 数组长度不匹配
    error ErrArraysLengthMismatch();
    /// @dev 空数组
    error ErrEmptyArrays();
    /// @dev 接收者过多
    error ErrTooManyRecipients();
    /// @dev 余额不足
    error ErrInsufficientBalance();
    /// @dev 无效接收者
    error ErrInvalidRecipient();
    /// @dev 铸造到零地址
    error ErrMintToZeroAddress();
    /// @dev 名称为空
    error ErrNameEmpty();
    /// @dev 符号为空
    error ErrSymbolEmpty();
    /// @dev 初始供应量过大（会导致溢出）
    error ErrInitialSupplyOverflow();

    // ============================================================
    //                         EVENTS
    // ============================================================
    
    /// @dev 批量转账事件
    event BatchTransfer(address indexed from, uint256 totalAmount, uint256 recipientCount);
    /// @dev 铸造事件
    event TokenMinted(address indexed to, uint256 amount);
    /// @dev 销毁事件
    event TokenBurned(address indexed from, uint256 amount);

    // ============================================================
    //                       CONSTRUCTOR
    // ============================================================
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============================================================
    //                      INITIALIZERS
    // ============================================================
    
    /**
     * @notice 初始化代币合约（基础版）
     * @param name_ 代币名称
     * @param symbol_ 代币符号
     * @param initialSupply_ 初始供应量（不含精度）
     * @param decimals_ 代币精度
     * @param owner_ 合约所有者
     */
    function initialize(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply_,
        uint8 decimals_,
        address owner_
    ) external initializer {
        _initializeToken(name_, symbol_, initialSupply_, decimals_, owner_, address(0), address(0));
    }
    
    /**
     * @notice 初始化代币合约（完整版，带多签和 DAO）
     * @param name_ 代币名称
     * @param symbol_ 代币符号
     * @param initialSupply_ 初始供应量（不含精度）
     * @param decimals_ 代币精度
     * @param owner_ 合约所有者
     * @param multiSig_ 多签钱包地址
     * @param dao_ DAO 治理合约地址
     */
    function initialize(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply_,
        uint8 decimals_,
        address owner_,
        address multiSig_,
        address dao_
    ) external initializer {
        _initializeToken(name_, symbol_, initialSupply_, decimals_, owner_, multiSig_, dao_);
    }
    
    /**
     * @dev 内部初始化函数
     */
    function _initializeToken(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply_,
        uint8 decimals_,
        address owner_,
        address multiSig_,
        address dao_
    ) internal {
        if (bytes(name_).length == 0) revert ErrNameEmpty();
        if (bytes(symbol_).length == 0) revert ErrSymbolEmpty();
        
        // 初始化 ERC20
        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);
        __ERC20Burnable_init();
        
        // 初始化 UUPS 基类
        __UUPSBase_init(owner_, multiSig_, dao_);
        
        // 设置精度
        _tokenDecimals = decimals_;
        
        // 铸造初始供应量（带溢出检查）
        if (initialSupply_ != 0) {
            uint256 multiplier = 10 ** decimals_;
            if (initialSupply_ > type(uint256).max / multiplier) {
                revert ErrInitialSupplyOverflow();
            }
            _mint(owner_, initialSupply_ * multiplier);
        }
    }

    // ============================================================
    //                      VIEW FUNCTIONS
    // ============================================================
    
    /**
     * @notice 获取代币精度
     * @return 精度位数
     */
    function decimals() public view virtual override returns (uint8) {
        return _tokenDecimals;
    }
    
    /**
     * @notice 获取合约版本
     * @return 版本字符串
     */
    function version() public pure virtual override returns (string memory) {
        return "1.0.0";
    }

    // ============================================================
    //                    TOKEN FUNCTIONS
    // ============================================================
    
    /**
     * @notice 批量转账
     * @param recipients 接收者地址数组
     * @param amounts 金额数组
     * @return 是否成功
     */
    function batchTransfer(
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external whenNotPaused nonReentrant returns (bool) {
        uint256 len = recipients.length;
        if (len != amounts.length) revert ErrArraysLengthMismatch();
        if (len == 0) revert ErrEmptyArrays();
        if (len > _MAX_BATCH_RECIPIENTS) revert ErrTooManyRecipients();
        
        // 计算总金额（利用 Solidity 0.8.x 内置溢出检查）
        uint256 totalAmount;
        for (uint256 i; i < len;) {
            totalAmount += amounts[i];
            unchecked { ++i; }
        }
        
        // 检查余额
        if (balanceOf(msg.sender) < totalAmount) revert ErrInsufficientBalance();
        
        // 执行转账
        for (uint256 i; i < len;) {
            if (recipients[i] == address(0)) revert ErrInvalidRecipient();
            _transfer(msg.sender, recipients[i], amounts[i]);
            unchecked { ++i; }
        }
        
        emit BatchTransfer(msg.sender, totalAmount, len);
        return true;
    }
    
    /**
     * @notice 铸造代币
     * @param to 接收者地址
     * @param amount 铸造数量
     */
    function mint(address to, uint256 amount) external onlyOwnerOrMultiSig whenNotPaused {
        if (to == address(0)) revert ErrMintToZeroAddress();
        _mint(to, amount);
        emit TokenMinted(to, amount);
    }
    
    /**
     * @notice 销毁代币（覆盖父类以添加事件）
     * @param amount 销毁数量
     */
    function burn(uint256 amount) public virtual override whenNotPaused {
        super.burn(amount);
        emit TokenBurned(msg.sender, amount);
    }
    
    /**
     * @notice 从指定地址销毁代币
     * @param account 目标地址
     * @param amount 销毁数量
     */
    function burnFrom(address account, uint256 amount) public virtual override whenNotPaused {
        super.burnFrom(account, amount);
        emit TokenBurned(account, amount);
    }

    // ============================================================
    //                    TRANSFER HOOKS
    // ============================================================
    
    /**
     * @dev 转账前检查（暂停时禁止转账）
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal virtual override {
        // 铸造和销毁不受暂停影响（由各自函数控制）
        if (from != address(0) && to != address(0)) {
            _requireNotPaused();
        }
        super._update(from, to, value);
    }
}
