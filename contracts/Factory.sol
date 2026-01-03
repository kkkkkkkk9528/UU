// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Token as BEP20Token} from "./token.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title Deterministic CREATE2 Factory
/// @notice Address formula: address = keccak256(0xff, factory, salt, keccak256(creationCode+abi.encode(args)))[12:]
contract Factory is Ownable(msg.sender) {
  event TokenDeployed(address indexed addr, bytes32 indexed salt);

  /// @dev Deploy via CREATE2 with salt
  function deployToken(
    bytes32 salt,
    string memory name,
    string memory symbol,
    uint8 decimals,
    uint256 supply
  )
    external
    payable
    onlyOwner
    returns (address addr)
  {
    BEP20Token tok = new BEP20Token{salt: salt}(name, symbol, decimals, supply);

    // Immediately transfer ownership to deployer (msg.sender)
    tok.transferOwnership(msg.sender);

    addr = address(tok);
    emit TokenDeployed(addr, salt);
  }

  /// @notice Compute token address under this factory with given params and salt (matches offline calculation)
  function computeTokenAddress(
    bytes32 salt,
    string memory name,
    string memory symbol,
    uint8 decimals,
    uint256 supply
  )
    external
    view
    returns (address)
  {
    bytes memory init = abi.encodePacked(type(BEP20Token).creationCode, abi.encode(name, symbol, decimals, supply));
    bytes32 initHash = keccak256(init);
    return address(uint160(uint(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash)))));
  }

  /// @notice Return only initCodeHash for frontend/script local calculation comparison
  function computeInitCodeHash(
    string memory name,
    string memory symbol,
    uint8 decimals,
    uint256 supply
  )
    external
    pure
    returns (bytes32)
  {
    bytes memory init = abi.encodePacked(type(BEP20Token).creationCode, abi.encode(name, symbol, decimals, supply));
    return keccak256(init);
  }
}