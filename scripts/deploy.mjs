/**
 * Kintagi - Deploy to Sui Testnet
 */

import { SuiJsonRpcClient, getJsonRpcFullnodeUrl } from '@mysten/sui/jsonRpc';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Transaction } from '@mysten/sui/transactions';
import { requestSuiFromFaucetV2, getFaucetHost } from '@mysten/sui/faucet';
import { fromBase64 } from '@mysten/sui/utils';
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'fs';
import { execSync } from 'child_process';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(__dirname, '..');
const DEPLOY_DIR = path.join(ROOT, 'deployments');
const DEPLOY_LOG = path.join(DEPLOY_DIR, 'deployed.json');
const CONTRACT_PATH = path.join('contracts', 'kintagi');

function log(prefix, msg) {
  console.log(`${prefix}  ${msg}`);
}

function logSection(title) {
  console.log(`\n${'-'.repeat(55)}\n  ${title}\n${'-'.repeat(55)}`);
}

function getKeypair() {
  if (process.env.SUI_PRIVATE_KEY) {
    const raw = fromBase64(process.env.SUI_PRIVATE_KEY);
    return Ed25519Keypair.fromSecretKey(raw.slice(0, 32));
  }

  const homeDir = process.env.HOME ?? process.env.USERPROFILE;
  const keystorePath = homeDir ? path.join(homeDir, '.sui', 'sui_config', 'sui.keystore') : null;

  if (keystorePath && existsSync(keystorePath)) {
    const keystore = JSON.parse(readFileSync(keystorePath, 'utf8'));
    if (keystore.length > 0) {
      const raw = fromBase64(keystore[0]);
      return Ed25519Keypair.fromSecretKey(raw.slice(1, 33));
    }
  }

  log('WARN', 'No keypair found - generating ephemeral wallet');
  return new Ed25519Keypair();
}

async function main() {
  logSection('KINTAGI - Testnet Deployment');

  const rpcClient = new SuiJsonRpcClient({
    url: getJsonRpcFullnodeUrl('testnet'),
    network: 'testnet',
  });

  const keypair = getKeypair();
  const address = keypair.getPublicKey().toSuiAddress();

  log('NET', 'Network  : testnet');
  log('ADDR', `Deployer : ${address}`);

  const balanceInfo = await rpcClient.getBalance({ owner: address });
  const balance = BigInt(balanceInfo.totalBalance);
  log('BAL', `Balance  : ${(Number(balance) / 1_000_000_000).toFixed(4)} SUI`);

  if (balance < 10_000_000n) {
    logSection('Requesting testnet SUI from faucet');

    try {
      await requestSuiFromFaucetV2({
        host: getFaucetHost('testnet'),
        recipient: address,
      });

      log('OK', 'Faucet request sent. Waiting 4s for confirmation...');
      await new Promise((resolve) => setTimeout(resolve, 4000));

      const bal2Info = await rpcClient.getBalance({ owner: address });
      const bal2 = BigInt(bal2Info.totalBalance);
      log('BAL', `New balance: ${(Number(bal2) / 1_000_000_000).toFixed(4)} SUI`);

      if (bal2 < 10_000_000n) {
        log('WARN', 'Faucet may be rate-limited. Fund manually:');
        log('INFO', `https://faucet.testnet.sui.io -> ${address}`);
        return;
      }
    } catch (error) {
      log('WARN', `Faucet error: ${error.message}`);
      log('INFO', 'Fund at: https://faucet.testnet.sui.io');
      log('INFO', `Address: ${address}`);
      return;
    }
  }

  logSection('Step 1 - Build Move package');

  let modules;
  let dependencies;

  try {
    const out = execSync(
      `sui move build --path ${CONTRACT_PATH} --dump-bytecode-as-base64`,
      { encoding: 'utf8' },
    );
    const jsonMatch = out.match(/\{[\s\S]*\}/);

    if (!jsonMatch) {
      throw new Error('No JSON in build output');
    }

    const parsed = JSON.parse(jsonMatch[0]);
    modules = parsed.modules;
    dependencies = parsed.dependencies;
    log('OK', `Built ${modules.length} modules successfully`);
  } catch (error) {
    log('ERR', 'Sui CLI build failed (contracts are written and ready):');
    log('INFO', 'Install Sui CLI: https://docs.sui.io/guides/developer/getting-started/sui-install');
    log('INFO', '');
    log('INFO', 'Then deploy manually:');
    log('INFO', `cd ${CONTRACT_PATH}`);
    log('INFO', 'sui client publish --gas-budget 100000000');
    log('INFO', '');
    log('INFO', 'Contract files:');
    log('INFO', 'sources/collection_manager.move');
    log('INFO', 'sources/mutation_engine.move');
    log('INFO', 'sources/nft.move');
    return;
  }

  logSection('Step 2 - Publish to testnet');

  const pubTx = new Transaction();
  const [upgradeCap] = pubTx.publish({ modules, dependencies });
  pubTx.transferObjects([upgradeCap], address);

  let pubResult;

  try {
    pubResult = await rpcClient.signAndExecuteTransaction({
      signer: keypair,
      transaction: pubTx,
      options: { showEffects: true, showObjectChanges: true },
    });
  } catch (error) {
    log('ERR', `Publish failed: ${error.message}`);
    return;
  }

  if (pubResult.effects?.status?.status !== 'success') {
    log('ERR', `Tx failed: ${pubResult.effects?.status?.error}`);
    return;
  }

  const packageId = pubResult.objectChanges?.find((change) => change.type === 'published')?.packageId;

  if (!packageId) {
    log('ERR', 'Publish succeeded but packageId was not found in objectChanges');
    return;
  }

  log('OK', `Package ID : ${packageId}`);
  log('LINK', `Explorer   : https://suiscan.xyz/testnet/object/${packageId}`);
  log('LINK', `Tx         : https://suiscan.xyz/testnet/tx/${pubResult.digest}`);

  const info = {
    network: 'testnet',
    deployedAt: new Date().toISOString(),
    deployer: address,
    packageId,
    txDigest: pubResult.digest,
    explorerLinks: {
      package: `https://suiscan.xyz/testnet/object/${packageId}`,
      tx: `https://suiscan.xyz/testnet/tx/${pubResult.digest}`,
    },
  };

  mkdirSync(DEPLOY_DIR, { recursive: true });
  writeFileSync(DEPLOY_LOG, JSON.stringify(info, null, 2));
  log('SAVE', 'Saved -> deployments/deployed.json');

  logSection('Deployment Complete');
  console.log(`\n${JSON.stringify(info, null, 2)}`);
}

main().catch((error) => {
  console.error(`\nERR  Fatal error: ${error.message}`);
  process.exit(1);
});
