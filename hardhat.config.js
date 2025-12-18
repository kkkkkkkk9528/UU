import "@nomicfoundation/hardhat-toolbox";

const config = {
  solidity: {
    version: "0.8.20",
    settings: {
      evmVersion: "paris",
      optimizer: {
        enabled: true,
        runs: 200
      }
    }
  },
  networks: {
    hardhat: {
      blockGasLimit: 1000000000,
      initialBaseFeePerGas: 0,
      gasPrice: 0,
      allowUnlimitedContractSize: true,
      disableBlockGasLimit: true
    },
    bscTestnet: {
      url: "https://bsc-testnet-rpc.publicnode.com/",
      chainId: 97,
      gasPrice: 20000000000,
      accounts: {
        mnemonic: process.env.MNEMONIC || "test test test test test test test test test test test junk"
      }
    }
  },
  mocha: {
    timeout: 120000
  }
};

export default config;