// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title Simple BEP20 Token
 * @notice Standard ERC20 token supporting minting, burning, pausing, batch transfers, Permit signature authorization
 * @dev Fill parameters directly when deploying on Remix
 */
contract Token is ERC20, ERC20Permit, ERC20Burnable, Ownable, Pausable {
    
    uint8 private immutable _decimals;
    uint256 private constant MAX_BATCH = 500;

    error ArrayLengthMismatch();
    error EmptyArray();
    error TooManyRecipients();
    error InvalidRecipient();

    event BatchTransfer(address indexed from, uint256 total, uint256 count);
    event TokenMinted(address indexed to, uint256 amount);

    /**
     * @notice Deploy token
     * @param name_ Token name
     * @param symbol_ Token symbol
     * @param decimals_ Decimals (usually 18)
     * @param initialSupply_ Initial supply (without decimals, e.g. 1000000 = 1 million)
     */
    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        uint256 initialSupply_
    ) ERC20(name_, symbol_) ERC20Permit(name_) Ownable(msg.sender) {
        _decimals = decimals_;
        if (initialSupply_ > 0) {
            _mint(msg.sender, initialSupply_ * 10 ** decimals_);
        }
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Mint tokens (owner only)
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
        emit TokenMinted(to, amount);
    }

    /// @notice Pause transfers
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause transfers
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Batch transfer
    function batchTransfer(
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external whenNotPaused returns (bool) {
        uint256 len = recipients.length;
        if (len != amounts.length) revert ArrayLengthMismatch();
        if (len == 0) revert EmptyArray();
        if (len > MAX_BATCH) revert TooManyRecipients();

        uint256 total;
        for (uint256 i; i < len; ++i) {
            if (recipients[i] == address(0)) revert InvalidRecipient();
            total += amounts[i];
            _transfer(msg.sender, recipients[i], amounts[i]);
        }

        emit BatchTransfer(msg.sender, total, len);
        return true;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            _requireNotPaused();
        }
        super._update(from, to, value);
    }
}
