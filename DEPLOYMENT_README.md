# USX System Deployment Guide

This guide explains how to deploy the complete USX system to different Scroll environments using the hybrid approach that combines OpenZeppelin's security features with our custom diamond deployment logic.

> **Note**: The deployment script was recently renamed from `DeployScrollFork.s.sol` to `DeployScroll.s.sol` to better reflect its capability to deploy to local forks, testnets, and mainnet, not just forks.

## 🏗️ Architecture Overview

The deployment system consists of three main components:

1. **DeployScroll.s.sol** - Main deployment script with hybrid approach
2. **DeployHelper.s.sol** - Verification and testing helper
3. **RunDeployment.s.sol** - Orchestrator that runs the complete deployment

## 🔧 Prerequisites

### Required Dependencies
- Foundry (latest version)
- OpenZeppelin Foundry Upgrades plugin
- Access to Scroll RPC endpoints

### Environment Setup
1. Install Foundry: `curl -L https://foundry.paradigm.xyz | bash`
2. Install OpenZeppelin Foundry Upgrades: `forge install OpenZeppelin/openzeppelin-foundry-upgrades`
3. Set up your environment variables

## 🚀 Quick Start Deployment

### 1. Set Environment Variables
```bash
# Create .env file
cp .env.example .env

# Fill in your values
PRIVATE_KEY=your_private_key_here
DEPLOYMENT_TARGET=local  # Options: local, sepolia, mainnet
```

### 2. Run the Complete Deployment
```bash
# Deploy to local fork (development)
export DEPLOYMENT_TARGET=local
forge script script/RunDeployment.s.sol:RunDeployment \
    --broadcast \
    --verify \
    -vvvv

# Deploy to testnet
export DEPLOYMENT_TARGET=sepolia
forge script script/RunDeployment.s.sol:RunDeployment \
    --broadcast \
    --verify \
    -vvvv

# Deploy to mainnet
export DEPLOYMENT_TARGET=mainnet
forge script script/RunDeployment.s.sol:RunDeployment \
    --broadcast \
    --verify \
    -vvvv
```

## 🌍 Deployment Environments

### Local Fork (Development)
- **DEPLOYMENT_TARGET**: `local`
- **Purpose**: Development and testing
- **Network**: Scroll mainnet fork
- **RPC**: `https://rpc.scroll.io`
- **Chain ID**: 31337 (local fork)
- **Gas**: No real costs

### Sepolia Testnet (Staging)
- **DEPLOYMENT_TARGET**: `sepolia`
- **Purpose**: Staging and community testing
- **Network**: Scroll Sepolia testnet
- **RPC**: `https://sepolia-rpc.scroll.io`
- **Chain ID**: 534351
- **Gas**: Testnet ETH required

### Mainnet (Production)
- **DEPLOYMENT_TARGET**: `mainnet`
- **Purpose**: Production deployment
- **Network**: Scroll mainnet
- **RPC**: `https://rpc.scroll.io`
- **Chain ID**: 534352
- **Gas**: Real ETH required
- **⚠️ Warning**: Permanent deployment

## 📋 Deployment Process

The deployment follows this sequence:

### Step 1: Core Contract Deployment (OpenZeppelin)
- Deploy USX Token with UUPS proxy
- Deploy sUSX Vault with UUPS proxy
- Use OpenZeppelin's security features and validation

### Step 2: Diamond Deployment (Custom Logic)
- Deploy Treasury Diamond implementation
- Deploy Treasury proxy with real contract addresses
- Deploy all facets (AssetManager, InsuranceBuffer, ProfitAndLoss)

### Step 3: Contract Linking (Hybrid)
- Link USX to Treasury using `setInitialTreasury`
- Link sUSX to Treasury using `setInitialTreasury`
- Add facets to diamond with proper selectors

### Step 4: Verification (OpenZeppelin + Custom)
- Verify all contract addresses and configurations
- Test facet functionality through diamond
- Validate contract linking

### Step 5: Testing (Custom)
- Test basic operations on all contracts
- Verify default values and configurations
- Test diamond pattern functionality

## 🔍 Verification Features

### Automatic Verification
- Contract address validation
- Configuration parameter verification
- Facet accessibility testing
- Contract linking validation

### Manual Verification
```bash
# Check deployed addresses
forge script script/RunDeployment.s.sol:RunDeployment \
    --sig "getDeployedAddresses()"

# Run post-deployment tests
forge script script/RunDeployment.s.sol:RunDeployment \
    --sig "runPostDeploymentTests()"

# Check contract state
forge script script/RunDeployment.s.sol:RunDeployment \
    --sig "checkContractState()"
```

## 🛡️ Security Features

### OpenZeppelin Integration
- **Automated security checks** during deployment
- **Proxy validation** and upgrade safety
- **Storage layout verification**
- **Access control validation**

### Custom Security
- **Diamond pattern validation**
- **Facet selector verification**
- **Contract linking verification**
- **Comprehensive testing**

