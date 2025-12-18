#!/usr/bin/env node

/**
 * Fixed CREATE2 Vanity Address Generator
 * Fixed the bug where computeAddress always used this.saltBuffer instead of the parameter
 */

import crypto from 'crypto';
import { Worker, isMainThread, parentPort, workerData } from 'worker_threads';
import os from 'os';
import hardhat from 'hardhat';
const { ethers } = hardhat;

class VanityAddressGenerator {
    constructor(options = {}) {
        this.factoryAddress = options.factoryAddress;
        this.initCodeHash = options.initCodeHash;
        this.targetSuffix = options.targetSuffix || '44444';
        this.maxWorkers = options.maxWorkers || Math.max(1, os.cpus().length - 1);
        this.batchSize = options.batchSize || 10000;
        this.maxAttempts = options.maxAttempts || 10000000;
        this.progressInterval = options.progressInterval || 1000;

        // Pre-compute common values
        this.factoryBytes = Buffer.from(this.factoryAddress.slice(2), 'hex');
        this.initHashBytes = Buffer.from(this.initCodeHash.slice(2), 'hex');
        this.prefix = Buffer.from('ff', 'hex');

        // Target validation
        this.targetLower = this.targetSuffix.toLowerCase();
        this.targetLength = this.targetSuffix.length;
    }

    /**
     * Compute CREATE2 address using optimized buffer operations
     * FIXED: Now correctly uses the salt parameter instead of this.saltBuffer
     */
    computeAddress(salt) {
        // Convert salt to buffer if it's a string
        let saltBuffer;
        if (typeof salt === 'string') {
            saltBuffer = Buffer.from(salt.slice(2), 'hex');
        } else {
            saltBuffer = salt;
        }

        // Create input: 0xff + factory + salt + initHash
        const input = ethers.solidityPacked(
            ["bytes1", "address", "bytes32", "bytes32"],
            ["0xff", this.factoryAddress, '0x' + saltBuffer.toString('hex'), '0x' + this.initHashBytes.toString('hex')]
        );

        // Compute keccak256 using ethers (matches Solidity exactly)
        const hash = ethers.keccak256(input);

        // Take last 20 bytes (equivalent to [12:] in Solidity)
        const address = '0x' + hash.slice(26);
        return address;
    }

    /**
     * Test function to verify address computation matches Solidity
     */
    async testAddressComputation(factoryContract, salt, name, symbol, supply, decimals) {
        const saltHex = '0x' + salt.toString('hex');
        const jsAddress = this.computeAddress(salt);
        const solidityAddress = await factoryContract.computeTokenAddress(saltHex, name, symbol, supply, decimals);

        console.log(`\n🔬 地址计算测试:`);
        console.log(`盐值: ${saltHex}`);
        console.log(`JS 计算: ${jsAddress}`);
        console.log(`Solidity: ${solidityAddress.toLowerCase()}`);
        console.log(`匹配: ${jsAddress.toLowerCase() === solidityAddress.toLowerCase() ? '✅' : '❌'}`);

        // Debug: show computation steps
        console.log(`\n🔧 调试信息:`);
        console.log(`Factory: ${this.factoryAddress}`);
        console.log(`Salt buffer: ${salt.toString('hex')}`);
        console.log(`Init hash: ${this.initCodeHash}`);

        return jsAddress.toLowerCase() === solidityAddress.toLowerCase();
    }

    /**
     * Check if address ends with target suffix (case insensitive)
     */
    matchesTarget(address) {
        return address.toLowerCase().endsWith(this.targetLower);
    }

    /**
     * Generate random salt buffer
     */
    generateSalt() {
        return crypto.randomBytes(32);
    }

    /**
     * Worker thread function
     */
    static async workerThread(options) {
        const generator = new VanityAddressGenerator(options);
        let attempts = 0;
        const startTime = Date.now();

        while (attempts < options.maxAttempts) {
            // Process batch
            for (let i = 0; i < options.batchSize; i++) {
                const salt = generator.generateSalt();
                const address = generator.computeAddress(salt);

                attempts++;

                if (generator.matchesTarget(address)) {
                    parentPort.postMessage({
                        type: 'found',
                        salt: '0x' + salt.toString('hex'),
                        address: address,
                        attempts: attempts,
                        time: Date.now() - startTime
                    });
                    return;
                }
            }

            // Report progress (reduced frequency to every 10000 attempts)
            if (attempts % (options.progressInterval * 10) === 0) {
                const rate = attempts / ((Date.now() - startTime) / 1000);
                parentPort.postMessage({
                    type: 'progress',
                    workerId: options.workerId,
                    attempts: attempts,
                    rate: Math.round(rate)
                });
            }
        }

        parentPort.postMessage({
            type: 'finished',
            workerId: options.workerId,
            attempts: attempts
        });
    }

