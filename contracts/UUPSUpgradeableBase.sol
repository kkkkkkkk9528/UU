// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/**
 * @title UUPS Upgradeable Base Contract
 * @author SWM Team
 * @notice 可升级合约基类，支持多签钱包和 DAO 治理1
 * 
 * @dev 
 * 权限优先级 (从高到低):
 * 1. DAO 模式    - daoGovernance 控制升级 (48h 延迟)
 * 2. MultiSig    - multiSig 控制升级 (24h 延迟)
 * 3. Owner 模式  - owner 控制升级 (24h 延迟)
 */
abstract contract UUPSUpgradeableBase is
    Initializable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    // ============================================================
    //                        CONSTANTS
    // ============================================================
    
    /// @dev Owner/MultiSig 升级延迟（24小时）
    uint48 private constant _UPGRADE_DELAY = 24 hours;
    
    /// @dev DAO 升级延迟（48小时）
    uint48 private constant _DAO_DELAY = 48 hours;
    
    /// @dev 升级过期时间（7天）
    uint48 private constant _UPGRADE_EXPIRY = 7 days;

    // ============================================================
    //                         STORAGE
    // ============================================================
    
    /// @notice 多签钱包地址
    address public multiSig;
    
    /// @notice DAO 治理合约地址
    address public daoGovernance;
    
    /// @notice 是否启用多签控制
    bool public multiSigEnabled;
    
    /// @notice 是否启用 DAO 治理
    bool public daoEnabled;
    
    /// @notice 是否启用升级时间锁
    bool public timelockEnabled;
    
    /// @notice 待升级的实现合约地址
    address public pendingImplementation;
    
    /// @notice 升级请求时间戳
    uint48 public upgradeRequestTime;
    
    /// @notice 升级请求发起者
    address public upgradeRequester;

    // ============================================================
    //                      STORAGE GAP
    // ============================================================
    
    /// @dev 预留 42 个存储槽位用于未来升级
    uint256[42] private __gap;

    // ============================================================
    //                         ERRORS
    // ============================================================
    
    /// @dev 零地址错误
    error ErrZeroAddress();
    
    /// @dev 无效的实现合约（零地址或无代码）
    error ErrInvalidImplementation();
    
    /// @dev 调用者无权限
    error ErrUnauthorized();
    
    /// @dev 需要多签钱包权限
    error ErrMultiSigRequired();
    
    /// @dev 需要 DAO 权限
    error ErrDAORequired();
    
    /// @dev 时间锁已启用，不能直接升级
    error ErrTimelockActive();
    
    /// @dev 升级未就绪（未到延迟时间）
    error ErrUpgradeNotReady();
    
    /// @dev 升级已过期
    error ErrUpgradeExpired();
    
    /// @dev 无待处理的升级请求
    error ErrNoPendingUpgrade();
    
    /// @dev 值未改变
    error ErrNoChange();
    
    /// @dev 功能未启用
    error ErrNotEnabled();

    // ============================================================
    //                         EVENTS
    // ============================================================
    
    /// @dev 多签钱包地址变更
    event MultiSigUpdated(address indexed oldMultiSig, address indexed newMultiSig);
    
    /// @dev 多签控制开关
    event MultiSigToggled(bool enabled);
    
    /// @dev DAO 治理地址变更
    event DAOUpdated(address indexed oldDAO, address indexed newDAO);
    
    /// @dev DAO 治理开关
    event DAOToggled(bool enabled);
    
    /// @dev 时间锁开关
    event TimelockToggled(bool enabled);
    
    /// @dev 升级请求发起
    event UpgradeRequested(
        address indexed requester,
        address indexed newImplementation,
        uint256 readyTime,
        uint256 expiryTime
    );
    
    /// @dev 升级请求取消
    event UpgradeCancelled(address indexed implementation, address indexed cancelledBy);
    
    /// @dev 升级执行完成
    event UpgradeExecuted(
        address indexed oldImplementation,
        address indexed newImplementation,
        address indexed executor
    );

    // ============================================================
    //                        MODIFIERS
    // ============================================================
    
    /**
     * @dev 只有 owner 或多签钱包可调用
     */
    modifier onlyOwnerOrMultiSig() {
        _checkOwnerOrMultiSig();
        _;
    }
    
    /**
     * @dev 只有有升级权限的地址可调用
     */
    modifier onlyUpgradeAuth() {
        _checkUpgradeAuth();
        _;
    }

    // ============================================================
    //                       CONSTRUCTOR
    // ============================================================
    
    /**
     * @dev 禁用实现合约的初始化
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }

    // ============================================================
    //                      INITIALIZERS
    // ============================================================
    
    /**
     * @notice 基础初始化（仅 owner）
     * @param owner_ 合约所有者地址
     */
    function __UUPSBase_init(address owner_) internal onlyInitializing {
        if (owner_ == address(0)) revert ErrZeroAddress();
        
        __Ownable_init(owner_);
        __Ownable2Step_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        // 默认启用时间锁
        timelockEnabled = true;
    }
    
    /**
     * @notice 完整初始化（owner + 多签 + DAO）
     * @param owner_ 合约所有者地址
     * @param multiSig_ 多签钱包地址（可为零地址）
     * @param dao_ DAO 治理合约地址（可为零地址）
     */
    function __UUPSBase_init(
        address owner_,
        address multiSig_,
        address dao_
    ) internal onlyInitializing {
        __UUPSBase_init(owner_);
        
        if (multiSig_ != address(0)) {
            multiSig = multiSig_;
            emit MultiSigUpdated(address(0), multiSig_);
        }
        
        if (dao_ != address(0)) {
            daoGovernance = dao_;
            emit DAOUpdated(address(0), dao_);
        }
    }

    // ============================================================
    //                      VIEW FUNCTIONS
    // ============================================================
    
    /**
     * @notice 获取合约版本
     * @return 版本字符串
     * @dev 子合约应覆盖此函数返回新版本号
     */
    function version() public pure virtual returns (string memory) {
        return "1.0.0";
    }
    
    /**
     * @notice 获取升级延迟时间
     * @return delay 延迟秒数
     */
    function getUpgradeDelay() public view returns (uint48 delay) {
        delay = daoEnabled ? _DAO_DELAY : _UPGRADE_DELAY;
    }
    
    /**
     * @notice 获取升级过期时间
     * @return 过期秒数
     */
    function getUpgradeExpiry() external pure returns (uint48) {
        return _UPGRADE_EXPIRY;
    }
    
    /**
     * @notice 查询升级状态
     * @return pending 待升级的实现合约地址
     * @return requester 升级请求发起者
     * @return ready 是否可以执行升级
     * @return readyTime 升级就绪时间
     * @return expiryTime 升级过期时间
     */
    function getUpgradeStatus() external view returns (
        address pending,
        address requester,
        bool ready,
        uint256 readyTime,
        uint256 expiryTime
    ) {
        pending = pendingImplementation;
        requester = upgradeRequester;
        
        if (pending == address(0)) {
            return (address(0), address(0), false, 0, 0);
        }
        
        uint256 reqTime = upgradeRequestTime;
        uint256 delay = getUpgradeDelay();
        
        readyTime = reqTime + delay;
        expiryTime = reqTime + _UPGRADE_EXPIRY;
        ready = block.timestamp >= readyTime && block.timestamp < expiryTime;
    }
    
    /**
     * @notice 检查地址是否有升级权限
     * @param account 要检查的地址
     * @return 是否有权限
     */
    function hasUpgradeAuth(address account) public view returns (bool) {
        if (daoEnabled) {
            return account == daoGovernance;
        }
        if (multiSigEnabled) {
            return account == multiSig;
        }
        return account == owner();
    }
    
    /**
     * @notice 获取当前权限模式
     * @return mode 0=Owner, 1=MultiSig, 2=DAO
     */
    function getAuthMode() external view returns (uint8 mode) {
        if (daoEnabled) return 2;
        if (multiSigEnabled) return 1;
        return 0;
    }

    // ============================================================
    //                    PAUSE FUNCTIONS
    // ============================================================
    
    /**
     * @notice 暂停合约
     * @dev owner 或多签钱包可调用
     */
    function pause() external onlyOwnerOrMultiSig {
        _pause();
    }
    
    /**
     * @notice 恢复合约
     * @dev owner 或多签钱包可调用
     */
    function unpause() external onlyOwnerOrMultiSig {
        _unpause();
    }

    // ============================================================
    //                   MULTISIG FUNCTIONS
    // ============================================================
    
    /**
     * @notice 设置多签钱包地址
     * @param newMultiSig 新多签钱包地址
     */
    function setMultiSig(address newMultiSig) external onlyOwner {
        if (newMultiSig == address(0)) revert ErrZeroAddress();
        
        address oldMultiSig = multiSig;
        if (oldMultiSig == newMultiSig) revert ErrNoChange();
        
        multiSig = newMultiSig;
        emit MultiSigUpdated(oldMultiSig, newMultiSig);
    }
    
    /**
     * @notice 开启多签控制
     * @dev 必须先设置多签地址
     */
    function enableMultiSig() external onlyOwner {
        if (multiSig == address(0)) revert ErrZeroAddress();
        if (multiSigEnabled) revert ErrNoChange();
        
        multiSigEnabled = true;
        emit MultiSigToggled(true);
    }
    
    /**
     * @notice 关闭多签控制
     */
    function disableMultiSig() external onlyOwner {
        if (!multiSigEnabled) revert ErrNoChange();
        
        multiSigEnabled = false;
        emit MultiSigToggled(false);
    }

    // ============================================================
    //                     DAO FUNCTIONS
    // ============================================================
    
    /**
     * @notice 设置 DAO 治理合约地址
     * @param newDAO 新 DAO 合约地址
     */
    function setDAOGovernance(address newDAO) external onlyOwner {
        if (newDAO == address(0)) revert ErrZeroAddress();
        
        address oldDAO = daoGovernance;
        if (oldDAO == newDAO) revert ErrNoChange();
        
        daoGovernance = newDAO;
        emit DAOUpdated(oldDAO, newDAO);
    }
    
    /**
     * @notice 开启 DAO 治理
     * @dev 
     * - 必须先设置 DAO 地址
     * - 启用后升级权限转移给 DAO
     * - 升级延迟变为 48 小时
     */
    function enableDAO() external onlyOwner {
        if (daoGovernance == address(0)) revert ErrZeroAddress();
        if (daoEnabled) revert ErrNoChange();
        
        daoEnabled = true;
        emit DAOToggled(true);
    }
    
    /**
     * @notice 关闭 DAO 治理
     * @dev 关闭后升级权限回到 owner 或多签
     */
    function disableDAO() external onlyOwner {
        if (!daoEnabled) revert ErrNoChange();
        
        daoEnabled = false;
        emit DAOToggled(false);
    }

    // ============================================================
    //                   TIMELOCK FUNCTIONS
    // ============================================================
    
    /**
     * @notice 开启升级时间锁
     */
    function enableTimelock() external onlyOwner {
        if (timelockEnabled) revert ErrNoChange();
        
        timelockEnabled = true;
        emit TimelockToggled(true);
    }
    
    /**
     * @notice 关闭升级时间锁
     * @dev 危险操作，关闭后可直接升级
     */
    function disableTimelock() external onlyOwner {
        if (!timelockEnabled) revert ErrNoChange();
        
        timelockEnabled = false;
        emit TimelockToggled(false);
    }

    // ============================================================
    //                   UPGRADE FUNCTIONS
    // ============================================================
    
    /**
     * @notice 请求升级
     * @param newImplementation 新实现合约地址
     * @dev 
     * - Owner 模式: owner 发起，24h 延迟
     * - MultiSig 模式: 多签发起，24h 延迟
     * - DAO 模式: DAO 发起，48h 延迟
     */
    function requestUpgrade(address newImplementation) external onlyUpgradeAuth {
        _validateImplementation(newImplementation);
        
        // 清除之前的请求（如果有）
        if (pendingImplementation != address(0)) {
            emit UpgradeCancelled(pendingImplementation, msg.sender);
        }
        
        pendingImplementation = newImplementation;
        uint48 currentTime = uint48(block.timestamp);
        upgradeRequestTime = currentTime;
        upgradeRequester = msg.sender;
        
        uint48 delay = getUpgradeDelay();
        uint256 readyTime = currentTime + delay;
        uint256 expiryTime = currentTime + _UPGRADE_EXPIRY;
        
        emit UpgradeRequested(msg.sender, newImplementation, readyTime, expiryTime);
    }
    
    /**
     * @notice 取消升级请求
     */
    function cancelUpgrade() external onlyUpgradeAuth {
        address pending = pendingImplementation;
        if (pending == address(0)) revert ErrNoPendingUpgrade();
        
        delete pendingImplementation;
        delete upgradeRequestTime;
        delete upgradeRequester;
        
        emit UpgradeCancelled(pending, msg.sender);
    }
    
    /**
     * @notice 执行升级
     * @dev 必须在延迟时间后、过期时间前执行
     */
    function executeUpgrade() external onlyUpgradeAuth {
        address pending = pendingImplementation;
        if (pending == address(0)) revert ErrNoPendingUpgrade();
        
        uint256 reqTime = upgradeRequestTime;
        uint256 delay = getUpgradeDelay();
        uint256 readyTime = reqTime + delay;
        uint256 expiryTime = reqTime + _UPGRADE_EXPIRY;
        
        if (block.timestamp < readyTime) revert ErrUpgradeNotReady();
        if (block.timestamp > expiryTime) revert ErrUpgradeExpired();
        
        // 先执行升级（_authorizeUpgrade 会检查 pendingImplementation）
        upgradeToAndCall(pending, "");
        
        // 升级成功后清除状态
        delete pendingImplementation;
        delete upgradeRequestTime;
        delete upgradeRequester;
    }
    
    /**
     * @notice 紧急升级（无时间锁）
     * @param newImplementation 新实现合约地址
     * @dev 
     * - 时间锁启用时不可用
     * - 用于紧急修复漏洞
     */
    function emergencyUpgrade(address newImplementation) external onlyUpgradeAuth {
        if (timelockEnabled) revert ErrTimelockActive();
        
        _validateImplementation(newImplementation);
        
        // 清除任何待处理的升级
        if (pendingImplementation != address(0)) {
            emit UpgradeCancelled(pendingImplementation, msg.sender);
            delete pendingImplementation;
            delete upgradeRequestTime;
            delete upgradeRequester;
        }
        
        upgradeToAndCall(newImplementation, "");
    }

    // ============================================================
    //                   INTERNAL FUNCTIONS
    // ============================================================
    
    /**
     * @dev 检查 owner 或多签权限
     */
    function _checkOwnerOrMultiSig() internal view {
        address sender = msg.sender;
        address _owner = owner();
        address _multiSig = multiSig;
        
        bool isOwner = sender == _owner;
        bool isMultiSig = _multiSig != address(0) && sender == _multiSig;
        
        if (!isOwner && !isMultiSig) {
            revert ErrUnauthorized();
        }
    }
    
    /**
     * @dev 检查升级权限
     */
    function _checkUpgradeAuth() internal view {
        address sender = msg.sender;
        
        if (daoEnabled) {
            if (sender != daoGovernance) revert ErrDAORequired();
            return;
        }
        
        if (multiSigEnabled) {
            if (sender != multiSig) revert ErrMultiSigRequired();
            return;
        }
        
        if (sender != owner()) revert ErrUnauthorized();
    }
    
    /**
     * @dev 验证实现合约地址
     */
    function _validateImplementation(address impl) internal view {
        if (impl == address(0)) revert ErrZeroAddress();
        if (impl.code.length == 0) revert ErrInvalidImplementation();
    }
    
    /**
     * @inheritdoc UUPSUpgradeable
     * @dev 授权升级检查
     */
    function _authorizeUpgrade(address newImplementation) internal virtual override {
        _checkUpgradeAuth();
        _validateImplementation(newImplementation);
        
        // 时间锁模式：必须通过 requestUpgrade -> executeUpgrade 流程
        if (timelockEnabled) {
            if (pendingImplementation != newImplementation) {
                revert ErrTimelockActive();
            }
        }
        
        address currentImpl = _getImplementation();
        emit UpgradeExecuted(currentImpl, newImplementation, msg.sender);
    }
    
    /**
     * @dev 获取当前实现合约地址
     */
    function _getImplementation() internal view returns (address impl) {
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        assembly {
            impl := sload(slot)
        }
    }
}
