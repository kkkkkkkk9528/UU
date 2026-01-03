// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title UUPS Proxy Contract
 * @author SWM Team
 * @notice ERC1967 代理合约，配合 UUPSUpgradeableBase 使用
 * @dev 
 * - 使用 OpenZeppelin ERC1967Proxy 标准实现
 * - 所有调用通过 delegatecall 转发到实现合约
 * - 数据存储在代理合约，逻辑在实现合约
 */
contract UUPSProxy is ERC1967Proxy {
    /**
     * @notice 部署代理合约
     * @param implementation 实现合约地址
     * @param data 初始化调用数据
     */
    constructor(
        address implementation,
        bytes memory data
    ) ERC1967Proxy(implementation, data) {}
}
