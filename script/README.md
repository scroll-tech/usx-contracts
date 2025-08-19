# Deployment Scripts

This directory contains the essential script for deploying the complete USX ecosystem.

## Script Overview

### `DeployAll.s.sol` - Complete System Deployment
**Purpose**: Deploys and fully configures the entire USX ecosystem in a single command.

**Environment Variables Required**:
- `DEPLOYMENT_TARGET`: Choose deployment target (`mainnet`, `sepolia`, or `local`)
- `PRIVATE_KEY`: Deployer private key (acts as governance during setup, then transfers to target)
- `SCROLL_MAINNET_RPC`: RPC URL for Scroll mainnet  
- `SCROLL_SEPOLIA_RPC`: RPC URL for Scroll Sepolia testnet
- `USDC_ADDRESS`: USDC token address on target network
- `ASSET_MANAGER_ADDRESS`: Asset manager contract address
- `GOVERNANCE_ADDRESS`: Target governance address (receives governance at end)
- `ADMIN_ADDRESS`: Admin contract address
- `GOVERNANCE_WARCHEST_ADDRESS`: Governance warchest address

## Deployment Targets

### 1. **Local Scroll Fork** (Recommended for testing)
```bash
# Set environment variable
export DEPLOYMENT_TARGET=local

# Deploy to local Anvil instance
forge script script/DeployAll.s.sol --fork-url http://localhost:8545 --broadcast
```

### 2. **Scroll Sepolia Testnet** (Recommended for staging)
```bash
# Set environment variable
export DEPLOYMENT_TARGET=sepolia

# Deploy to Scroll Sepolia testnet
forge script script/DeployAll.s.sol --fork-url https://sepolia-rpc.scroll.io --broadcast
```

### 3. **Scroll Mainnet** (Production deployment)
```bash
# Set environment variable
export DEPLOYMENT_TARGET=mainnet

# Deploy to Scroll mainnet
forge script script/DeployAll.s.sol --fork-url https://rpc.scroll.io --broadcast
```

## What the Script Does

1. **Target Selection**: Automatically selects RPC URL based on `DEPLOYMENT_TARGET`
2. **Initial Deployment**:
   - Deploys USX Token with UUPS proxy (Treasury address initially set to 0x0)
   - Deploys sUSX Vault with UUPS proxy (Treasury address initially set to 0x0)  
   - Deploys Treasury Diamond with UUPS proxy and all facets
   - Registers all facet functions in the Diamond pattern
3. **Treasury Linking**:
   - Upgrades USX proxy to include `setInitialTreasury` function
   - Upgrades sUSX proxy to include `setInitialTreasury` function
   - Links USX to Treasury Diamond
   - Links sUSX to Treasury Diamond
4. **Governance Transfer**:
   - Deploys contracts with deployer as temporary governance for setup
   - Transfers Treasury governance to target `GOVERNANCE_ADDRESS` at the end
   - USX and sUSX governance set to target address from start

## Example .env Configuration

```bash
# Deployment Target (required)
DEPLOYMENT_TARGET=local

# RPC URLs
SCROLL_MAINNET_RPC=https://rpc.scroll.io
SCROLL_SEPOLIA_RPC=https://sepolia-rpc.scroll.io

# Private Keys  
PRIVATE_KEY=0x...  # Deployer private key (acts as governance during setup, then transfers to target)

# Contract Addresses
USDC_ADDRESS=0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4
ASSET_MANAGER_ADDRESS=0x...
GOVERNANCE_ADDRESS=0x...  # Target governance address (receives governance at end)
ADMIN_ADDRESS=0x...
GOVERNANCE_WARCHEST_ADDRESS=0x...
```

## Safety Features

- **Network Validation**: Script validates deployment target before proceeding
- **RPC URL Selection**: Automatically selects correct RPC based on target
- **Permission Checks**: Uses correct private keys for governance operations
- **Complete Setup**: Handles all deployment and linking in one transaction

## Post-Deployment

After successful deployment, the script outputs all contract addresses. You can verify the deployment by:
- Checking contract state variables
- Calling basic functions on deployed contracts
- Verifying Treasury links in USX and sUSX contracts