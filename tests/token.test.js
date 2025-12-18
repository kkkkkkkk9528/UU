import { expect } from "chai";
import hardhat from "hardhat";
const { ethers } = hardhat;

describe("BEP20Token", function () {
  let token;
  let owner;
  let addr1;
  let addr2;
  let addrs;

  beforeEach(async function () {
    [owner, addr1, addr2, ...addrs] = await ethers.getSigners();

    const BEP20Token = await ethers.getContractFactory("BEP20Token");
    token = await BEP20Token.deploy("Test Token", "TTK", 1000000, 18);
    await token.waitForDeployment();
  });

  describe("Deployment", function () {
    it("Should set the right owner", async function () {
      expect(await token.owner()).to.equal(owner.address);
    });

    it("Should assign the total supply of tokens to the owner", async function () {
      const ownerBalance = await token.balanceOf(owner.address);
      expect(await token.totalSupply()).to.equal(ownerBalance);
    });

    it("Should set the correct name and symbol", async function () {
      expect(await token.name()).to.equal("Test Token");
      expect(await token.symbol()).to.equal("TTK");
    });

    it("Should set the correct decimals", async function () {
      expect(await token.decimals()).to.equal(18);
    });
  });

  describe("Transactions", function () {
    it("Should transfer tokens between accounts", async function () {
      await token.transfer(addr1.address, 50);
      const addr1Balance = await token.balanceOf(addr1.address);
      expect(addr1Balance).to.equal(50);

      await token.connect(addr1).transfer(addr2.address, 50);
      const addr2Balance = await token.balanceOf(addr2.address);
      expect(addr2Balance).to.equal(50);
    });

    it("Should fail if sender doesn't have enough tokens", async function () {
      const initialOwnerBalance = await token.balanceOf(owner.address);

      await expect(
        token.connect(addr1).transfer(owner.address, 1)
      ).to.be.revertedWithCustomError(token, "ERC20InsufficientBalance");

      expect(await token.balanceOf(owner.address)).to.equal(
        initialOwnerBalance
      );
    });

    it("Should update balances after transfers", async function () {
      const initialOwnerBalance = await token.balanceOf(owner.address);

      await token.transfer(addr1.address, 100);
      await token.transfer(addr2.address, 50);

      const finalOwnerBalance = await token.balanceOf(owner.address);
      expect(finalOwnerBalance).to.equal(initialOwnerBalance - 150n);

      const addr1Balance = await token.balanceOf(addr1.address);
      expect(addr1Balance).to.equal(100);

      const addr2Balance = await token.balanceOf(addr2.address);
      expect(addr2Balance).to.equal(50);
    });
  });

  describe("Batch Transfer", function () {
    it("Should batch transfer tokens to multiple recipients", async function () {
      const recipients = [addr1.address, addr2.address];
      const amounts = [100, 200];

      await token.batchTransfer(recipients, amounts);

      expect(await token.balanceOf(addr1.address)).to.equal(100);
      expect(await token.balanceOf(addr2.address)).to.equal(200);
    });

    it("Should fail if arrays length mismatch", async function () {
      const recipients = [addr1.address, addr2.address];
      const amounts = [100];

      await expect(token.batchTransfer(recipients, amounts)).to.be.revertedWithCustomError(token, "ErrorArraysLengthMismatch");
    });

    it("Should fail if empty arrays", async function () {
      await expect(token.batchTransfer([], [])).to.be.revertedWithCustomError(token, "ErrorEmptyArrays");
    });

    it("Should fail if too many recipients", async function () {
      const recipients = new Array(201).fill(addr1.address);
      const amounts = new Array(201).fill(1);

      await expect(token.batchTransfer(recipients, amounts)).to.be.revertedWithCustomError(token, "ErrorTooManyRecipients");
    });

    it("Should fail if insufficient balance", async function () {
      const recipients = [addr1.address];
      const amounts = [ethers.parseEther("1000001")]; // More than total supply

      await expect(token.batchTransfer(recipients, amounts)).to.be.revertedWithCustomError(token, "ErrorInsufficientBalance");
    });
  });

  describe("Minting", function () {
    it("Should mint tokens to address", async function () {
      await token.mint(addr1.address, 100);
      expect(await token.balanceOf(addr1.address)).to.equal(100);
    });

    it("Should fail if not owner", async function () {
      await expect(token.connect(addr1).mint(addr2.address, 100)).to.be.revertedWithCustomError(token, "OwnableUnauthorizedAccount");
    });

    it("Should fail if mint to zero address", async function () {
      await expect(token.mint(ethers.ZeroAddress, 100)).to.be.revertedWithCustomError(token, "ErrorMintToZeroAddress");
    });
  });

  describe("Burning", function () {
    it("Should burn tokens", async function () {
      await token.transfer(addr1.address, 100);
      await token.connect(addr1).burn(50);
      expect(await token.balanceOf(addr1.address)).to.equal(50);
    });
  });

  describe("Ownership", function () {
    it("Should renounce ownership", async function () {
      await token.renounceOwnership();
      expect(await token.owner()).to.equal(ethers.ZeroAddress);
    });
  });
});