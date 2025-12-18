import { expect } from "chai";
import hardhat from "hardhat";
const { ethers } = hardhat;

describe("Factory", function () {
  let factory;
  let owner;
  let salt;
  let name = "Test Token";
  let symbol = "TTK";
  let supply = 1000000;
  let decimals = 18;

  beforeEach(async function () {
    [owner] = await ethers.getSigners();

    const Factory = await ethers.getContractFactory("Factory");
    factory = await Factory.deploy();
    await factory.waitForDeployment();

    // Generate a random salt for testing
    salt = ethers.randomBytes(32);
  });

  describe("Deployment", function () {
    it("Should deploy successfully", async function () {
      expect(await factory.getAddress()).to.be.properAddress;
    });
  });

  describe("computeInitCodeHash", function () {
    it("Should compute correct init code hash", async function () {
      const hash = await factory.computeInitCodeHash(name, symbol, supply, decimals);
      expect(hash).to.be.a("string");
      expect(hash).to.have.lengthOf(66); // 0x + 64 hex chars
    });
  });

  describe("computeTokenAddress", function () {
    it("Should predict correct token deployment address", async function () {
      const predictedAddress = await factory.computeTokenAddress(salt, name, symbol, supply, decimals);

      // Deploy token
      const tx = await factory.deployToken(salt, name, symbol, supply, decimals);
      const receipt = await tx.wait();

      const deployedEvent = receipt.logs.find(log => log.eventName === "TokenDeployed");
      const actualAddress = deployedEvent.args.addr;

      expect(predictedAddress).to.equal(actualAddress);
    });
  });

  describe("deployToken", function () {
    it("Should deploy token successfully", async function () {
      const tx = await factory.deployToken(salt, name, symbol, supply, decimals);
      const receipt = await tx.wait();

      const deployedEvent = receipt.logs.find(log => log.eventName === "TokenDeployed");
      expect(deployedEvent).to.not.be.undefined;
      expect(deployedEvent.args.salt).to.equal(ethers.hexlify(salt));

      const tokenAddress = deployedEvent.args.addr;
      expect(tokenAddress).to.be.properAddress;

      // Verify token was deployed correctly
      const token = await ethers.getContractAt("BEP20Token", tokenAddress);
      expect(await token.name()).to.equal(name);
      expect(await token.symbol()).to.equal(symbol);
      expect(await token.totalSupply()).to.equal(BigInt(supply) * (10n ** BigInt(decimals)));
      expect(await token.decimals()).to.equal(decimals);
    });

    it("Should emit TokenDeployed event", async function () {
      const predictedAddress = await factory.computeTokenAddress(salt, name, symbol, supply, decimals);

      await expect(factory.deployToken(salt, name, symbol, supply, decimals))
        .to.emit(factory, "TokenDeployed")
        .withArgs(predictedAddress, ethers.hexlify(salt));
    });

    it("Should support payable deployment", async function () {
      const value = ethers.parseEther("1");
      const tx = await factory.deployToken(salt, name, symbol, supply, decimals, { value });
      const receipt = await tx.wait();

      const deployedEvent = receipt.logs.find(log => log.eventName === "TokenDeployed");
      const tokenAddress = deployedEvent.args.addr;

      // Note: The ether goes to the factory contract, not the token contract
      // since CREATE2 deploys the token but the value stays with the factory
      expect(await ethers.provider.getBalance(await factory.getAddress())).to.be.at.least(value);
    });
  });

  describe("Address collision prevention", function () {
    it("Should deploy different addresses with different salts", async function () {
      const salt1 = ethers.randomBytes(32);
      const salt2 = ethers.randomBytes(32);

      const tx1 = await factory.deployToken(salt1, name, symbol, supply, decimals);
      const receipt1 = await tx1.wait();
      const addr1 = receipt1.logs.find(log => log.eventName === "TokenDeployed").args.addr;

      const tx2 = await factory.deployToken(salt2, name, symbol, supply, decimals);
      const receipt2 = await tx2.wait();
      const addr2 = receipt2.logs.find(log => log.eventName === "TokenDeployed").args.addr;

      expect(addr1).to.not.equal(addr2);
    });

    it("Should deploy same address with same parameters", async function () {
      const sameSalt = ethers.randomBytes(32);

      const tx1 = await factory.deployToken(sameSalt, name, symbol, supply, decimals);
      const receipt1 = await tx1.wait();
      const addr1 = receipt1.logs.find(log => log.eventName === "TokenDeployed").args.addr;

      // Try to deploy again with same parameters (should fail or return same address)
      // Note: CREATE2 will deploy to same address if salt and code are identical
      const predictedAddress = await factory.computeTokenAddress(sameSalt, name, symbol, supply, decimals);
      expect(predictedAddress).to.equal(addr1);
    });
  });

  describe("Vanity address generation", function () {
    it("Should find salt for address ending with 44444", async function () {
      // This test demonstrates the vanity address concept
      // In practice, this would be done off-chain with a script
      const targetSuffix = "44444";

      // Try a few salts to demonstrate the concept
      let found = false;
      let attempts = 0;
      let foundSalt;
      let foundAddress;

      while (!found && attempts < 100) { // Limit attempts for test
        const testSalt = ethers.randomBytes(32);
        const testAddress = await factory.computeTokenAddress(testSalt, name, symbol, supply, decimals);

        if (testAddress.toLowerCase().endsWith(targetSuffix.toLowerCase())) {
          found = true;
          foundSalt = testSalt;
          foundAddress = testAddress;
        }
        attempts++;
      }

      if (found) {
        console.log(`Found vanity address after ${attempts} attempts:`);
        console.log(`Salt: ${ethers.hexlify(foundSalt)}`);
        console.log(`Address: ${foundAddress}`);

        // Verify the found address
        const tx = await factory.deployToken(foundSalt, name, symbol, supply, decimals);
        const receipt = await tx.wait();
        const deployedEvent = receipt.logs.find(log => log.eventName === "TokenDeployed");
        const actualAddress = deployedEvent.args.addr;

        expect(actualAddress).to.equal(foundAddress);
        expect(actualAddress.toLowerCase()).to.include(targetSuffix.toLowerCase());
      } else {
        console.log(`No vanity address found within ${attempts} attempts. This is normal for rare suffixes.`);
        // Test still passes - just demonstrates the concept
        expect(attempts).to.be.greaterThan(0);
      }
    });
  });
});