    /**
     * Main search function with multi-threading
     */
    async search() {
        console.log('🚀 Starting CREATE2 Vanity Address Generator (FIXED VERSION)');
        console.log(`Target suffix: ${this.targetSuffix}`);
        console.log(`Factory: ${this.factoryAddress}`);
        console.log(`Init Code Hash: ${this.initCodeHash}`);
        console.log(`Workers: ${this.maxWorkers}`);
        console.log(`Batch size: ${this.batchSize}`);
        console.log('');

        return new Promise((resolve, reject) => {
            const workers = [];
            let activeWorkers = 0;
            let totalAttempts = 0;
            const startTime = Date.now();
            let found = false;

            // Progress tracking
            const progress = {
                workers: new Array(this.maxWorkers).fill(0),
                totalRate: 0
            };

            const createWorker = (workerId) => {
                const worker = new Worker(new URL(import.meta.url), {
                    workerData: {
                        factoryAddress: this.factoryAddress,
                        initCodeHash: this.initCodeHash,
                        targetSuffix: this.targetSuffix,
                        workerId: workerId,
                        batchSize: this.batchSize,
                        maxAttempts: this.maxAttempts,
                        progressInterval: this.progressInterval
                    }
                });

                worker.on('message', (message) => {
                    switch (message.type) {
                        case 'found':
                            if (!found) {
                                found = true;
                                const result = {
                                    salt: message.salt,
                                    address: message.address,
                                    attempts: message.attempts,
                                    totalTime: Date.now() - startTime,
                                    workerId: message.workerId
                                };

                                // Terminate all workers
                                workers.forEach(w => w.terminate());
                                resolve(result);
                            }
                            break;

                        case 'progress':
                            progress.workers[message.workerId - 1] = message.rate;
                            progress.totalRate = progress.workers.reduce((a, b) => a + b, 0);
                            totalAttempts += message.attempts;

                            console.log(`Worker ${message.workerId}: ${message.attempts.toLocaleString()} attempts (${message.rate}/s) | Total: ${progress.totalRate}/s`);
                            break;

                        case 'finished':
                            activeWorkers--;
                            if (activeWorkers === 0 && !found) {
                                reject(new Error('No vanity address found within attempt limit'));
                            }
                            break;
                    }
                });

                worker.on('error', (error) => {
                    console.error(`Worker ${workerId} error:`, error);
                    activeWorkers--;
                });

                worker.on('exit', (code) => {
                    if (code !== 0 && !found) {
                        console.log(`Worker ${workerId} exited with code ${code}`);
                    }
                });

                workers.push(worker);
                activeWorkers++;
            };

            // Start workers
            for (let i = 1; i <= this.maxWorkers; i++) {
                createWorker(i);
            }

            // Timeout after reasonable time
            setTimeout(() => {
                if (!found) {
                    workers.forEach(w => w.terminate());
                    reject(new Error('Search timeout - try with more workers or different target'));
                }
            }, 300000); // 5 minutes
        });
    }
}

// Worker thread execution
if (!isMainThread) {
    VanityAddressGenerator.workerThread(workerData).catch(console.error);
    process.exit(0);
}

// CLI interface
async function main() {
    const args = process.argv.slice(2);

    if (args.length < 2) {
        console.log('Usage: node vanity44444-fixed.js <factory_address> <init_code_hash> [target_suffix] [max_workers]');
        console.log('Example: node vanity44444-fixed.js 0x123... 0x456... 44444 8');
        process.exit(1);
    }

    const [factoryAddress, initCodeHash, targetSuffix = '44444', maxWorkers] = args;

    try {
        const generator = new VanityAddressGenerator({
            factoryAddress,
            initCodeHash,
            targetSuffix,
            maxWorkers: maxWorkers ? parseInt(maxWorkers) : undefined
        });

        const result = await generator.search();

        console.log('\n🎉 SUCCESS! Found vanity address!');
        console.log(`Worker: ${result.workerId}`);
        console.log(`Attempts: ${result.attempts.toLocaleString()}`);
        console.log(`Time: ${(result.totalTime / 1000).toFixed(2)}s`);
        console.log(`Salt: ${result.salt}`);
        console.log(`Address: ${result.address}`);
        console.log('');
        console.log('=== VERIFICATION ===');
        console.log(`Factory: ${factoryAddress}`);
        console.log(`Salt: ${result.salt}`);
        console.log(`Init Code Hash: ${initCodeHash}`);
        console.log(`Target suffix: ${targetSuffix}`);
        console.log(`Computed address: ${generator.computeAddress(Buffer.from(result.salt.slice(2), 'hex'))}`);

    } catch (error) {
        console.error('❌ Error:', error.message);
        process.exit(1);
    }
}

if (import.meta.url === `file://${process.argv[1]}`) {
    main();
}

export default VanityAddressGenerator;