import type { DeploymentManifest, DeploymentTransaction, StandaloneContract } from "./deployment-state.ts";

const transactionHashPattern = /^0x[0-9a-fA-F]{64}$/;
const addressPattern = /^0x[0-9a-fA-F]{40}$/;
const quantityPattern = /^0x(?:0|[1-9a-fA-F][0-9a-fA-F]*)$/;
const runtimeCodePattern = /^0x(?:[0-9a-fA-F]{2})*$/;

export type CommandOptions = {
  signal?: AbortSignal;
};

export type CommandRunner = (command: string, args: readonly string[], options: CommandOptions) => Promise<string>;

export type FinalityOptions = {
  signal?: AbortSignal;
  pollIntervalMs?: number;
  sleep?: (milliseconds: number, signal?: AbortSignal) => Promise<void>;
  progress?: (message: string) => void;
};

export type DeploymentExpectations = {
  admin: string;
  adminDelay: number;
};

export function extractBroadcastTransactionHashes(text: string): string[] {
  let value: unknown;
  try {
    value = JSON.parse(text) as unknown;
  } catch {
    throw new Error("broadcast JSON is invalid");
  }

  if (!isObject(value) || !Array.isArray(value.transactions) || value.transactions.length === 0) {
    throw new Error("broadcast.transactions must be a non-empty array");
  }

  const hashes: string[] = [];
  const uniqueHashes = new Set<string>();
  for (const [index, transaction] of value.transactions.entries()) {
    if (
      !isObject(transaction) ||
      typeof transaction.hash !== "string" ||
      !transactionHashPattern.test(transaction.hash)
    ) {
      throw new Error(`broadcast.transactions[${index}].hash must be a 32-byte transaction hash`);
    }
    const hash = transaction.hash.toLowerCase();
    if (uniqueHashes.has(hash)) {
      throw new Error(`broadcast.transactions[${index}] has duplicate transaction hash ${hash}`);
    }
    uniqueHashes.add(hash);
    hashes.push(hash);
  }
  return hashes;
}

export async function loadTransactionReceipts(
  run: CommandRunner,
  rpcUrl: string,
  hashes: readonly string[],
): Promise<DeploymentTransaction[]> {
  if (hashes.length === 0) throw new Error("at least one transaction hash is required");
  const receipts: DeploymentTransaction[] = [];
  const receiptHashes = new Set<string>();

  for (const requestedHash of hashes) {
    if (!transactionHashPattern.test(requestedHash)) throw new Error(`transaction hash ${requestedHash} is invalid`);
    let output: string;
    try {
      output = await run("cast", ["rpc", "--rpc-url", rpcUrl, "eth_getTransactionReceipt", requestedHash], {});
    } catch (error) {
      throw new Error(`could not read receipt for transaction ${requestedHash}`, { cause: error });
    }
    const receipt = parseTransactionReceipt(output, requestedHash);
    if (receiptHashes.has(receipt.hash)) throw new Error(`duplicate receipt hash ${receipt.hash}`);
    receiptHashes.add(receipt.hash);
    receipts.push(receipt);
  }

  return receipts;
}

// Ethereum finalizes a block about two epochs (~13 minutes) after it is produced; a finalized block can no
// longer be reorganized away, so the manifest never records transactions that might disappear.
export async function waitForFinality(
  run: CommandRunner,
  rpcUrl: string,
  receipts: readonly DeploymentTransaction[],
  options: FinalityOptions = {},
): Promise<void> {
  const receiptBlocks = collectReceiptBlocks(receipts);
  const highestReceiptBlock = Math.max(...receiptBlocks.keys());
  const pollIntervalMs = options.pollIntervalMs ?? 30_000;
  if (!Number.isInteger(pollIntervalMs) || pollIntervalMs < 0) {
    throw new Error("finality poll interval must be a non-negative integer");
  }
  const sleep = options.sleep ?? abortableSleep;
  const progress = options.progress ?? ((message: string) => console.error(message));

  while (true) {
    throwIfCancelled(options.signal);
    const height = await loadFinalizedBlockNumber(run, rpcUrl, options.signal);
    throwIfCancelled(options.signal);
    if (height >= highestReceiptBlock) {
      progress(`finalized height ${height} covers all receipt blocks`);
      break;
    }
    progress(`finalized height ${height}; waiting for receipt block ${highestReceiptBlock}`);
    await sleep(pollIntervalMs, options.signal);
  }

  for (const [height, expectedHash] of receiptBlocks) {
    throwIfCancelled(options.signal);
    await verifyCanonicalBlock(run, rpcUrl, height, expectedHash, options.signal);
  }
}

