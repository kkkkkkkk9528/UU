// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/**
 * @title UUPS Upgradeable Base Contract
 * @author SWM Team
 * @notice Upgradeable contract base class supporting multisig wallet and DAO governance

 * @dev
 * Permission priority (high to low):
 * 1. DAO mode    - daoGovernance controls upgrades (48h delay)
 * 2. MultiSig    - multiSig controls upgrades (24h delay)
 * 3. Owner mode  - owner controls upgrades (24h delay)
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
    
    /// @dev Owner/MultiSig upgrade delay (24 hours)
    uint48 private constant _UPGRADE_DELAY = 24 hours;

    /// @dev DAO upgrade delay (48 hours)
    uint48 private constant _DAO_DELAY = 48 hours;

    /// @dev Upgrade expiry time (7 days)
    uint48 private constant _UPGRADE_EXPIRY = 7 days;

    // ============================================================
    //                         STORAGE
    // ============================================================
    
    /// @notice Multisig wallet address
    address public multiSig;

    /// @notice DAO governance contract address
    address public daoGovernance;

    /// @notice Whether multisig control is enabled
    bool public multiSigEnabled;

    /// @notice Whether DAO governance is enabled
    bool public daoEnabled;

    /// @notice Whether upgrade timelock is enabled
    bool public timelockEnabled;

    /// @notice Pending implementation contract address for upgrade
    address public pendingImplementation;

    /// @notice Upgrade request timestamp
    uint48 public upgradeRequestTime;

    /// @notice Upgrade request initiator
    address public upgradeRequester;

    // ============================================================
    //                      STORAGE GAP
    // ============================================================
    
    /// @dev Reserve 42 storage slots for future upgrades
    uint256[42] private __gap;

    // ============================================================
    //                         ERRORS
    // ============================================================
    
    /// @dev Zero address error
    error ErrZeroAddress();

    /// @dev Invalid implementation contract (zero address or no code)
    error ErrInvalidImplementation();

    /// @dev Caller has no permission
    error ErrUnauthorized();

    /// @dev Multisig wallet permission required
    error ErrMultiSigRequired();

    /// @dev DAO permission required
    error ErrDAORequired();

    /// @dev Timelock is active, cannot upgrade directly
    error ErrTimelockActive();

    /// @dev Upgrade not ready (delay time not reached)
    error ErrUpgradeNotReady();

    /// @dev Upgrade has expired
    error ErrUpgradeExpired();

    /// @dev No pending upgrade request
    error ErrNoPendingUpgrade();

    /// @dev Value not changed
    error ErrNoChange();

    /// @dev Feature not enabled
    error ErrNotEnabled();

    // ============================================================
    //                         EVENTS
    // ============================================================
    
    /// @dev Multisig wallet address updated
    event MultiSigUpdated(address indexed oldMultiSig, address indexed newMultiSig);

    /// @dev Multisig control toggled
    event MultiSigToggled(bool enabled);

    /// @dev DAO governance address updated
    event DAOUpdated(address indexed oldDAO, address indexed newDAO);

    /// @dev DAO governance toggled
    event DAOToggled(bool enabled);

    /// @dev Timelock toggled
    event TimelockToggled(bool enabled);

    /// @dev Upgrade request initiated
    event UpgradeRequested(
        address indexed requester,
        address indexed newImplementation,
        uint256 readyTime,
        uint256 expiryTime
    );

    /// @dev Upgrade request cancelled
    event UpgradeCancelled(address indexed implementation, address indexed cancelledBy);

    /// @dev Upgrade executed successfully
    event UpgradeExecuted(
        address indexed oldImplementation,
        address indexed newImplementation,
        address indexed executor
    );

    // ============================================================
    //                        MODIFIERS
    // ============================================================
    
    /**
     * @dev Only owner or multisig wallet can call
     */
    modifier onlyOwnerOrMultiSig() {
        _checkOwnerOrMultiSig();
        _;
    }

    /**
     * @dev Only addresses with upgrade permission can call
     */
    modifier onlyUpgradeAuth() {
        _checkUpgradeAuth();
        _;
    }

    // ============================================================
    //                       CONSTRUCTOR
    // ============================================================
    
    /**
     * @dev Disable initialization for implementation contract
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }

    // ============================================================
    //                      INITIALIZERS
    // ============================================================
    
    /**
     * @notice Basic initialization (owner only)
     * @param owner_ Contract owner address
     */
    function __UUPSBase_init(address owner_) internal onlyInitializing {
        if (owner_ == address(0)) revert ErrZeroAddress();
        
        __Ownable_init(owner_);
        __Ownable2Step_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        // Enable timelock by default
        timelockEnabled = true;
    }
    
    /**
     * @notice Full initialization (owner + multisig + DAO)
     * @param owner_ Contract owner address
     * @param multiSig_ Multisig wallet address (can be zero address)
     * @param dao_ DAO governance contract address (can be zero address)
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
     * @notice Get contract version
     * @return Version string
     * @dev Subcontracts should override this function to return new version number
     */
    function version() public pure virtual returns (string memory) {
        return "1.0.0";
    }
    
    /**
     * @notice Get upgrade delay time
     * @return delay Delay in seconds
     */
    function getUpgradeDelay() public view returns (uint48 delay) {
        delay = daoEnabled ? _DAO_DELAY : _UPGRADE_DELAY;
    }
    
    /**
     * @notice Get upgrade expiry time
     * @return Expiry seconds
     */
    function getUpgradeExpiry() external pure returns (uint48) {
        return _UPGRADE_EXPIRY;
    }
    
    /**
     * @notice Query upgrade status
     * @return pending Pending implementation contract address for upgrade
     * @return requester Upgrade request initiator
     * @return ready Whether upgrade can be executed
     * @return readyTime Upgrade ready time
     * @return expiryTime Upgrade expiry time
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
     * @notice Check if address has upgrade permission
     * @param account Address to check
     * @return Whether has permission
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
     * @notice Get current permission mode
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
     * @notice Pause contract
     * @dev Owner or multisig wallet can call
     */
    function pause() external onlyOwnerOrMultiSig {
        _pause();
    }
    
    /**
     * @notice Unpause contract
     * @dev Owner or multisig wallet can call
     */
    function unpause() external onlyOwnerOrMultiSig {
        _unpause();
    }

    // ============================================================
    //                   MULTISIG FUNCTIONS
    // ============================================================
    
    /**
     * @notice Set multisig wallet address
     * @param newMultiSig New multisig wallet address
     */
    function setMultiSig(address newMultiSig) external onlyOwner {
        if (newMultiSig == address(0)) revert ErrZeroAddress();
        
        address oldMultiSig = multiSig;
        if (oldMultiSig == newMultiSig) revert ErrNoChange();
        
        multiSig = newMultiSig;
        emit MultiSigUpdated(oldMultiSig, newMultiSig);
    }
    
    /**
     * @notice Enable multisig control
     * @dev Must set multisig address first
     */
    function enableMultiSig() external onlyOwner {
        if (multiSig == address(0)) revert ErrZeroAddress();
        if (multiSigEnabled) revert ErrNoChange();
        
        multiSigEnabled = true;
        emit MultiSigToggled(true);
    }
    
    /**
     * @notice Disable multisig control
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
     * @notice Set DAO governance contract address
     * @param newDAO New DAO contract address
     */
    function setDAOGovernance(address newDAO) external onlyOwner {
        if (newDAO == address(0)) revert ErrZeroAddress();
        
        address oldDAO = daoGovernance;
        if (oldDAO == newDAO) revert ErrNoChange();
        
        daoGovernance = newDAO;
        emit DAOUpdated(oldDAO, newDAO);
    }
    
    /**
     * @notice Enable DAO governance
     * @dev
     * - Must set DAO address first
     * - After enabling, upgrade permission transfers to DAO
     * - Upgrade delay becomes 48 hours
     */
    function enableDAO() external onlyOwner {
        if (daoGovernance == address(0)) revert ErrZeroAddress();
        if (daoEnabled) revert ErrNoChange();
        
        daoEnabled = true;
        emit DAOToggled(true);
    }
    
    /**
     * @notice Disable DAO governance
     * @dev After disabling, upgrade permission returns to owner or multisig
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
     * @notice Enable upgrade timelock
     */
    function enableTimelock() external onlyOwner {
        if (timelockEnabled) revert ErrNoChange();
        
        timelockEnabled = true;
        emit TimelockToggled(true);
    }
    
    /**
     * @notice Disable upgrade timelock
     * @dev Dangerous operation, allows direct upgrades after disabling
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
     * @notice Request upgrade
     * @param newImplementation New implementation contract address
     * @dev
     * - Owner mode: owner initiates, 24h delay
     * - MultiSig mode: multisig initiates, 24h delay
     * - DAO mode: DAO initiates, 48h delay
     */
    function requestUpgrade(address newImplementation) external onlyUpgradeAuth {
        _validateImplementation(newImplementation);
        
        // Clear previous request (if any)
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
     * @notice Cancel upgrade request
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
     * @notice Execute upgrade
     * @dev Must execute after delay time and before expiry time
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
        
        // Execute upgrade first (_authorizeUpgrade will check pendingImplementation)
        upgradeToAndCall(pending, "");

        // Clear state after successful upgrade
        delete pendingImplementation;
        delete upgradeRequestTime;
        delete upgradeRequester;
    }
    
    /**
     * @notice Emergency upgrade (no timelock)
     * @param newImplementation New implementation contract address
     * @dev
     * - Not available when timelock is enabled
     * - Used for emergency vulnerability fixes
     */
    function emergencyUpgrade(address newImplementation) external onlyUpgradeAuth {
        if (timelockEnabled) revert ErrTimelockActive();
        
        _validateImplementation(newImplementation);
        
        // Clear any pending upgrades
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
     * @dev Check owner or multisig permission
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
     * @dev Check upgrade permission
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
     * @dev Validate implementation contract address
     */
    function _validateImplementation(address impl) internal view {
        if (impl == address(0)) revert ErrZeroAddress();
        if (impl.code.length == 0) revert ErrInvalidImplementation();
    }
    
    /**
     * @inheritdoc UUPSUpgradeable
     * @dev Authorize upgrade check
     */
    function _authorizeUpgrade(address newImplementation) internal virtual override {
        _checkUpgradeAuth();
        _validateImplementation(newImplementation);
        
        // Timelock mode: must go through requestUpgrade -> executeUpgrade process
        if (timelockEnabled) {
            if (pendingImplementation != newImplementation) {
                revert ErrTimelockActive();
            }
        }
        
        address currentImpl = _getImplementation();
        emit UpgradeExecuted(currentImpl, newImplementation, msg.sender);
    }
    
    /**
     * @dev Get current implementation contract address
     */
    function _getImplementation() internal view returns (address impl) {
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        assembly {
            impl := sload(slot)
        }
    }
}
