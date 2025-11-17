import axios from "axios";
import dotenv from "dotenv";
import { createWalletClient, http, type Address } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { scroll } from "viem/chains";

import { ScrollL1MessengerABI } from "./abi.ts";

dotenv.config();

interface ClaimInfo {
  from: string;
  to: string;
  value: string;
  nonce: string;
  message: string;
  proof: {
    batch_index: string;
    merkle_proof: string;
  };
  claimable: boolean;
}

interface ApiResponse {
  errcode: number;
  errmsg: string;
  data: {
    results: Array<{
      hash: string;
      counterpart_chain_tx?: {
        hash: string;
        block_number: number;
      };
      claim_info: ClaimInfo;
    }>;
  };
}

async function getClaimInfo(txHash: string): Promise<ClaimInfo> {
  const apiUrl = "https://mainnet-api-bridge-v2.scroll.io/api/txsbyhashes";

  try {
    const response = await axios.post<ApiResponse>(apiUrl, {
      txs: [txHash],
    });

    if (response.data.errcode !== 0) {
      throw new Error(`API error: ${response.data.errmsg}`);
    }

    const results = response.data.data.results;
    if (!results || results.length === 0) {
      throw new Error("No transaction found");
    }

    if (results[0]?.counterpart_chain_tx) {
      console.log(
        "Transaction already claimed, hash:",
        results[0]?.counterpart_chain_tx?.hash
      );
      // throw new Error("Transaction already claimed");
    }

    const claimInfo = results[0]?.claim_info;
    if (!claimInfo) {
      throw new Error("No claim info found");
    }

    if (!claimInfo.claimable) {
      throw new Error("Transaction is not claimable");
    }

    return claimInfo;
  } catch (error) {
    if (axios.isAxiosError(error)) {
      throw new Error(`Failed to fetch claim info: ${error.message}`);
    }
    throw error;
  }
}

async function sendClaimTransaction(
  claimInfo: ClaimInfo,
  privateKey: string,
  rpcUrl?: string
) {
  // Create account from private key
  const account = privateKeyToAccount(privateKey as `0x${string}`);

  // Create wallet client
  const client = createWalletClient({
    chain: scroll,
    account,
    transport: rpcUrl ? http(rpcUrl) : http(),
  });

  console.log("Sending claim transaction...");
  console.log("From:", claimInfo.from);
  console.log("To:", claimInfo.to);
  console.log("Value:", claimInfo.value);
  console.log("Nonce:", claimInfo.nonce);
  console.log("Batch Index:", claimInfo.proof.batch_index);
  console.log(
    "Merkle Proof Length:",
    claimInfo.proof.merkle_proof.length,
    "bytes"
  );

  const hash = await client.writeContract({
    address: "0x6774Bcbd5ceCeF1336b5300fb5186a12DDD8b367" as Address,
    abi: ScrollL1MessengerABI,
    functionName: "relayMessageWithProof",
    args: [
      claimInfo.from as Address,
      claimInfo.to as Address,
      BigInt(claimInfo.value),
      BigInt(claimInfo.nonce),
      claimInfo.message as `0x${string}`,
      [
        BigInt(claimInfo.proof.batch_index),
        claimInfo.proof.merkle_proof as `0x${string}`,
      ],
    ],
  });

  console.log("Transaction sent successfully!, hash:", hash);
  return hash;
}

async function main() {
  const args = process.argv.slice(2);

  if (args.length === 0) {
    console.error("Usage: ts-node tools/index.ts <txHash>");
    console.error(
      "Example: ts-node tools/index.ts 0x9d934b35e47f38a5c404b2baa88c97dcc0d8171e04ed6496892265b08bdaab07"
    );
    process.exit(1);
  }

  const txHash = args[0] as string;
  const rpcUrl = process.env.MAINNET_RPC || "https://eth.drpc.org";
  const privateKey = process.env.PRIVATE_KEY;

  if (!privateKey) {
    console.error("Error: Private key is required");
    console.error(
      "Provide it as second argument or set PRIVATE_KEY environment variable"
    );
    process.exit(1);
  }

  console.log("Fetching claim info for transaction:", txHash);
  const claimInfo = await getClaimInfo(txHash);

  console.log("\nClaim info retrieved:");
  console.log("- Claimable:", claimInfo.claimable);
  console.log("- From:", claimInfo.from);
  console.log("- To:", claimInfo.to);
  console.log("- Value:", claimInfo.value);
  console.log("- Nonce:", claimInfo.nonce);
  console.log("- Batch Index:", claimInfo.proof.batch_index);
  console.log(
    "- Merkle Proof Length:",
    claimInfo.proof.merkle_proof.length,
    "bytes"
  );

  await sendClaimTransaction(claimInfo, privateKey, rpcUrl);
}

main();