// Contracts are compiled for Osaka, which every supported network runs, but Amsterdam (Glamsterdam) reprices
// contract creation several times over. Forge sets gas limits from its own simulation, so it has to simulate
// with the rules the chain runs or the deployment runs out of gas. Blocks carry a block access list hash
// (EIP-7928) from Amsterdam on.
export async function detectRuntimeHardfork(
  run: CommandRunner,
  rpcUrl: string,
  signal?: AbortSignal,
): Promise<"amsterdam" | undefined> {
  let output: string;
  try {
    output = await run("cast", ["rpc", "--rpc-url", rpcUrl, "eth_getBlockByNumber", "latest", "false"], { signal });
  } catch (error) {
    throw new Error("could not read latest block", { cause: error });
  }
  const block = parseJsonObject(output, "latest block");
  return block.blockAccessListHash === undefined ? undefined : "amsterdam";
}

export async function verifyManifestContracts(
  run: CommandRunner,
  rpcUrl: string,
  manifest: DeploymentManifest,
): Promise<void> {
  for (const [name, contract] of Object.entries(manifest.contracts)) {
    await verifyRuntimeHash(run, rpcUrl, contract.address, contract.codeHash, name);
  }
}

export async function verifyLiveDeployment(
  run: CommandRunner,
  rpcUrl: string,
  manifest: DeploymentManifest,
  expectations?: DeploymentExpectations,
): Promise<void> {
  await verifyManifestContracts(run, rpcUrl, manifest);

  const registry = requireContract(manifest, "DatasetRegistry");
  const consentManager = requireContract(manifest, "ConsentManager");
  const usageLog = requireContract(manifest, "UsageLog");

  await verifyAddressCall(
    run,
    rpcUrl,
    consentManager.address,
    "getDatasetRegistry()(address)",
    registry.address,
    "ConsentManager dataset registry",
  );
  await verifyAddressCall(
    run,
    rpcUrl,
    usageLog.address,
    "getConsentManager()(address)",
    consentManager.address,
    "UsageLog consent manager",
  );

  const admin = await readAddressCall(run, rpcUrl, usageLog.address, "defaultAdmin()(address)", "UsageLog admin");
  if (expectations !== undefined) {
    if (admin !== expectations.admin.toLowerCase()) {
      throw new Error(`UsageLog admin does not match: expected ${expectations.admin.toLowerCase()}, got ${admin}`);
    }
    const delay = await readUintCall(run, rpcUrl, usageLog.address, "defaultAdminDelay()(uint48)", "UsageLog admin delay");
    if (delay !== BigInt(expectations.adminDelay)) {
      throw new Error(`UsageLog admin delay does not match: expected ${expectations.adminDelay}, got ${delay}`);
    }
  }
  await verifyRole(run, rpcUrl, usageLog.address, "DEFAULT_ADMIN_ROLE()(bytes32)", admin, "UsageLog admin");
  await verifyRole(
    run,
    rpcUrl,
    usageLog.address,
    "LOGGER_ROLE()(bytes32)",
    requireNonZeroDependency(manifest, "Logger"),
    "UsageLog logger",
  );
}

async function verifyRuntimeHash(
  run: CommandRunner,
  rpcUrl: string,
  address: string,
  expectedHashValue: string,
  label: string,
): Promise<void> {
  const code = await loadRuntimeCode(run, rpcUrl, address, label);
  let output: string;
  try {
    output = await run("cast", ["keccak", code], {});
  } catch (error) {
    throw new Error(`could not hash ${label} runtime bytecode`, { cause: error });
  }
  const actualHash = readHash(output.trim(), `${label} runtime code hash`);
  const expectedHash = readHash(expectedHashValue, `${label} manifest code hash`);
  if (actualHash !== expectedHash) {
    throw new Error(`${label} code hash does not match manifest: expected ${expectedHash}, got ${actualHash}`);
  }
}