## 🔧 Configuration Options

### Environment Variables

> **Note**: RPC URLs are automatically determined based on your `DEPLOYMENT_TARGET` setting. You don't need to specify them in the command line anymore.
```bash
# Required: Your private key
PRIVATE_KEY=your_private_key_here

# Required: Contract addresses
USDC_ADDRESS=0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4

# Required: Governance addresses
GOVERNANCE_ADDRESS=0x1000000000000000000000000000000000000001
GOVERNANCE_WARCHEST_ADDRESS=0x2000000000000000000000000000000000000002
ASSET_MANAGER_ADDRESS=0x3000000000000000000000000000000000000003
ADMIN_ADDRESS=0x4000000000000000000000000000000000000004

# Required: Deployment target
DEPLOYMENT_TARGET=local  # Options: local, sepolia, mainnet

# Required: RPC URLs
SCROLL_MAINNET_RPC=https://rpc.scroll.io
SCROLL_SEPOLIA_RPC=https://sepolia-rpc.scroll.io
```

### Network Configuration
```toml
# deploy.config.toml
[network]
fork_url = "https://rpc.scroll.io"
chain_id = 534352
name = "Scroll Mainnet Fork"
```

### Contract Addresses
```toml
[contracts]
usdc_address = "0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4"
```

### Test Addresses
```toml
[addresses]
governance = "0x1000000000000000000000000000000000000001"
governance_warchest = "0x2000000000000000000000000000000000000002"
asset_manager = "0x3000000000000000000000000000000000000003"
admin = "0x4000000000000000000000000000000000000004"
```

## 🧪 Testing the Deployment

### Automated Testing
The deployment includes comprehensive testing:
- Contract initialization verification
- Facet functionality testing
- Diamond pattern validation
- Contract linking verification

### Manual Testing
```bash
# Test specific functionality
forge script script/DeployHelper.s.sol:DeployHelper \
    --sig "testBasicOperations()" \
    --rpc-url <your-rpc-url>
```

## 🚨 Troubleshooting

### Common Issues

#### 1. OpenZeppelin Import Errors
```bash
# Ensure OpenZeppelin Foundry Upgrades is installed
forge install OpenZeppelin/openzeppelin-foundry-upgrades
```

#### 2. RPC Connection Issues
```bash
# Check RPC endpoint
curl -X POST -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
    https://rpc.scroll.io
```

#### 3. Gas Limit Issues
```bash
# Increase gas limit
forge script script/RunDeployment.s.sol:RunDeployment \
    --gas-limit 30000000 \
    --rpc-url <your-rpc-url>
```

### Debug Mode
```bash
# Run with maximum verbosity
forge script script/RunDeployment.s.sol:RunDeployment \
    --rpc-url <your-rpc-url> \
    -vvvvv
```

## 📊 Deployment Output

