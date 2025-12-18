# CREATE2 Vanity 地址生成指南

## 概述

本指南介绍如何使用 CREATE2 确定性部署生成以特定后缀结尾的 vanity 地址。适用于 BEP20 代币在 BSC 测试网上的部署。

## 核心原理

CREATE2 地址计算公式：
```
address = keccak256(0xff + factory + salt + keccak256(creationCode + abi.encode(args)))[12:]
```

其中：
- `factory`: 工厂合约地址
- `salt`: 32字节随机数（用于生成不同地址）
- `creationCode`: 合约字节码
- `args`: 构造函数参数

## 关键发现

### 1. Init Code Hash 必须使用链上真实值

**重要**: 不要依赖本地计算的 init code hash！必须使用链上 Factory 合约返回的真实 hash。

原因：
- 链上合约可能与本地编译版本不同
- 编译环境差异可能导致字节码不一致
- 使用错误的 hash 会导致地址计算错误

### 2. 正确的工作流程

```bash
# 1. 获取链上真实的 init code hash
cast call 0x0C605B4C0442e9aE5c3C65d4dadEac76246aA751 \
  "computeInitCodeHash(string,string,uint256,uint8)" \
  "马" "马" 1000000 18 \
  --rpc-url https://bsc-testnet.publicnode.com

# 2. 使用真实 hash 运行 vanity 搜索
node scripts/vanity44444-fixed.js \
  0x0C605B4C0442e9aE5c3C65d4dadEac76246aA751 \
  <真实_init_hash> \
  44444 \
  8

# 3. 使用找到的 salt 部署代币
# 代币地址将确定性地以目标后缀结尾
```

## 工具和脚本

### 1. `scripts/exactFactoryLogic.js`
用于本地计算和验证 init code hash（仅用于调试，不用于生产）。

### 2. `scripts/vanity44444-fixed.js`
修复版本的 CREATE2 vanity 地址生成器：
- 正确处理 salt 参数
- 多线程搜索
- 实时进度显示
- 结果验证

### 3. Factory 合约

**当前活跃合约**: `0xBE3Fe1852a06Aa70D8C1A7B548b8667AB31E5232`
**历史合约**: 
`0x0C605B4C0442e9aE5c3C65d4dadEac76246aA751`, `0x74b0d3cBc5e8a8183eC293705bcF558F8bd44033`, `0x7ED19ebB8a16708E0ea10C74588F4747e234E459`

关键函数：
- `computeInitCodeHash()`: 计算并返回 init code hash
- `computeTokenAddress()`: 计算给定参数下的代币地址
- `deployToken()`: 使用 salt 部署代币

## 实际案例

### 案例 1: 旧工厂合约 (0x0C605B4C0442e9aE5c3C65d4dadEac76246aA751)

**目标**: 生成以 `44444` 结尾的地址

**参数**:
- 名称: "马"
- 符号: "马"
- 供应量: 1,000,000
- 小数位: 18

**结果**:
- 地址: `0xa4f0d313deb82c975b28f4fe39d349e958244444`
- Salt: `0xc44624934b2714b234b41f50205de1da929ca9fb64d1b6d02e3f62b4ef54c162`
- 搜索时间: 8.81秒
- 尝试次数: 14,041

**验证交易**: `0x9e1795bfd3a42e041b9e8a938b1c3a17d5c01cc5126a5110ea94a9b5ff9a5dbf`

### 案例 2: 新工厂合约 (0x74b0d3cBc5e8a8183eC293705bcF558F8bd44033)

**目标**: 生成以 `44444` 结尾的地址

**参数**:
- 名称: "马"
- 符号: "马"
- 供应量: 1,000,000
- 小数位: 18

**结果**:
- 地址: `0x3f4e8f9ff2db732c7df2752a498599cbef044444`
- Salt: `0xa6e9263cc57308fc41c1eb43b9dafe5c748da59d49fae285778213053dc1fc38`
- 搜索时间: 20.19秒
- 尝试次数: 47,084

**链上验证**: Factory 合约确认地址计算正确

### 案例 3: 最新工厂合约 (0x7ED19ebB8a16708E0ea10C74588F4747e234E459)

**目标**: 生成以 `44444` 结尾的地址

**参数**:
- 名称: "马"
- 符号: "马"
- 供应量: 1,000,000
- 小数位: 18

**结果**:
- 地址: `0x85b32f1ee0c406be1723ba0f7608aed591f44444`
- Salt: `0x8db1952d63ec207a571f83380294b68a0d2704f078b6cbc5ed9a52d4c4530508`
- 搜索时间: 9.50秒
- 尝试次数: 10,767

**链上验证**: Factory 合约确认地址计算正确

### 案例 4: 当前工厂合约 (0xBE3Fe1852a06Aa70D8C1A7B548b8667AB31E5232)

**目标**: 生成以 `44444` 结尾的地址

**参数**:
- 名称: "马"
- 符号: "马"
- 供应量: 1,000,000
- 小数位: 18

**结果**:
- 地址: `0x3c45fbec3653f45318c54ecd64b89bc608e44444`
- Salt: `0x04995506cb7a4a5189a1dbcf59faaeab3c377a654037e615763872a71f566dc2`
- 搜索时间: 11.07秒
- 尝试次数: 14,464

**链上验证**: Factory 合约确认地址计算正确

## 最佳实践

### 1. 始终使用链上 hash
```javascript
// ❌ 错误：使用本地计算
const localHash = ethers.keccak256(initCode);

// ✅ 正确：使用链上合约返回
const realHash = await factory.computeInitCodeHash(name, symbol, supply, decimals);
```

### 2. 验证地址计算
每次找到 salt 后，都要验证计算出的地址是否正确匹配目标后缀。

### 3. 多线程搜索
使用更多线程可以显著加快搜索速度，但要注意系统资源限制。

### 4. 错误排查
如果本地 hash 与链上不匹配：
- 检查编译环境是否一致
- 确认合约代码是否最新
- 使用链上合约的返回值作为权威来源

## 技术细节

### Init Code 组成
```
initCode = creationCode + abi.encode(name, symbol, supply, decimals)
initCodeHash = keccak256(initCode)
```

### CREATE2 地址计算
```javascript
const input = ethers.solidityPacked(
  ["bytes1", "address", "bytes32", "bytes32"],
  ["0xff", factoryAddress, salt, initCodeHash]
);
const hash = ethers.keccak256(input);
const address = '0x' + hash.slice(26); // 取后20字节
```

### 性能优化
- 使用 Buffer 操作而非字符串
- 预计算不变值
- 多线程并行搜索
- 批量处理随机数生成

## 故障排除

### 常见问题

1. **Hash 不匹配**
   - 原因: 本地编译与链上合约不同
   - 解决: 直接使用链上 `computeInitCodeHash()` 返回值

2. **地址不匹配**
   - 原因: Salt 或参数错误
   - 解决: 重新验证所有输入参数

3. **搜索过慢**
   - 原因: 线程数不足或目标太复杂
   - 解决: 增加线程数或选择更简单的后缀

4. **内存不足**
   - 原因: 批量大小过大
   - 解决: 减少 `batchSize` 参数

## 结论

通过使用链上真实的 init code hash，我们确保了地址计算的准确性。结合优化的搜索算法，可以快速找到满足条件的 vanity 地址，实现确定性部署。