async function loadRuntimeCode(run: CommandRunner, rpcUrl: string, address: string, label: string): Promise<string> {
  let output: string;
  try {
    output = await run("cast", ["rpc", "--rpc-url", rpcUrl, "eth_getCode", address, "latest"], {});
  } catch (error) {
    throw new Error(`could not read ${label} runtime bytecode at ${address}`, { cause: error });
  }
  let value: unknown;
  try {
    value = JSON.parse(output) as unknown;
  } catch {
    throw new Error(`${label} runtime bytecode RPC output is invalid`);
  }
  if (typeof value !== "string" || !runtimeCodePattern.test(value)) {
    throw new Error(`${label} runtime bytecode is malformed`);
  }
  if (value.toLowerCase() === "0x") throw new Error(`${label} has no runtime bytecode`);
  return value.toLowerCase();
}

async function verifyAddressCall(
  run: CommandRunner,
  rpcUrl: string,
  target: string,
  signature: string,
  expectedAddress: string,
  label: string,
): Promise<void> {
  const actualAddress = await readAddressCall(run, rpcUrl, target, signature, label);
  if (actualAddress !== expectedAddress.toLowerCase()) {
    throw new Error(`${label} does not match: expected ${expectedAddress.toLowerCase()}, got ${actualAddress}`);
  }
}

async function readAddressCall(
  run: CommandRunner,
  rpcUrl: string,
  target: string,
  signature: string,
  label: string,
): Promise<string> {
  const output = await call(run, rpcUrl, target, [signature], label);
  return readAddressResult(output, label);
}

async function readUintCall(
  run: CommandRunner,
  rpcUrl: string,
  target: string,
  signature: string,
  label: string,
): Promise<bigint> {
  const output = await call(run, rpcUrl, target, [signature], label);
  const value = output.split(/\s+/)[0] ?? "";
  if (!/^\d+$/.test(value)) throw new Error(`${label} must return an unsigned integer`);
  return BigInt(value);
}

async function verifyRole(
  run: CommandRunner,
  rpcUrl: string,
  contract: string,
  roleSignature: string,
  account: string,
  label: string,
): Promise<void> {
  const role = readHash(await call(run, rpcUrl, contract, [roleSignature], `${label} role identifier`), `${label} role identifier`);
  const granted = await call(run, rpcUrl, contract, ["hasRole(bytes32,address)(bool)", role, account], `${label} role`);
  if (granted !== "true") throw new Error(`${label} role is missing for ${account} on contract ${contract}`);
}

async function call(
  run: CommandRunner,
  rpcUrl: string,
  target: string,
  args: readonly string[],
  label: string,
): Promise<string> {
  try {
    return (await run("cast", ["call", target, ...args, "--rpc-url", rpcUrl], {})).trim();
  } catch (error) {
    throw new Error(`could not read ${label} from contract ${target}`, { cause: error });
  }
}

function readAddressResult(value: string, path: string): string {
  if (!addressPattern.test(value)) throw new Error(`${path} must return an address`);
  return value.toLowerCase();
}

function requireContract(manifest: DeploymentManifest, name: string): StandaloneContract {
  const contract = manifest.contracts[name];
  if (contract === undefined) throw new Error(`manifest contract ${name} is missing`);
  return contract;
}

function requireNonZeroDependency(manifest: DeploymentManifest, name: string): string {
  const address = manifest.externalDependencies[name];
  if (address === undefined || !addressPattern.test(address) || /^0x0{40}$/.test(address)) {
    throw new Error(`manifest external dependency ${name} must be a non-zero address`);
  }
  return address.toLowerCase();
}

function collectReceiptBlocks(receipts: readonly DeploymentTransaction[]): Map<number, string> {
  if (receipts.length === 0) throw new Error("at least one transaction receipt is required for finality");
  const blocks = new Map<number, string>();
  for (const receipt of receipts) {
    if (!Number.isSafeInteger(receipt.blockNumber) || receipt.blockNumber <= 0) {
      throw new Error(`receipt transaction ${receipt.hash} has invalid block number`);
    }
    const blockHash = readHash(receipt.blockHash, `receipt block ${receipt.blockNumber} hash`);
    const previousHash = blocks.get(receipt.blockNumber);
    if (previousHash !== undefined && previousHash !== blockHash) {
      throw new Error(`receipt block ${receipt.blockNumber} has conflicting hashes`);
    }
    blocks.set(receipt.blockNumber, blockHash);
  }
  return blocks;
}