### Successful Deployment
```
🚀 STARTING FULL SYSTEM DEPLOYMENT
=====================================
Deployment Target: local
RPC URL: https://rpc.scroll.io
=====================================

📋 STEP 1: Running Main Deployment
-------------------------------------
=== DEPLOYING TO local ===
Deployer: 0x...
Governance: 0x1000000000000000000000000000000000000001
Asset Manager: 0x3000000000000000000000000000000000000003
Chain ID: 534352
=========================================

=== STEP 1: Deploying Core Contracts with OpenZeppelin ===
1.1. Deploying USX Token...
✓ USX Token deployed at: 0x...
1.2. Deploying sUSX Vault...
✓ sUSX Vault deployed at: 0x...

=== STEP 2: Deploying Diamond with Custom Logic ===
2.1. Deploying Treasury Diamond...
2.2. Deploying Treasury Proxy...
✓ Treasury Diamond deployed at: 0x...
2.3. Deploying Facets...
✓ Profit/Loss Facet: 0x...
✓ Insurance Buffer Facet: 0x...
✓ Asset Manager Facet: 0x...

=== STEP 3: Linking Contracts with OpenZeppelin Security ===
3.1. Linking USX to Treasury...
✓ USX linked to Treasury
3.2. Linking sUSX to Treasury...
✓ sUSX linked to Treasury
3.3. Adding Facets to Diamond...
3.3.1. Adding Profit/Loss Facet...
✓ Profit/Loss Facet added
3.3.2. Adding Insurance Buffer Facet...
✓ Insurance Buffer Facet added
3.3.3. Adding Asset Manager Facet...
✓ Asset Manager Facet added

=== STEP 4: Comprehensive Verification ===
✓ USX verification passed
✓ sUSX verification passed
✓ Treasury verification passed
✓ Facet accessibility verification passed

=== STEP 5: Testing Basic Functionality ===
5.1. Testing USX basic functionality...
✓ USX basic functionality verified
5.2. Testing sUSX basic functionality...
✓ sUSX basic functionality verified
5.3. Testing Treasury basic functionality...
✓ Treasury basic functionality verified
5.4. Testing facet functionality through diamond...
✓ Facet functionality verified

✅ Main deployment completed successfully
   USX Proxy: 0x...
   sUSX Proxy: 0x...
   Treasury Proxy: 0x...

🔍 STEP 2: Verifying Deployment
--------------------------------
=== DEPLOYMENT HELPER SETUP ===
USX: 0x...
sUSX: 0x...
Treasury: 0x...
=================================

=== COMPLETE SYSTEM VERIFICATION ===

--- USX Configuration Verification ---
Name: USX Token
Symbol: USX
Decimals: 18
USDC Address: 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4
Treasury Address: 0x...
Governance Warchest: 0x2000000000000000000000000000000000000002
Admin: 0x4000000000000000000000000000000000000004
✓ USX USDC address verified
✓ USX treasury linking verified

--- sUSX Configuration Verification ---
Name: sUSX Token
Symbol: sUSX
Decimals: 18
USX Address: 0x...
Treasury Address: 0x...
Governance: 0x1000000000000000000000000000000000000001
✓ sUSX USX linking verified
✓ sUSX treasury linking verified

--- Treasury Configuration Verification ---
USDC Address: 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4
USX Address: 0x...
sUSX Address: 0x...
Governance: 0x1000000000000000000000000000000000000001
Asset Manager: 0x3000000000000000000000000000000000000003
✓ Treasury address linking verified

--- Facet Functionality Verification ---
  Testing AssetManagerAllocatorFacet...
    maxLeverage: 0
    netDeposits: 0
  Testing InsuranceBufferFacet...
    bufferTarget: 0
    bufferRenewalRate: 100000
  Testing ProfitAndLossReporterFacet...
    successFee: 50000
    profitLatestEpoch: 0
✓ All facet functionality verified

--- Contract Linking Verification ---
✓ USX -> Treasury link verified
✓ sUSX -> Treasury link verified
✓ Treasury -> USX link verified
✓ Treasury -> sUSX link verified
✓ Treasury -> USDC link verified

✅ ALL VERIFICATIONS PASSED!
System is fully deployed and functional!

✅ Deployment verification completed successfully

🧪 STEP 3: Testing Basic Functionality
---------------------------------------
=== TESTING BASIC OPERATIONS ===
  Testing USX minting...
    ⚠️ USX minting failed (expected if not admin)
  Testing sUSX operations...
    sharePrice: 1000000000000000000
    lastEpochBlock: 1000000
    epochDuration: 216000
  Testing Treasury operations...
    maxLeverageFraction: 100000
    successFeeFraction: 50000
    bufferTargetFraction: 50000
✓ All basic operations tested successfully

✅ Basic functionality testing completed successfully

📊 DEPLOYMENT SUMMARY
=====================
Network: local
RPC URL: https://rpc.scroll.io

Deployed Contracts:
  • USX Token: 0x...
  • sUSX Vault: 0x...
  • Treasury Diamond: 0x...

Facets Added:
  • AssetManagerAllocatorFacet
  • InsuranceBufferFacet
  • ProfitAndLossReporterFacet

Configuration:
  • USDC Address: 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4
  • Governance: 0x1000000000000000000000000000000000000001
  • Asset Manager: 0x3000000000000000000000000000000000000003

Default Values:
  • Max Leverage Fraction: 10% (100000)
  • Success Fee Fraction: 5% (50000)
  • Buffer Target Fraction: 5% (50000)
  • Buffer Renewal Fraction: 10% (100000)

🎉 DEPLOYMENT COMPLETE AND VERIFIED!
=====================================
```

## 🔄 Upgrading the System

### Upgrade Process
1. **Deploy new implementation contracts**
2. **Upgrade proxies using OpenZeppelin tools**
3. **Verify new functionality**
4. **Test all facets through diamond**

### Upgrade Commands
```bash
# Upgrade specific contracts
forge script script/UpgradeContracts.s.sol:UpgradeContracts \
    --rpc-url <your-rpc-url> \
    --broadcast
```

## 📚 Additional Resources

### Documentation
- [OpenZeppelin Foundry Upgrades](https://docs.openzeppelin.com/upgrades-plugins/1.x/)
- [Diamond Standard (EIP-2535)](https://eips.ethereum.org/EIPS/eip-2535)
- [Foundry Book](https://book.getfoundry.sh/)

### Support
- GitHub Issues: [USX Repository](https://github.com/your-org/usx)
- Documentation: [USX Docs](https://docs.usx.com)

## 🎯 Next Steps

After successful deployment:
1. **Test all functionality** thoroughly
2. **Verify security** with external auditors
3. **Deploy to testnet** for community testing
4. **Prepare for mainnet** deployment

---

**Note**: This deployment system combines the best of both worlds - OpenZeppelin's proven security tools with our custom diamond pattern expertise. Always test thoroughly before deploying to production networks.
