// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title UUPS Proxy Contract
 * @author SWM Team
 * @notice ERC1967 proxy contract, used with UUPSUpgradeableBase
 * @dev
 * - Uses OpenZeppelin ERC1967Proxy standard implementation
 * - All calls forwarded to implementation contract via delegatecall
 * - Data stored in proxy contract, logic in implementation contract
 */
contract UUPSProxy is ERC1967Proxy {
    /**
     * @notice Deploy proxy contract
     * @param implementation Implementation contract address
     * @param data Initialization call data
     */
    constructor(
        address implementation,
        bytes memory data
    ) ERC1967Proxy(implementation, data) {}
}
