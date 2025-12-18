# CREATE2 Token Factory Project

A secure and efficient token deployment system using CREATE2 for deterministic addresses.

## Project Structure

### contracts/
- `Factory.sol` - CREATE2 factory contract for deterministic token deployment
- `token.sol` - BEP20 token implementation with batch transfers and ownership management

### scripts/
- `exactFactoryLogic.js` - Local factory logic verification
- `vanity44444-fixed.js` - Vanity address generator for tokens ending with '44444'

### tests/
- `factory.test.js` - Comprehensive factory contract tests
- `token.test.js` - Token contract functionality tests

## Key Features

### Factory Contract
- **Deterministic Deployment**: Uses CREATE2 for predictable token addresses
- **Access Control**: Only factory owner can deploy tokens
- **Automatic Ownership Transfer**: Deployed tokens immediately transfer ownership to deployer
- **Address Computation**: Helper functions for offline address calculation

### Token Contract
- **Standard ERC20**: Full ERC20 compliance with extensions
- **Batch Transfers**: Support up to 1000 recipients in single transaction
- **Owner Minting**: Owner-only token minting capability
- **Security**: Comprehensive input validation and error handling

## Usage

### Deploy Factory
```bash
npx hardhat run scripts/deploy.js --network <network>
```

### Deploy Token via Factory
```javascript
const factory = await ethers.getContractAt("Factory", factoryAddress);
await factory.deployToken(salt, name, symbol, supply, decimals);
```

### Batch Transfer Tokens
```javascript
await token.batchTransfer(recipients, amounts);
```

## Development

### Prerequisites
- Node.js >= 16
- Hardhat

### Setup
```bash
npm install
```

### Compile
```bash
npx hardhat compile
```

### Test
```bash
npx hardhat test
```

### Deploy
```bash
npx hardhat run scripts/deploy.js --network <network>
```

## Security Considerations

- Factory contract owner has full control over token deployment
- Deployed tokens automatically transfer ownership to deployer
- All contracts use OpenZeppelin battle-tested implementations
- Comprehensive test coverage ensures reliability

## License

MIT
