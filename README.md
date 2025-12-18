# BEP20/ERC20 Upgradeable Token Project

**A UUPS-proxy upgradeable token with batch transfer, governance, and multisig support.**

![License](https://img.shields.io/badge/license-MIT-blue)
![Solidity](https://img.shields.io/badge/solidity-0.8.24-orange)
![Vue](https://img.shields.io/badge/vue-3.3.4-green)
![Wagmi](https://img.shields.io/badge/wagmi-1.4.0-ff69b4)

---

## 📋 Project Structure

```bash
/
├── contracts/              # Smart contracts (UUPS + ERC20)
├── frontend-vue/           # Vue 3 user frontend
├── admin-vue/              # Vue 3 admin dashboard
├── scripts/                # Deployment/upgrade scripts
├── test/                   # Hardhat tests
├── hardhat.config.ts       # Hardhat config
└── README.md

🚀 Features
Smart Contract
✅ UUPS Upgradeable (OpenZeppelin)
✅ Batch Transfers (Max 1000 recipients)
✅ Pausable (Emergency stop)
✅ ERC20 Permit (Gasless approvals)
✅ Governance Ready (DAO/Multisig upgrades)
✅ Reentrancy Guard (Secure transfers)
Frontend (Vue 3)
🔗 Wallet Connection (MetaMask, WalletConnect)
💰 Token Transfers (Single & Batch)
📊 Balance & Transaction History
🔄 Network Switcher (BSC, Ethereum)
Admin Dashboard
🔧 Contract Upgrades (UUPS)
🛡 Pause/Unpause (Emergency control)
💠 Mint/Burn (Admin-only)
🏛 DAO Proposals (Governance integration)
🔐 Multisig Transactions (Gnosis Safe)
🛠 Setup
Prerequisites
Node.js ≥ 18.x
Yarn / pnpm (recommended)
Hardhat ≥ 2.19.0
MetaMask (for frontend testing)
1. Install Dependencies
bash
# Install root dependencies (contracts/scripts)
yarn install

# Install frontend
cd frontend-vue
yarn install

# Install admin dashboard
cd ../admin-vue
yarn install
2. Configure Environment
Copy .env.example to .env and update:

Frontend (frontend-vue/.env)
env
VITE_RPC_URL_BSC=https://bsc-dataseed.bnbchain.org/
VITE_RPC_URL_ETH=https://mainnet.infura.io/v3/YOUR_INFURA_KEY
VITE_TOKEN_ADDRESS=0xYourDeployedTokenAddress
VITE_MULTISIG_ADDRESS=0xYourGnosisSafeAddress
Admin (admin-vue/.env)
env
VITE_SAFE_SERVICE_URL=https://safe-transaction.bscscan.com
VITE_DAO_ADDRESS=0xYourDAOAddress
Hardhat (hardhat.config.ts)
typescript
networks: {
  bsc: {
    url: "https://bsc-dataseed.bnbchain.org/",
    accounts: [process.env.DEPLOYER_PRIVATE_KEY!],
  },
},
📦 Smart Contracts
Key Contracts
Contract	Description	File
BEP20TokenUpgradeable	Main token logic (UUPS + ERC20)	contracts/token.sol
UUPSUpgradeableBase	Base contract (ownership, pausable)	contracts/base.sol
Compile & Test
bash
# Compile contracts
yarn hardhat compile

# Run tests
yarn hardhat test
Deployment
bash
# Deploy to BSC Testnet
yarn hardhat run scripts/deploy/1_deploy_token.ts --network bscTestnet

# Upgrade contract
yarn hardhat run scripts/upgrade/1_upgrade_token.ts --network bsc
🖥 Frontend (Vue 3)
Tech Stack
Framework: Vue 3 + Vite
State Management: Pinia
Web3: Wagmi + Ethers.js
UI: Tailwind CSS
Routing: Vue Router
Key Composables
File	Purpose
useWeb3.ts	Wallet connection
useTokenContract.ts	Token interactions
useBatchTransfer.ts	Batch transfer logic
Run Frontend
bash
cd frontend-vue
yarn dev
→ Open http://localhost:5173

🛡 Admin Dashboard
Tech Stack
Framework: Vue 3 + Vite
Multisig: @safe-global/safe-core-sdk
Auth: Basic Auth (or OAuth)
Charts: Chart.js (for transaction stats)
Key Features
Contract Upgrades: UUPS proxy upgrades via multisig.
Pause Controls: Emergency pause/unpause.
Minting: Admin-only token minting.
DAO Integration: Proposal creation/execution.
Run Admin Dashboard
bash
cd admin-vue
yarn dev
→ Open http://localhost:5174

🔧 Admin Operations
1. Upgrade Contract
bash
yarn hardhat run scripts/upgrade/1_upgrade_token.ts --network bsc
2. Mint Tokens (Admin)
javascript
// In admin-vue/src/composables/useAdmin.ts
const { mint } = useTokenContract();
await mint(recipientAddress, amount);
3. Pausefers
javascript
const { pause } = useTokenContract();
await pause();
4. Multisig Transaction
Use Gnosis Safe to:

Submit upgrade/mint transactions.
Require M-of-N signatures.
🧪 Testing
Unit Tests (Hardhat)
bash
yarn hardhat test test/token/BEP20TokenUpgradeable.ts
Frontend Tests (Vitest)
bash
cd frontend-vue
yarn test
Test Coverage
Contract: 95% (batch transfer, upgrades, pausable)
Frontend: 80% (wallet connection, transfers)
📜 License
MIT © [Your Name 🤝 Contributing

Fork the repository.
Create a feature branch (git checkout -b feature/xxx).
Commit changes (git commit -am 'Add xxx').
Push to branch (git push origin feature/xxx).
Open a Pull Request.
📬 Contact
Email: your@email.com
Twitter: @yourhandle
Telegram: @yourchannel


---

### **关键部分说明**
1. **项目概览**：
   - 明确标注 **UUPS 可升级**、**批量转账**、**多签/DAO** 等核心功能。
   - 使用 **Shields.io badge** 展示技术栈版本。

2. **环境配置**：
   - 分别列出 **前端**、**管理端**、**Hardhat** 的 `.env` 示例。
   - 强调 **私钥** 和 **合约地址** 的配置需求。

3. **合约部署**：
   - 提供 **编译**、**测试**、**部署**、**升级** 的完整命令。
   - 高亮 **BSC Testnet** 作为默认测试。

4. **前端/管理端**：
   - 详细列出 **技术栈** 和 **核心组合式函数**（Vue 3 的 `composables/`）。
   - 提供 **运行命令** 和 本地访问 URL。

5. **管理操作**：
   - 列出 **升级**、**铸造**、**暂停** 等关键操作的代码片段。
   - 强调 **多签（Gnosis Safe）** 的集成流程。

6. **测试**：
   - 区分 **合约测试（Hardhat）** 和 **前端测试（Vitest）**。
   - 标注 **测试覆盖率** 目标。

7注意事项**：
   - 虽然未单独列出，但通过 **多签要求**、**暂停功能**、**UUPS 升级流程** 隐含安全实践。

---
### **如何使用此 README？**
1. **替换占位符**：
   - 将 `0xYourDeployedTokenAddress`、`YOUR_INFURA_KEY` 等替换为实际值。
   - 更新 **联系方式** 和 **许可证** 信息。

2. **扩展部分**：
   - 如有 **特定治理规则**（O 提案阈值），可在 **Admin Dashboard** 部分补充。
   - 如使用 **IPFS** 部署前端，可添加 **部署指南** 章节。

3. **图片增强**：
   - 可添加 **架构图**（如 UUPS 升级流程）或 **界面截图**。

---
### **示例：添加架构图**
在 `## 📋 Project Structure` 后插入：
```markdown
## 🏗 Architecture

![UUPS Proxy Diagram](https://docs.openzeppelin.com/contracts/4.x/api/proxy#UUPS)
*UUPS Upgradeable Pattern (Source: OpenZeppelin)*