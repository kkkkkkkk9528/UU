import hardhat from "hardhat";
const { ethers } = hardhat;

/**
 * 使用 Hardhat 部署本地 Factory 合约并计算 initCodeHash
 * 用于与链上比对验证
 */
async function main() {
  console.log("🔢 本地部署 Factory 并计算 Init Code Hash...\n");

  // 代币参数 - 与部署使用相同参数
  const name = "马";
  const symbol = "马";
  const supply = 1000000;
  const decimals = 18;

  console.log("📋 代币参数:");
  console.log(`名称: ${name}`);
  console.log(`符号: ${symbol}`);
  console.log(`供应量: ${supply}`);
  console.log(`小数位: ${decimals}\n`);

  // 部署本地 Factory 合约
  const Factory = await ethers.getContractFactory("Factory");
  const factory = await Factory.deploy();
  await factory.waitForDeployment();

  console.log(`本地 Factory 地址: ${await factory.getAddress()}`);

  // 调用合约的 computeInitCodeHash 函数
  const initCodeHash = await factory.computeInitCodeHash(name, symbol, supply, decimals);

  console.log("\n🎯 合约计算结果:");
  console.log(`Init Code Hash: ${initCodeHash}`);
  console.log(`长度: ${initCodeHash.length} 字符 (应为 66)`);

  // 验证哈希格式
  const isValidHash = /^0x[a-fA-F0-9]{64}$/.test(initCodeHash);
  console.log(`格式验证: ${isValidHash ? '✅' : '❌'}`);

  console.log("\n📋 用于比对的命令:");
  console.log(`cast call 0x0C605B4C0442e9aE5c3C65d4dadEac76246aA751 "computeInitCodeHash(string,string,uint256,uint8)" "${name}" "${symbol}" ${supply} ${decimals} --rpc-url https://bsc-testnet.publicnode.com`);

  console.log("\n✅ 本地计算完成！");
  console.log("💡 提示: 确保使用相同的代币参数和编译环境。");

  // 输出便于脚本处理
  console.log(`\nLOCAL_INIT_HASH=${initCodeHash}`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("❌ 计算失败:", error);
    process.exit(1);
  });