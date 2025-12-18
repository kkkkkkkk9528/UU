// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BEP20TokenUpgradeable} from "./token.sol";
import {UUPSProxy} from "./UUPSProxy.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title Deterministic CREATE2 Factory for Upgradeable Tokens
/// @notice 部署可升级代币合约（通过 UUPS 代理）
/// @dev Address formula: address = keccak256(0xff, factory, salt, keccak256(creationCode+abi.encode(args)))[12:]
contract Factory is Ownable(msg.sender) {
    /// @notice 代币实现合约地址
    address public tokenImplementation;

    event TokenDeployed(address indexed proxy, address indexed implementation, bytes32 indexed salt);
    event ImplementationUpdated(address indexed oldImpl, address indexed newImpl);

    constructor() {
        // 部署默认实现合约
        tokenImplementation = address(new BEP20TokenUpgradeable());
    }

    /// @notice 更新代币实现合约
    /// @param newImpl 新实现合约地址
    function setImplementation(address newImpl) external onlyOwner {
        require(newImpl != address(0), "Invalid implementation");
        address oldImpl = tokenImplementation;
        tokenImplementation = newImpl;
        emit ImplementationUpdated(oldImpl, newImpl);
    }

    /// @dev Deploy via CREATE2 with salt (upgradeable proxy)
    function deployToken(
        bytes32 salt,
        string memory name,
        string memory symbol,
        uint256 supply,
        uint8 decimals
    ) external payable onlyOwner returns (address addr) {
        // 编码初始化数据（基础版 5 参数）
        bytes memory initData = abi.encodeWithSignature(
            "initialize(string,string,uint256,uint8,address)",
            name, symbol, supply, decimals, msg.sender
        );

        // 部署代理
        UUPSProxy proxy = new UUPSProxy{salt: salt}(tokenImplementation, initData);

        addr = address(proxy);
        emit TokenDeployed(addr, tokenImplementation, salt);
    }

    /// @notice 部署带多签和 DAO 的代币
    function deployTokenFull(
        bytes32 salt,
        string memory name,
        string memory symbol,
        uint256 supply,
        uint8 decimals,
        address multiSig,
        address dao
    ) external payable onlyOwner returns (address addr) {
        // 编码初始化数据（完整版 7 参数）
        bytes memory initData = abi.encodeWithSignature(
            "initialize(string,string,uint256,uint8,address,address,address)",
            name, symbol, supply, decimals, msg.sender, multiSig, dao
        );

        // 部署代理
        UUPSProxy proxy = new UUPSProxy{salt: salt}(tokenImplementation, initData);

        addr = address(proxy);
        emit TokenDeployed(addr, tokenImplementation, salt);
    }

    /// @notice Compute token proxy address under this factory with given params and salt
    function computeTokenAddress(
        bytes32 salt,
        string memory name,
        string memory symbol,
        uint256 supply,
        uint8 decimals
    ) external view returns (address) {
        bytes memory initData = abi.encodeWithSignature(
            "initialize(string,string,uint256,uint8,address)",
            name, symbol, supply, decimals, msg.sender
        );

        bytes memory init = abi.encodePacked(
            type(UUPSProxy).creationCode,
            abi.encode(tokenImplementation, initData)
        );
        bytes32 initHash = keccak256(init);
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash)))));
    }

    /// @notice Return only initCodeHash for frontend/script local calculation comparison
    function computeInitCodeHash(
        string memory name,
        string memory symbol,
        uint256 supply,
        uint8 decimals
    ) external view returns (bytes32) {
        bytes memory initData = abi.encodeWithSignature(
            "initialize(string,string,uint256,uint8,address)",
            name, symbol, supply, decimals, msg.sender
        );

        bytes memory init = abi.encodePacked(
            type(UUPSProxy).creationCode,
            abi.encode(tokenImplementation, initData)
        );
        return keccak256(init);
    }
}