async function loadFinalizedBlockNumber(run: CommandRunner, rpcUrl: string, signal?: AbortSignal): Promise<number> {
  let output: string;
  try {
    output = await run("cast", ["rpc", "--rpc-url", rpcUrl, "eth_getBlockByNumber", "finalized", "false"], { signal });
  } catch (error) {
    throwIfCancelled(signal);
    throw new Error("could not read finalized block", { cause: error });
  }
  const block = parseJsonObject(output, "finalized block");
  return readQuantity(block.number, "finalized block number");
}

async function verifyCanonicalBlock(
  run: CommandRunner,
  rpcUrl: string,
  height: number,
  expectedHash: string,
  signal?: AbortSignal,
): Promise<void> {
  const quantity = `0x${height.toString(16)}`;
  let output: string;
  try {
    output = await run("cast", ["rpc", "--rpc-url", rpcUrl, "eth_getBlockByNumber", quantity, "false"], { signal });
  } catch (error) {
    throwIfCancelled(signal);
    throw new Error(`could not read canonical block ${height}`, { cause: error });
  }
  const block = parseJsonObject(output, `canonical block ${height}`);
  const actualHeight = readQuantity(block.number, `canonical block ${height} number`);
  if (actualHeight !== height) {
    throw new Error(`canonical block height mismatch for receipt block ${height}: got ${actualHeight}`);
  }
  const actualHash = readHash(block.hash, `canonical block ${height} hash`);
  if (actualHash !== expectedHash) {
    throw new Error(`receipt block ${height} is not canonical: expected ${expectedHash}, got ${actualHash}`);
  }
}

function parseTransactionReceipt(text: string, requestedHash: string): DeploymentTransaction {
  let value: unknown;
  try {
    value = JSON.parse(text) as unknown;
  } catch {
    throw new Error(`receipt JSON for transaction ${requestedHash} is invalid`);
  }
  if (value === null) throw new Error(`receipt is missing for transaction ${requestedHash}`);
  if (!isObject(value)) throw new Error(`receipt for transaction ${requestedHash} must be an object`);

  const receiptHash = readHash(value.transactionHash, `transaction ${requestedHash} receipt hash`);
  const status = readQuantity(value.status, `transaction ${requestedHash} status`);
  if (status !== 1) throw new Error(`transaction ${requestedHash} failed with status ${status}`);
  const blockNumber = readQuantity(value.blockNumber, `transaction ${requestedHash} blockNumber`);
  if (blockNumber <= 0) throw new Error(`transaction ${requestedHash} must have a positive block number`);
  const blockHash = readHash(value.blockHash, `transaction ${requestedHash} blockHash`);
  const contractAddress = readReceiptContractAddress(value.contractAddress, requestedHash);

  return { hash: receiptHash, status, blockNumber, blockHash, contractAddress };
}

function readReceiptContractAddress(value: unknown, transactionHash: string): string | null {
  if (value === null || value === undefined) return null;
  if (typeof value !== "string" || !addressPattern.test(value)) {
    throw new Error(`transaction ${transactionHash} contractAddress must be null or a 20-byte address`);
  }
  return value.toLowerCase();
}

function parseJsonObject(text: string, path: string): Record<string, unknown> {
  let value: unknown;
  try {
    value = JSON.parse(text) as unknown;
  } catch {
    throw new Error(`${path} JSON is invalid`);
  }
  if (!isObject(value)) throw new Error(`${path} must be an object`);
  return value;
}

function readQuantity(value: unknown, path: string): number {
  if (typeof value !== "string" || !quantityPattern.test(value)) {
    throw new Error(`${path} must be a valid JSON-RPC hex quantity`);
  }
  const quantity = BigInt(value);
  if (quantity > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error(`${path} exceeds the safe integer range`);
  return Number(quantity);
}

function readHash(value: unknown, path: string): string {
  if (typeof value !== "string" || !transactionHashPattern.test(value)) throw new Error(`${path} must be a 32-byte hash`);
  return value.toLowerCase();
}

function throwIfCancelled(signal?: AbortSignal): void {
  if (signal?.aborted) {
    const error = new Error("finality wait cancelled");
    error.name = "AbortError";
    throw error;
  }
}

function abortableSleep(milliseconds: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    throwIfCancelled(signal);
    const timer = setTimeout(() => {
      signal?.removeEventListener("abort", cancel);
      resolve();
    }, milliseconds);
    const cancel = () => {
      clearTimeout(timer);
      const error = new Error("finality wait cancelled");
      error.name = "AbortError";
      reject(error);
    };
    signal?.addEventListener("abort", cancel, { once: true });
  });
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
